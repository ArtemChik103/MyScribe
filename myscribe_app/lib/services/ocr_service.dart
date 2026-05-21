import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:myscribe_app/services/api_settings_service.dart';

enum OcrProcessingStage { sending, processing, parsing }

class OcrRequestException implements Exception {
  final String message;

  const OcrRequestException(this.message);

  @override
  String toString() => message;
}

class BackendEngineHealth {
  final bool available;
  final bool loaded;
  final String device;
  final bool? modelPathExists;
  final String? lang;

  const BackendEngineHealth({
    required this.available,
    required this.loaded,
    required this.device,
    this.modelPathExists,
    this.lang,
  });

  factory BackendEngineHealth.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const BackendEngineHealth(
        available: false,
        loaded: false,
        device: 'unknown',
      );
    }

    return BackendEngineHealth(
      available: json['available'] == true,
      loaded: json['loaded'] == true,
      device: json['device']?.toString() ?? 'unknown',
      modelPathExists: json['model_path_exists'] is bool
          ? json['model_path_exists'] as bool
          : null,
      lang: json['lang']?.toString(),
    );
  }
}

class BackendHealth {
  final String status;
  final String defaultEngine;
  final Map<String, BackendEngineHealth> engines;
  final String device;
  final bool cudaAvailable;
  final bool modelLoaded;
  final bool modelPathExists;
  final bool datasetDirExists;
  final bool labelsFileExists;
  final int batchSize;
  final int resizeMaxDim;

  const BackendHealth({
    required this.status,
    required this.defaultEngine,
    required this.engines,
    required this.device,
    required this.cudaAvailable,
    required this.modelLoaded,
    required this.modelPathExists,
    required this.datasetDirExists,
    required this.labelsFileExists,
    required this.batchSize,
    required this.resizeMaxDim,
  });

  factory BackendHealth.fromJson(Map<String, dynamic> json) {
    final rawEngines = json['engines'];
    final engines = <String, BackendEngineHealth>{};
    if (rawEngines is Map<String, dynamic>) {
      for (final entry in rawEngines.entries) {
        final value = entry.value;
        engines[entry.key] = BackendEngineHealth.fromJson(
          value is Map<String, dynamic> ? value : null,
        );
      }
    }

    return BackendHealth(
      status: json['status']?.toString() ?? 'unknown',
      defaultEngine: json['default_engine']?.toString() ?? 'trocr',
      engines: engines,
      device: json['device']?.toString() ?? 'unknown',
      cudaAvailable: json['cuda_available'] == true,
      modelLoaded: json['model_loaded'] == true,
      modelPathExists: json['model_path_exists'] == true,
      datasetDirExists: json['dataset_dir_exists'] == true,
      labelsFileExists: json['labels_file_exists'] == true,
      batchSize: json['batch_size'] is int ? json['batch_size'] as int : 0,
      resizeMaxDim: json['resize_max_dim'] is int
          ? json['resize_max_dim'] as int
          : 0,
    );
  }
}

class OcrService {
  OcrService({required ApiSettingsService apiSettings})
    : _apiSettings = apiSettings;

  final ApiSettingsService _apiSettings;

  Future<String> runOCR(
    Uint8List imageBytes, {
    void Function(OcrProcessingStage stage)? onStage,
  }) async {
    try {
      final uri = _apiSettings.ocrUri;
      debugPrint('OCR request -> $uri');

      // Создаем Multipart запрос
      final request = http.MultipartRequest('POST', uri);
      request.fields['engine'] = _apiSettings.ocrEngine.name;

      // Добавляем файл
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: 'upload.jpg',
        ),
      );

      // Отправляем
      onStage?.call(OcrProcessingStage.sending);
      final streamedResponse = await request.send();
      onStage?.call(OcrProcessingStage.processing);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        onStage?.call(OcrProcessingStage.parsing);
        final Map<String, dynamic> data = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        final String text = data['text'] ?? "";
        debugPrint(
          'OCR success (${data['engine'] ?? _apiSettings.ocrEngine.name}), '
          'text length: ${text.length}',
        );
        return text;
      }

      final responseBody = utf8.decode(response.bodyBytes);
      debugPrint('OCR error ${response.statusCode}: $responseBody');
      var detail = 'Проверьте доступность OCR API.';
      try {
        final decoded = jsonDecode(responseBody);
        if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      throw OcrRequestException(
        'Сервер вернул ${response.statusCode}. $detail',
      );
    } on http.ClientException catch (e) {
      debugPrint('OCR client exception: $e');
      throw Exception(
        'Ошибка соединения с сервером (${_apiSettings.effectiveBaseUrl}). '
        'Проверьте адрес API в настройках приложения.',
      );
    } on OcrRequestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      debugPrint('OCR unexpected error: $e');
      throw Exception(
        'Ошибка OCR (${_apiSettings.effectiveBaseUrl}). '
        'Проверьте, что backend запущен и доступен.',
      );
    }
  }

  Future<BackendHealth> checkHealth() async {
    final response = await http
        .get(_apiSettings.healthUri)
        .timeout(const Duration(seconds: 5));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Сервер вернул ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) {
      throw Exception('Некорректный ответ health endpoint');
    }

    return BackendHealth.fromJson(data);
  }

  Future<void> sendFeedback({
    required String fragmentPath,
    required String correctedText,
  }) async {
    final request = http.MultipartRequest('POST', _apiSettings.feedbackUri);
    request.fields['correct_text'] = correctedText;
    request.files.add(await http.MultipartFile.fromPath('file', fragmentPath));
    final response = await request.send();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw Exception('Сервер вернул ${response.statusCode}');
  }

  void dispose() {
    // Ничего закрывать не нужно
  }
}
