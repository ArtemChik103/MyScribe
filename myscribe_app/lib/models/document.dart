class Document {
  final String id;
  final String imagePath;
  String recognizedText;
  final DateTime createdAt;
  bool requiresReview;

  Document({
    required this.id,
    required this.imagePath,
    required this.recognizedText,
    required this.createdAt,
    this.requiresReview = false,
  });

  // Для преобразования из Map (из БД) в объект Document
  factory Document.fromMap(Map<String, dynamic> map) {
    final rawRequiresReview = map['requiresReview'];
    final requiresReview = rawRequiresReview is int
        ? rawRequiresReview == 1
        : rawRequiresReview == true;

    return Document(
      id: map['id'],
      imagePath: map['imagePath'],
      recognizedText: map['recognizedText'],
      createdAt: DateTime.parse(map['createdAt']),
      requiresReview: requiresReview,
    );
  }

  // Для преобразования объекта Document в Map (для записи в БД)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'imagePath': imagePath,
      'recognizedText': recognizedText,
      'createdAt': createdAt.toIso8601String(),
      'requiresReview': requiresReview ? 1 : 0,
    };
  }
}
