from fastapi import FastAPI, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware # <--- ИМПОРТ
from transformers import TrOCRProcessor, VisionEncoderDecoderModel
from PIL import Image, ImageOps
import io
import torch
import easyocr
import numpy as np
import os
import uuid
import csv
import shutil

app = FastAPI()

# === РАЗРЕШАЕМ ДОСТУП ИЗ ИНТЕРНЕТА (CORS) ===
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Разрешить всем
    allow_credentials=True,
    allow_methods=["*"],  # Разрешить любые методы (POST, GET)
    allow_headers=["*"],  # Разрешить любые заголовки
)
# ============================================

# === НАСТРОЙКИ ===
LOCAL_MODEL_PATH = r"C:\Users\pvppv\Desktop\roo\myscribe_backend\trocr-handwritten-cyrillic"

# ДЛЯ FEEDBACK (СБОР ДАННЫХ)
DATASET_DIR = "dataset"
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
    with open(LABELS_FILE, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(["filename", "text"])

# НАСТРОЙКИ СКОРОСТИ
# 4 - нормально для GTX 1650 (FP32) при Greedy Search
BATCH_SIZE = 4
RESIZE_MAX_DIM = 1280
PADDING = 10

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
print(f"=== УСТРОЙСТВО: {DEVICE} (PyTorch Native Speed) ===")

print("1. Настройка EasyOCR...")
detect_reader = easyocr.Reader(['ru'], gpu=(DEVICE == "cuda"), quantize=False) 

print("2. Загрузка TrOCR (PyTorch)...")
try:
    processor = TrOCRProcessor.from_pretrained(LOCAL_MODEL_PATH, local_files_only=True)
    model = VisionEncoderDecoderModel.from_pretrained(LOCAL_MODEL_PATH, local_files_only=True)
    model.to(DEVICE)
    # .half() НЕ используем (тормозит на 1650)
    model.eval()
    print("TrOCR готов!")
except Exception as e:
    print(f"Ошибка: {e}")
    exit(1)

def group_boxes_into_lines_and_merge(boxes):
    if not boxes: return []
    boxes = sorted(boxes, key=lambda b: b[2])
    lines = []
    current_line = []
    current_line.append(boxes[0])
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
    if current_line: lines.append(current_line)
    
    merged_lines_coords = []
    for line_boxes in lines:
        x_min = min(b[0] for b in line_boxes)
        x_max = max(b[1] for b in line_boxes)
        y_min = min(b[2] for b in line_boxes)
        y_max = max(b[3] for b in line_boxes)
        merged_lines_coords.append([x_min, x_max, y_min, y_max])
    return merged_lines_coords

def process_batch(images):
    if not images: return []
    try:
        # Чистим кэш CUDA перед запуском (важно для 4GB)
        torch.cuda.empty_cache()
        
        pixel_values = processor(images=images, return_tensors="pt", padding=True).pixel_values.to(DEVICE)
        
        with torch.no_grad():
            # GREEDY SEARCH (Быстро и эффективно)
            generated_ids = model.generate(
                pixel_values, 
                max_new_tokens=100,
                num_beams=4,         # 1 луч = скорость
                do_sample=False,
                early_stopping=False,
                length_penalty=1.0,
                use_cache=True
            )
            
        texts = processor.batch_decode(generated_ids, skip_special_tokens=True)
        return texts
    except Exception as e:
        print(f"Ошибка в батче: {e}")
        return [""] * len(images)

@app.post("/ocr")
async def run_ocr(file: UploadFile = File(...)):
    try:
        image_data = await file.read()
        image = Image.open(io.BytesIO(image_data))
        image = ImageOps.exif_transpose(image)
        if image.mode != "RGB": image = image.convert("RGB")

        if image.width > RESIZE_MAX_DIM or image.height > RESIZE_MAX_DIM:
            image.thumbnail((RESIZE_MAX_DIM, RESIZE_MAX_DIM), Image.Resampling.LANCZOS)
        
        img_w, img_h = image.size
        image_np = np.array(image)

        print("--- 1. Поиск (EasyOCR) ---")
        boxes = detect_reader.detect(image_np, 
                                     text_threshold=0.5, 
                                     low_text=0.3, 
                                     link_threshold=0.2,
                                     canvas_size=RESIZE_MAX_DIM, 
                                     mag_ratio=1.0)[0][0]
        
        if not boxes: return {"text": "Текст не найден."}

        line_boxes = group_boxes_into_lines_and_merge(boxes)
        print(f"Найдено строк: {len(line_boxes)}")
        
        indexed_crops = []
        for idx, box in enumerate(line_boxes):
            x_min, x_max, y_min, y_max = box
            x_min = max(0, x_min - PADDING)
            x_max = min(img_w, x_max + PADDING)
            y_min = max(0, y_min - PADDING)
            y_max = min(img_h, y_max + PADDING)
            crop = image.crop((x_min, y_min, x_max, y_max))
            indexed_crops.append( (idx, crop) )

        # Smart Batching: сортировка по ширине
        indexed_crops.sort(key=lambda x: x[1].width, reverse=True)

        print(f"--- 2. Чтение (PyTorch Greedy) ---")
        results = {}
        sorted_indices = [x[0] for x in indexed_crops]
        sorted_images = [x[1] for x in indexed_crops]
        
        for i in range(0, len(sorted_images), BATCH_SIZE):
            batch_imgs = sorted_images[i : i + BATCH_SIZE]
            batch_indices = sorted_indices[i : i + BATCH_SIZE]
            print(f"   Батч {i // BATCH_SIZE + 1}...")
            
            recognized_texts = process_batch(batch_imgs)
            
            for original_idx, text in zip(batch_indices, recognized_texts):
                results[original_idx] = text

        final_lines = []
        for i in range(len(line_boxes)):
            final_lines.append(results.get(i, ""))

        final_text = "\n".join(final_lines)
        print("--- Готово ---")
        return {"text": final_text}

    except Exception as e:
        print(f"Error: {e}")
        return {"text": f"Error: {e}"}

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
            
        with open(LABELS_FILE, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow([filename, correct_text])
            
        print(f"Сохранено для дообучения: {correct_text}")
        return {"status": "saved", "filename": filename}
    except Exception as e:
        print(f"Ошибка сохранения: {e}")
        return {"status": "error"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
