from pathlib import Path
import tempfile

from PIL import Image, ImageDraw, ImageFont


def main():
    try:
        from paddleocr import PaddleOCR
    except ImportError as exc:
        raise SystemExit(
            "PaddleOCR is not installed. Run: python -m pip install -r requirements-paddle.txt"
        ) from exc

    ocr = PaddleOCR(
        lang="ru",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        engine="paddle",
    )

    image = Image.new("RGB", (420, 120), "white")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("arial.ttf", 36)
    except OSError:
        font = ImageFont.load_default()
    draw.text((24, 36), "Проверка OCR", fill="black", font=font)

    with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as tmp:
        temp_path = Path(tmp.name)
        image.save(tmp, format="JPEG", quality=95)

    try:
        ocr.predict(str(temp_path))
    finally:
        temp_path.unlink(missing_ok=True)

    print("PaddleOCR ready")


if __name__ == "__main__":
    main()
