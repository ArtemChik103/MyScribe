import 'package:flutter/foundation.dart';

class ApiConfig {
  static const String androidTailscaleBaseUrl = 'http://100.95.221.105:8000';
  static const String usbReverseBaseUrl = 'http://127.0.0.1:8000';

  static const String dartDefineBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  static String get platformDefaultBaseUrl {
    if (kIsWeb) {
      return usbReverseBaseUrl;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return androidTailscaleBaseUrl;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return usbReverseBaseUrl;
    }
  }

  static String normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
