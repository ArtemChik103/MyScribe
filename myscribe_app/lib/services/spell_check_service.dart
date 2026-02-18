// Файл: lib/services/spell_check_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:myscribe_app/utils/constants.dart';

class SpellCheckService {
  final Set<String> _russianWords = {};
  final Set<String> _englishWords = {};

  Future<void> loadDictionaries() async {
    try {
      final ruContent = await _loadAndCleanAsset(AppConstants.ruDictionaryPath);
      _russianWords.addAll(ruContent.split('\n').map((e) => e.trim().toLowerCase()));

      final enContent = await _loadAndCleanAsset(AppConstants.enDictionaryPath);
      _englishWords.addAll(enContent.split('\n').map((e) => e.trim().toLowerCase()));

      debugPrint(
        'Словари загружены: ${_russianWords.length} русских, '
        '${_englishWords.length} английских.',
      );
    } catch (e) {
      debugPrint('Ошибка загрузки словарей: $e');
    }
  }

  // БОЛЕЕ НАДЕЖНАЯ ВЕРСИЯ ДЕКОДЕРА
  Future<String> _loadAndCleanAsset(String assetPath) async {
    final byteData = await rootBundle.load(assetPath);
    final bytes = byteData.buffer.asUint8List();

    // Используем Utf8Decoder с параметром, который игнорирует ошибки кодировки
    // Это должно решить проблему раз и навсегда.
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }

  List<String> checkText(String text) {
    // ... остальной код без изменений
    final misspelledWords = <String>[];
    final wordRegex = RegExp(r"[\w'-]+", unicode: true);

    final words = wordRegex.allMatches(text).map((m) => m.group(0)!).toList();

    for (final word in words) {
      final lowerWord = word.toLowerCase();
      if (!_russianWords.contains(lowerWord) && !_englishWords.contains(lowerWord)) {
        misspelledWords.add(word);
      }
    }
    return misspelledWords;
  }
}
