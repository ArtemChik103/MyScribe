import 'package:flutter/foundation.dart';
import 'package:myscribe_app/config/api_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum OcrEngine {
  trocr,
  paddle;

  String get label {
    return switch (this) {
      OcrEngine.trocr => 'TrOCR',
      OcrEngine.paddle => 'PaddleOCR',
    };
  }

  static OcrEngine fromName(String? value) {
    return OcrEngine.values.firstWhere(
      (engine) => engine.name == value,
      orElse: () => OcrEngine.trocr,
    );
  }
}

class ApiSettingsService extends ChangeNotifier {
  static const String _customBaseUrlKey = 'api.customBaseUrl';
  static const String _ocrEngineKey = 'ocr.engine';

  ApiSettingsService._(this._prefs);

  final SharedPreferences _prefs;
  String? _customBaseUrl;
  OcrEngine _ocrEngine = OcrEngine.trocr;

  static Future<ApiSettingsService> create() async {
    final prefs = await SharedPreferences.getInstance();
    final service = ApiSettingsService._(prefs);
    service._customBaseUrl = prefs.getString(_customBaseUrlKey);
    service._ocrEngine = OcrEngine.fromName(prefs.getString(_ocrEngineKey));
    return service;
  }

  String? get customBaseUrl => _customBaseUrl;

  OcrEngine get ocrEngine => _ocrEngine;

  bool get hasCustomBaseUrl {
    return _customBaseUrl != null && _customBaseUrl!.trim().isNotEmpty;
  }

  String get effectiveBaseUrl {
    if (hasCustomBaseUrl) {
      return _customBaseUrl!;
    }

    final dartDefineUrl = ApiConfig.dartDefineBaseUrl.trim();
    if (dartDefineUrl.isNotEmpty) {
      return ApiConfig.normalizeBaseUrl(dartDefineUrl);
    }

    return ApiConfig.platformDefaultBaseUrl;
  }

  Uri get ocrUri => Uri.parse('$effectiveBaseUrl/ocr');

  Uri get feedbackUri => Uri.parse('$effectiveBaseUrl/feedback');

  Uri get healthUri => Uri.parse('$effectiveBaseUrl/health');

  Future<void> setCustomBaseUrl(String value) async {
    final normalized = ApiConfig.normalizeBaseUrl(value);
    if (normalized.isEmpty) {
      await resetCustomBaseUrl();
      return;
    }

    _customBaseUrl = normalized;
    await _prefs.setString(_customBaseUrlKey, normalized);
    notifyListeners();
  }

  Future<void> resetCustomBaseUrl() async {
    _customBaseUrl = null;
    await _prefs.remove(_customBaseUrlKey);
    notifyListeners();
  }

  Future<void> setOcrEngine(OcrEngine engine) async {
    if (_ocrEngine == engine) return;
    _ocrEngine = engine;
    await _prefs.setString(_ocrEngineKey, engine.name);
    notifyListeners();
  }
}
