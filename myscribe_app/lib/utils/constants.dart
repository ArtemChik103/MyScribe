// lib/utils/constants.dart

class AppConstants {
  // --- Database Constants ---
  static const String databaseName = "MyScribe.db";
  static const int databaseVersion = 1;
  static const String tableDocuments = 'documents';
  static const String tableCorrections = 'corrections';

  // --- Asset Paths ---
  static const String modelPath = 'assets/ocr_model.tflite';
  static const String alphabetPath = 'assets/alphabet.txt';
  static const String ruDictionaryPath = 'assets/ru_dict.txt';
  static const String enDictionaryPath = 'assets/en_dict.txt';

  // --- ML Model Constants ---
  static const int modelInputHeight = 384;
  static const int modelInputWidth = 384;
}