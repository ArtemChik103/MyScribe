import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:myscribe_app/config/api_config.dart';

class OcrService {
  /// Метод оставлен для совместимости, но теперь он ничего не делает,
  /// так как модель грузится на сервере.
  Future<void> loadModel({String? customModelPath}) async {
    print(
      "Используется удаленный сервер. Загрузка модели на клиенте не требуется.",
    );
  }

  Future<String> runOCR(Uint8List imageBytes) async {
    try {
      final uri = ApiConfig.ocrUri;
      print("Отправка изображения на сервер: $uri");

      // Создаем Multipart запрос
      var request = http.MultipartRequest('POST', uri);

      // Добавляем файл
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: 'upload.jpg',
        ),
      );

      // Отправляем
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        // Успех, парсим JSON
        // Ожидаемый ответ от сервера: {"text": "Распознанный текст"}
        final Map<String, dynamic> data = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        final String text = data['text'] ?? "";
        print("Ответ сервера: $text");
        return text;
      } else {
        print("Ошибка сервера: ${response.statusCode} ${response.body}");
        return "Ошибка сервера: ${response.statusCode}";
      }
    } on http.ClientException catch (e) {
      print("Ошибка соединения (ClientException): $e");
      return "Ошибка соединения с сервером (${ApiConfig.baseUrl}). Для отладки на ПК используйте http://127.0.0.1:8000, для телефона через Tailscale передайте --dart-define=API_BASE_URL=http://<tailscale-ip>:8000.";
    } catch (e) {
      print("Ошибка соединения: $e");
      return "Ошибка соединения с сервером (${ApiConfig.baseUrl}). Проверьте, что backend запущен и доступен.";
    }
  }

  void dispose() {
    // Ничего закрывать не нужно
  }
}
