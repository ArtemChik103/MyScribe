import 'dart:io';

import 'package:myscribe_app/models/correction.dart';
import 'package:myscribe_app/models/document.dart';
import 'package:myscribe_app/utils/constants.dart'; // <-- ИМПОРТ
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseService {
  // Создаем синглтон
  DatabaseService._privateConstructor();
  static final DatabaseService instance = DatabaseService._privateConstructor();

  static Database? _database;
  Future<Database> get database async => _database ??= await initDB();

  Future<Database> initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, AppConstants.databaseName); // <-- ИСПОЛЬЗОВАНИЕ
    return await openDatabase(
      path,
      version: AppConstants.databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    ); // <-- ИСПОЛЬЗОВАНИЕ
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.tableDocuments} (
        id TEXT PRIMARY KEY,
        imagePath TEXT NOT NULL,
        recognizedText TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        requiresReview INTEGER NOT NULL DEFAULT 0
      )
    '''); // <-- ИСПОЛЬЗОВАНИЕ
    await db.execute('''
      CREATE TABLE ${AppConstants.tableCorrections} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        documentId TEXT NOT NULL,
        imageFragmentPath TEXT NOT NULL,
        correctedText TEXT NOT NULL,
        FOREIGN KEY (documentId) REFERENCES ${AppConstants.tableDocuments} (id) ON DELETE CASCADE
      )
    '''); // <-- ИСПОЛЬЗОВАНИЕ
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE ${AppConstants.tableDocuments} '
        'ADD COLUMN requiresReview INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  // CRUD для Документов
  Future<void> insertDocument(Document doc) async {
    final db = await database;
    await db.insert(
      AppConstants.tableDocuments, // <-- ИСПОЛЬЗОВАНИЕ
      doc.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Document>> getDocuments() async {
    final db = await database;
    final maps = await db.query(
      AppConstants.tableDocuments,
      orderBy: 'createdAt DESC',
    ); // <-- ИСПОЛЬЗОВАНИЕ
    return List.generate(maps.length, (i) => Document.fromMap(maps[i]));
  }

  Future<void> updateDocumentText(String id, String newText) async {
    final db = await database;
    await db.update(
      AppConstants.tableDocuments, // <-- ИСПОЛЬЗОВАНИЕ
      {'recognizedText': newText},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateDocumentRequiresReview(String id, bool requiresReview) async {
    final db = await database;
    await db.update(
      AppConstants.tableDocuments,
      {'requiresReview': requiresReview ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteDocument(String id) async {
    final db = await database;
    await db.delete(
      AppConstants.tableDocuments, // <-- ИСПОЛЬЗОВАНИЕ
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteBrokenDocuments() async {
    final documents = await getDocuments();
    var deletedCount = 0;

    for (final doc in documents) {
      final fileExists = await File(doc.imagePath).exists();
      if (!fileExists) {
        await deleteDocument(doc.id);
        deletedCount++;
      }
    }

    return deletedCount;
  }

  // CRUD для Коррекций
  Future<void> insertCorrection(Correction correction) async {
    final db = await database;
    await db.insert(
      AppConstants.tableCorrections, // <-- ИСПОЛЬЗОВАНИЕ
      correction.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getCorrections() async {
    final db = await database;
    final result = await db.query(
      AppConstants.tableCorrections,
    ); // <-- ИСПОЛЬЗОВАНИЕ
    return result
        .map(
          (row) => {
            "image_fragment_path": row['imageFragmentPath'],
            "corrected_text": row['correctedText'],
          },
        )
        .toList();
  }
}
