class Document {
  final String id;
  final String imagePath;
  String recognizedText;
  final DateTime createdAt;

  Document({
    required this.id,
    required this.imagePath,
    required this.recognizedText,
    required this.createdAt,
  });

  // Для преобразования из Map (из БД) в объект Document
  factory Document.fromMap(Map<String, dynamic> map) {
    return Document(
      id: map['id'],
      imagePath: map['imagePath'],
      recognizedText: map['recognizedText'],
      createdAt: DateTime.parse(map['createdAt']),
    );
  }

  // Для преобразования объекта Document в Map (для записи в БД)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'imagePath': imagePath,
      'recognizedText': recognizedText,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}