# myscribe_app

## API endpoint configuration

The app reads backend address from `--dart-define=API_BASE_URL=...`.

If `API_BASE_URL` is not provided, defaults are:
- Windows/macOS/Linux: `http://127.0.0.1:8000`
- Android emulator: `http://10.0.2.2:8000`
- iOS simulator / Web: `http://127.0.0.1:8000`

OCR and feedback endpoints are built automatically:
- `${API_BASE_URL}/ocr`
- `${API_BASE_URL}/feedback`

## Run examples

Desktop local debug (backend on same PC):
```bash
flutter run -d windows
```

Phone via Tailscale:
```bash
flutter run --dart-define=API_BASE_URL=http://<tailscale-ip>:8000
```

Android emulator with explicit override:
```bash
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000
```
