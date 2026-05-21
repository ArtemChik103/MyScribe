from dataclasses import asdict, dataclass
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from transformers import TrOCRProcessor, VisionEncoderDecoderModel
from PIL import Image, ImageOps
import csv
import importlib.util
import io
import logging
import os
import shutil
import tempfile
import time
import uuid

import easyocr
import numpy as np
import torch


logger = logging.getLogger("myscribe")
logging.basicConfig(level=logging.INFO)

app = FastAPI()

# === РАЗРЕШАЕМ ДОСТУП ИЗ ИНТЕРНЕТА (CORS) ===
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# ============================================

# === НАСТРОЙКИ ===
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_MODEL_PATH = os.path.join(BASE_DIR, "trocr-handwritten-cyrillic")

# ДЛЯ FEEDBACK (СБОР ДАННЫХ)
DATASET_DIR = os.path.join(BASE_DIR, "dataset")
IMAGES_DIR = os.path.join(DATASET_DIR, "images")
os.makedirs(IMAGES_DIR, exist_ok=True)
LABELS_FILE = os.path.join(DATASET_DIR, "labels.csv")
LEGACY_FEEDBACK_META_FILE = os.path.join(DATASET_DIR, "feedback_meta.csv")
LEGACY_META_DIR = os.path.join(DATASET_DIR, "meta")

# Чистим старые диагностические артефакты: в dataset должны остаться только images/ и labels.csv
if os.path.exists(LEGACY_FEEDBACK_META_FILE):
    os.remove(LEGACY_FEEDBACK_META_FILE)
if os.path.isdir(LEGACY_META_DIR):
    shutil.rmtree(LEGACY_META_DIR)

if not os.path.exists(LABELS_FILE):
    with open(LABELS_FILE, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["filename", "text"])

# НАСТРОЙКИ СКОРОСТИ
# Дефолты выбираем в пользу стабильности на 4GB GPU: EasyOCR остается на CPU,
# а TrOCR использует CUDA только для распознавания crop-строк.
BATCH_SIZE = int(os.getenv("MYSCRIBE_TROCR_BATCH_SIZE", "1"))
NUM_BEAMS = int(os.getenv("MYSCRIBE_TROCR_NUM_BEAMS", "1"))
RESIZE_MAX_DIM = 1280
PADDING = 10
DEFAULT_ENGINE = "trocr"
SUPPORTED_ENGINES = {"trocr", "paddle"}

FORCE_CPU = os.getenv("MYSCRIBE_FORCE_CPU", "").lower() in {"1", "true", "yes"}
CUDA_AVAILABLE = (
    not FORCE_CPU
    and torch.cuda.is_available()
    and torch.cuda.device_count() > 0
)
DEVICE = "cuda" if CUDA_AVAILABLE else "cpu"
EASYOCR_GPU = os.getenv("MYSCRIBE_EASYOCR_GPU", "").lower() in {"1", "true", "yes"}
logger.info("=== УСТРОЙСТВО: %s (PyTorch Native Speed) ===", DEVICE)
logger.info(
    "=== OCR settings: batch_size=%s, num_beams=%s, easyocr_gpu=%s ===",
    BATCH_SIZE,
    NUM_BEAMS,
    EASYOCR_GPU and CUDA_AVAILABLE,
)

logger.info("1. Настройка EasyOCR...")
detect_reader = easyocr.Reader(["ru"], gpu=(EASYOCR_GPU and CUDA_AVAILABLE), quantize=False)

logger.info("2. Загрузка TrOCR (PyTorch)...")
try:
    processor = TrOCRProcessor.from_pretrained(LOCAL_MODEL_PATH, local_files_only=True)
    model = VisionEncoderDecoderModel.from_pretrained(
        LOCAL_MODEL_PATH,
        local_files_only=True,
    )
    model.to(DEVICE)
    # .half() НЕ используем (тормозит на 1650)
    model.eval()
    logger.info("TrOCR готов!")
except Exception as e:
    logger.error("Ошибка загрузки TrOCR: %s", e)
    raise SystemExit(1)

_paddle_ocr = None


@dataclass
class OcrLine:
    text: str
    confidence: float | None = None
    box: list[float] | None = None


@dataclass
class OcrResult:
    text: str
    engine: str
    lines: list[OcrLine]
    processing_time_ms: int
    warnings: list[str]

    def to_response(self):
        payload = asdict(self)
        payload["lines"] = [asdict(line) for line in self.lines]
        return payload


def _paddle_available() -> bool:
    return (
        importlib.util.find_spec("paddleocr") is not None
        and importlib.util.find_spec("paddle") is not None
    )


def _get_paddle_ocr():
    global _paddle_ocr
    if _paddle_ocr is not None:
        return _paddle_ocr

    if not _paddle_available():
        raise HTTPException(
            status_code=503,
            detail=(
                "PaddleOCR не установлен. Установите optional зависимости: "
                "python -m pip install -r requirements-paddle.txt"
            ),
        )

    from paddleocr import PaddleOCR

    _paddle_ocr = PaddleOCR(
        lang="ru",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        engine="paddle",
    )
    return _paddle_ocr


def _prepare_image(image_data: bytes) -> Image.Image:
    try:
        image = Image.open(io.BytesIO(image_data))
        image = ImageOps.exif_transpose(image)
        if image.mode != "RGB":
            image = image.convert("RGB")
        return image
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Не удалось прочитать изображение: {e}")


def _resize_for_trocr(image: Image.Image) -> Image.Image:
    if image.width > RESIZE_MAX_DIM or image.height > RESIZE_MAX_DIM:
        image = image.copy()
        image.thumbnail((RESIZE_MAX_DIM, RESIZE_MAX_DIM), Image.Resampling.LANCZOS)
    return image


@app.get("/health")
async def health_check():
    paddle_available = _paddle_available()
    trocr_loaded = processor is not None and model is not None
    return {
        "status": "ok",
        "default_engine": DEFAULT_ENGINE,
        "engines": {
            "trocr": {
                "available": True,
                "loaded": trocr_loaded,
                "device": DEVICE,
                "model_path_exists": os.path.isdir(LOCAL_MODEL_PATH),
            },
            "paddle": {
                "available": paddle_available,
                "loaded": _paddle_ocr is not None,
                "device": "cpu",
                "lang": "ru",
            },
        },
        # Старые поля оставляем для совместимости существующего Flutter-кода.
        "device": DEVICE,
        "cuda_available": CUDA_AVAILABLE,
        "model_loaded": trocr_loaded,
        "model_path_exists": os.path.isdir(LOCAL_MODEL_PATH),
        "dataset_dir_exists": os.path.isdir(DATASET_DIR),
        "labels_file_exists": os.path.isfile(LABELS_FILE),
        "batch_size": BATCH_SIZE,
        "num_beams": NUM_BEAMS,
        "resize_max_dim": RESIZE_MAX_DIM,
    }


def group_boxes_into_lines_and_merge(boxes):
    if not boxes:
        return []
    boxes = sorted(boxes, key=lambda b: b[2])
    lines = []
    current_line = [boxes[0]]
    current_y_center = (boxes[0][2] + boxes[0][3]) / 2

    for box in boxes[1:]:
        box_y_center = (box[2] + box[3]) / 2
        box_height = box[3] - box[2]
        if abs(box_y_center - current_y_center) < (box_height * 0.6):
            current_line.append(box)
        else:
            lines.append(current_line)
            current_line = [box]
            current_y_center = box_y_center
    if current_line:
        lines.append(current_line)

    merged_lines_coords = []
    for line_boxes in lines:
        x_min = min(b[0] for b in line_boxes)
        x_max = max(b[1] for b in line_boxes)
        y_min = min(b[2] for b in line_boxes)
        y_max = max(b[3] for b in line_boxes)
        merged_lines_coords.append([x_min, x_max, y_min, y_max])
    return merged_lines_coords


def process_batch(images):
    if not images:
        return []
    try:
        if DEVICE == "cuda":
            torch.cuda.empty_cache()

        pixel_values = processor(
            images=images,
            return_tensors="pt",
            padding=True,
        ).pixel_values.to(DEVICE)

        with torch.no_grad():
            generated_ids = model.generate(
                pixel_values,
                max_new_tokens=100,
                num_beams=NUM_BEAMS,
                do_sample=False,
                early_stopping=False,
                length_penalty=1.0,
                use_cache=True,
            )

        return processor.batch_decode(generated_ids, skip_special_tokens=True)
    except Exception as e:
        logger.exception("Ошибка в TrOCR батче: %s", e)
        return [""] * len(images)


def recognize_trocr(image: Image.Image) -> OcrResult:
    start = time.perf_counter()
    warnings = []
    image = _resize_for_trocr(image)
    img_w, img_h = image.size
    image_np = np.array(image)

    logger.info("--- TrOCR: 1. Поиск (EasyOCR) ---")
    boxes = detect_reader.detect(
        image_np,
        text_threshold=0.5,
        low_text=0.3,
        link_threshold=0.2,
        canvas_size=RESIZE_MAX_DIM,
        mag_ratio=1.0,
    )[0][0]

    if not boxes:
        return OcrResult(
            text="Текст не найден.",
            engine="trocr",
            lines=[],
            processing_time_ms=int((time.perf_counter() - start) * 1000),
            warnings=warnings,
        )

    line_boxes = group_boxes_into_lines_and_merge(boxes)
    logger.info("TrOCR: найдено строк: %s", len(line_boxes))

    indexed_crops = []
    crop_boxes = []
    for idx, box in enumerate(line_boxes):
        x_min, x_max, y_min, y_max = box
        x_min = max(0, x_min - PADDING)
        x_max = min(img_w, x_max + PADDING)
        y_min = max(0, y_min - PADDING)
        y_max = min(img_h, y_max + PADDING)
        crop = image.crop((x_min, y_min, x_max, y_max))
        indexed_crops.append((idx, crop))
        crop_boxes.append([float(x_min), float(y_min), float(x_max), float(y_max)])

    indexed_crops.sort(key=lambda x: x[1].width, reverse=True)

    logger.info("--- TrOCR: 2. Чтение (PyTorch Greedy) ---")
    results = {}
    sorted_indices = [x[0] for x in indexed_crops]
    sorted_images = [x[1] for x in indexed_crops]

    for i in range(0, len(sorted_images), BATCH_SIZE):
        batch_imgs = sorted_images[i : i + BATCH_SIZE]
        batch_indices = sorted_indices[i : i + BATCH_SIZE]
        logger.info("TrOCR: батч %s", i // BATCH_SIZE + 1)

        recognized_texts = process_batch(batch_imgs)

        for original_idx, text in zip(batch_indices, recognized_texts):
            results[original_idx] = text

    lines = []
    for i, box in enumerate(crop_boxes):
        lines.append(OcrLine(text=results.get(i, ""), confidence=None, box=box))

    final_text = "\n".join(line.text for line in lines)
    if not final_text.strip():
        final_text = "Текст не найден."
        lines = []

    return OcrResult(
        text=final_text,
        engine="trocr",
        lines=lines,
        processing_time_ms=int((time.perf_counter() - start) * 1000),
        warnings=warnings,
    )


def _payload_from_paddle_item(item):
    if isinstance(item, dict):
        return item
    if hasattr(item, "json"):
        try:
            data = item.json
            if isinstance(data, dict):
                return data
        except Exception:
            pass
    if hasattr(item, "res") and isinstance(item.res, dict):
        return item.res
    return {}


def _normalize_paddle_box(box):
    if box is None:
        return None
    arr = np.array(box, dtype=float)
    if arr.size == 0:
        return None
    if arr.ndim == 1 and arr.size >= 4:
        return [float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3])]
    if arr.ndim >= 2 and arr.shape[-1] >= 2:
        xs = arr[..., 0]
        ys = arr[..., 1]
        return [float(xs.min()), float(ys.min()), float(xs.max()), float(ys.max())]
    return None


def _extract_paddle_lines(results) -> list[OcrLine]:
    payloads = [_payload_from_paddle_item(item) for item in (results or [])]
    texts = []
    scores = []
    boxes = []

    for payload in payloads:
        texts.extend(payload.get("rec_texts") or [])
        scores.extend(payload.get("rec_scores") or [])
        raw_boxes = payload.get("rec_boxes")
        if raw_boxes is None:
            raw_boxes = payload.get("dt_polys")
        if raw_boxes is not None:
            boxes.extend(list(raw_boxes))

    lines = []
    for idx, text in enumerate(texts):
        confidence = None
        if idx < len(scores):
            try:
                confidence = float(scores[idx])
            except (TypeError, ValueError):
                confidence = None
        box = _normalize_paddle_box(boxes[idx]) if idx < len(boxes) else None
        lines.append(OcrLine(text=str(text), confidence=confidence, box=box))

    if any(line.box for line in lines):
        lines.sort(
            key=lambda line: (
                line.box[1] if line.box else 0.0,
                line.box[0] if line.box else 0.0,
            )
        )

    return lines


def recognize_paddle(image: Image.Image) -> OcrResult:
    start = time.perf_counter()
    warnings = []
    paddle_ocr = _get_paddle_ocr()
    temp_path = None

    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as tmp:
            temp_path = tmp.name
            image.save(tmp, format="JPEG", quality=95)

        results = paddle_ocr.predict(temp_path)
        lines = _extract_paddle_lines(results)
        final_text = "\n".join(line.text for line in lines if line.text.strip())
        if not final_text.strip():
            final_text = "Текст не найден."
            lines = []

        return OcrResult(
            text=final_text,
            engine="paddle",
            lines=lines,
            processing_time_ms=int((time.perf_counter() - start) * 1000),
            warnings=warnings,
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Paddle inference failed, engine=paddle")
        raise HTTPException(status_code=500, detail=f"Ошибка PaddleOCR inference: {e}")
    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)


@app.post("/ocr")
async def run_ocr(
    file: UploadFile = File(...),
    engine: str = Form(DEFAULT_ENGINE),
):
    selected_engine = (engine or DEFAULT_ENGINE).strip().lower()
    if selected_engine not in SUPPORTED_ENGINES:
        raise HTTPException(
            status_code=400,
            detail=f"Неизвестный OCR engine: {engine}. Допустимо: trocr, paddle.",
        )

    image_data = await file.read()
    image = _prepare_image(image_data)

    if selected_engine == "paddle":
        return recognize_paddle(image).to_response()

    return recognize_trocr(image).to_response()


# === ЭНДПОИНТ ДЛЯ ДООБУЧЕНИЯ ===
@app.post("/feedback")
async def save_feedback(
    file: UploadFile = File(...),
    correct_text: str = Form(...),
):
    try:
        filename = f"{uuid.uuid4()}.jpg"
        filepath = os.path.join(IMAGES_DIR, filename)

        image_data = await file.read()
        with open(filepath, "wb") as f:
            f.write(image_data)

        with open(LABELS_FILE, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow([filename, correct_text])

        logger.info("Сохранено для дообучения: %s", correct_text)
        return {"status": "saved", "filename": filename}
    except Exception as e:
        logger.exception("Ошибка сохранения feedback: %s", e)
        return {"status": "error"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
