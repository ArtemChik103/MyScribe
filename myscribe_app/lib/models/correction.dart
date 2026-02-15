class Correction {
  final int? id;
  final String documentId;
  final String imageFragmentPath;
  final String correctedText;

  Correction({
    this.id,
    required this.documentId,
    required this.imageFragmentPath,
    required this.correctedText,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'documentId': documentId,
      'imageFragmentPath': imageFragmentPath,
      'correctedText': correctedText,
    };
  }
}