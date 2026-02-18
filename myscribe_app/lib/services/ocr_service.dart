import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:myscribe_app/config/api_config.dart';

enum OcrProcessingStage { sending, processing, parsing }

class OcrService {
  Future<String> runOCR(
    Uint8List imageBytes, {
    void Function(OcrProcessingStage stage)? onStage,
  }) async {
    try {
      final uri = ApiConfig.ocrUri;
      debugPrint('OCR request -> $uri');

      // Создаем Multipart запрос
      final request = http.MultipartRequest('POST', uri);

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
        debugPrint('OCR success, text length: ${text.length}');
        return text;
      }

      final responseBody = utf8.decode(response.bodyBytes);
      debugPrint('OCR error ${response.statusCode}: $responseBody');
      throw Exception(
        'Сервер вернул ${response.statusCode}. '
        'Проверьте доступность OCR API.',
      );
    } on http.ClientException catch (e) {
      debugPrint('OCR client exception: $e');
      throw Exception(
        'Ошибка соединения с сервером (${ApiConfig.baseUrl}). '
        'Для ПК: http://127.0.0.1:8000. '
        'Для телефона можно передать --dart-define=API_BASE_URL=http://<ip>:8000.',
      );
    } catch (e) {
      debugPrint('OCR unexpected error: $e');
      throw Exception(
        'Ошибка OCR (${ApiConfig.baseUrl}). '
        'Проверьте, что backend запущен и доступен.',
      );
    }
  }

  void dispose() {
    // Ничего закрывать не нужно
  }
}
