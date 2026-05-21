# MyScribe

MyScribe - приложение для распознавания рукописного русского текста с телефона.
Проект состоит из Flutter-клиента и Python FastAPI backend. Телефон отправляет
фото на backend, backend распознает текст выбранным OCR-движком, после чего
приложение сохраняет документ локально.

## Что внутри

- `myscribe_app` - Flutter-приложение для Android, Windows и других платформ.
- `myscribe_backend` - OCR API на FastAPI.
- `myscribe_backend/trocr-handwritten-cyrillic` - локальная папка модели TrOCR.
- `myscribe_backend/dataset` - локальные исправления пользователя и фрагменты
  изображений для сбора данных. Дообучение в текущем проекте не запускается.

## OCR-режимы

В приложении на экране `API и сервер` можно выбрать один из двух режимов:

- `TrOCR` - основной режим по умолчанию. EasyOCR ищет строки, TrOCR распознает
  crop-строки. Обычно лучше подходит для рукописного текста, но тяжелее.
- `PaddleOCR` - optional альтернативный локальный режим. Он подключается только
  при выборе `engine=paddle` и рассчитан на CPU-first установку.

PaddleOCR не является обязательной зависимостью. Обычный backend с TrOCR должен
стартовать и работать без установленного PaddleOCR.

## Backend

Установить зависимости:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_backend
python -m pip install -r requirements.txt
```

Опционально установить PaddleOCR:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_backend
python -m pip install -r requirements-paddle.txt
python .\tools\warmup_paddle.py
```

Запустить backend для телефона по USB через `adb reverse`:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_backend
python -m uvicorn main:app --host 127.0.0.1 --port 8000
```

Запустить backend для показа через Tailscale или локальную сеть:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_backend
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Проверить состояние backend:

```powershell
curl http://127.0.0.1:8000/health
```

Ожидаемый ответ содержит `status`, `device`, `cuda_available`,
`model_loaded`, состояние папки модели и dataset. Новый ответ также содержит
`default_engine` и `engines.trocr` / `engines.paddle`.

Пример OCR-запроса с PaddleOCR:

```powershell
curl -X POST -F "engine=paddle" -F "file=@sample.jpg" http://127.0.0.1:8000/ocr
```

Без поля `engine` backend использует `trocr`.

## Flutter-приложение

Установить зависимости Flutter:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_app
flutter pub get
```

Запустить на Android-телефоне по USB:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_app
adb reverse tcp:8000 tcp:8000
flutter run -d 97c3a7ce
```

При USB-сценарии в приложении выберите preset `USB` на экране
`API и сервер`, если активный URL не равен `http://127.0.0.1:8000`.

Запустить для демонстрации через Tailscale:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_app
flutter run -d 97c3a7ce
```

Android-дефолт приложения - `http://100.95.221.105:8000`, потому что этот адрес
используется для демонстраций через Tailscale. Его можно изменить внутри
приложения на экране `API и сервер`.

## Настройка API

Приложение выбирает backend URL в таком порядке:

1. URL, сохраненный в экране `API и сервер`.
2. `--dart-define=API_BASE_URL=...`.
3. Дефолт платформы.

Дефолты:

- Android: `http://100.95.221.105:8000` для Tailscale.
- Windows, Linux, macOS, iOS, Web: `http://127.0.0.1:8000`.

Быстрые presets в приложении:

- `Tailscale` - `http://100.95.221.105:8000`.
- `USB` - `http://127.0.0.1:8000`.
- `Сброс` - вернуть дефолт платформы или `dart-define`.

## Проверки перед показом

Backend:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_backend
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Flutter:

```powershell
cd C:\Users\pvppv\Desktop\roo\MyScribe\myscribe_app
flutter analyze
flutter build apk --debug
```

В приложении откройте `API и сервер`, нажмите `Проверить сервер` и убедитесь,
что сервер доступен, модель загружена, а `Device` показывает `cuda` или `cpu`.

## Как сравнивать TrOCR и PaddleOCR

1. Выберите один и тот же снимок.
2. На экране `API и сервер` выберите `TrOCR` и распознайте документ.
3. Переключите engine на `PaddleOCR` и распознайте тот же снимок повторно.
4. Сравните скорость, количество строк и качество текста в созданных
   документах. В списке и деталях документа сохраняется chip с engine.

## Важные заметки

- Модель не хранится в git и должна лежать в
  `myscribe_backend/trocr-handwritten-cyrillic`.
- PaddleOCR CPU-first нужен для стабильности установки; GPU-ускорение PaddleOCR
  не входит в этот этап.
- Dataset и пользовательские изображения не нужно коммитить.
- Окно backend должно оставаться открытым, пока приложение распознает текст.
- Если сборка Android снова ругается на NDK, проверьте установленную версию NDK
  в Android Studio и настройку проекта.
