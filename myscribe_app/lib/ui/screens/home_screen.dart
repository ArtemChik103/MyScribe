import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myscribe_app/models/document.dart';
import 'package:myscribe_app/services/database_service.dart';
import 'package:myscribe_app/services/ocr_service.dart';
import 'package:myscribe_app/ui/screens/document_detail_screen.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const double _thumbnailSize = 50;
  final ImagePicker _picker = ImagePicker();
  List<Document> _documents = [];
  bool _isLoadingDocuments = true;
  String? _loadError;
  final Set<String> _deletingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _initializeScreen();
  }

  Future<void> _initializeScreen() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    final deletedCount = await dbService.deleteBrokenDocuments();
    if (!mounted) return;
    await _loadDocuments();
    if (!mounted) return;

    if (deletedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Удалено поврежденных документов: $deletedCount'),
        ),
      );
    }
  }

  Future<void> _loadDocuments() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    setState(() {
      _isLoadingDocuments = true;
      _loadError = null;
    });

    try {
      final docs = await dbService.getDocuments();
      if (!mounted) return;
      setState(() {
        _documents = docs;
        _isLoadingDocuments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoadingDocuments = false;
      });
    }
  }

  Future<void> _cleanupBrokenDocuments() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    final deletedCount = await dbService.deleteBrokenDocuments();
    if (!mounted) return;
    await _loadDocuments();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Удалено поврежденных документов: $deletedCount')),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    // Запрос разрешений
    if (source == ImageSource.camera) {
      await Permission.camera.request();
    } else {
      await Permission.photos.request();
    }

    final XFile? image = await _picker.pickImage(source: source);
    if (image == null || !mounted) return;

    final ocrService = Provider.of<OcrService>(context, listen: false);
    final dbService = Provider.of<DatabaseService>(context, listen: false);

    // Показываем индикатор загрузки
    _showLoadingDialog("Распознавание текста...");

    String persistentImagePath = '';
    var hasPersistentImage = false;
    String recognizedText;
    try {
      persistentImagePath = await _persistPickedImage(image);
      hasPersistentImage = true;
      final imageBytes = await File(persistentImagePath).readAsBytes();
      recognizedText = await ocrService.runOCR(imageBytes);
    } catch (e) {
      if (hasPersistentImage) {
        try {
          await File(persistentImagePath).delete();
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка обработки изображения: $e')),
        );
      }
      return;
    } finally {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    final newDoc = Document(
      id: const Uuid().v4(),
      imagePath: persistentImagePath,
      recognizedText: recognizedText,
      createdAt: DateTime.now(),
    );

    await dbService.insertDocument(newDoc);
    if (!mounted) return;
    await _loadDocuments();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => DocumentDetailScreen(document: newDoc),
      ),
    );
    if (!mounted) return;
    await _loadDocuments();
  }

  void _showLoadingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Text(message),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteDocument(String id) async {
    if (_deletingIds.contains(id)) return;

    final dbService = Provider.of<DatabaseService>(context, listen: false);
    final docIndex = _documents.indexWhere((doc) => doc.id == id);
    final imagePath = docIndex >= 0 ? _documents[docIndex].imagePath : null;
    setState(() {
      _deletingIds.add(id);
    });

    try {
      await dbService.deleteDocument(id);
      if (imagePath != null) {
        try {
          final imageFile = File(imagePath);
          if (await imageFile.exists()) {
            await imageFile.delete();
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _documents.removeWhere((doc) => doc.id == id);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Документ удален')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка удаления: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _deletingIds.remove(id);
        });
      }
    }
  }

  Future<void> _exportData() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    final corrections = await dbService.getCorrections();

    if (corrections.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Нет данных для экспорта.')));
      return;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final exportDir = Directory(
      '${appDir.path}/export_${DateTime.now().millisecondsSinceEpoch}',
    );
    final imagesDir = Directory('${exportDir.path}/images');
    await imagesDir.create(recursive: true);

    // Копирование изображений-фрагментов
    for (var correction in corrections) {
      final sourcePath = correction['image_fragment_path'] as String;
      final file = File(sourcePath);
      if (await file.exists()) {
        final fileName = sourcePath.split('/').last;
        await file.copy('${imagesDir.path}/$fileName');
      }
    }

    // Создание JSON-файла
    final jsonContent = jsonEncode(corrections);
    final jsonFile = File('${exportDir.path}/corrections.json');
    await jsonFile.writeAsString(jsonContent);

    // Share JSON
    await Share.shareXFiles(
      [XFile(jsonFile.path)],
      text:
          'Данные для дообучения. Папка с изображениями находится в: ${imagesDir.path}',
    );
  }

  Future<void> _loadCustomModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any, // .tflite не поддерживается как тип
    );

    if (!mounted) return;

    if (result != null && result.files.single.path != null) {
      final filePath = result.files.single.path!;
      if (!filePath.endsWith('.tflite')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Пожалуйста, выберите файл с расширением .tflite'),
          ),
        );
        return;
      }

      _showLoadingDialog("Загрузка новой модели...");
      final ocrService = Provider.of<OcrService>(context, listen: false);
      try {
        await ocrService.loadModel(customModelPath: filePath);
      } finally {
        if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Новая модель успешно загружена!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MyScribe Документы'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload),
            tooltip: 'Загрузить модель',
            onPressed: _loadCustomModel,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: 'Очистить поврежденные',
            onPressed: _cleanupBrokenDocuments,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Экспорт данных',
            onPressed: _exportData,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            onPressed: () => _pickImage(ImageSource.gallery),
            label: const Text('Галерея'),
            icon: const Icon(Icons.photo_library),
            heroTag: 'gallery',
          ),
          const SizedBox(width: 10),
          FloatingActionButton.extended(
            onPressed: () => _pickImage(ImageSource.camera),
            label: const Text('Камера'),
            icon: const Icon(Icons.camera_alt),
            heroTag: 'camera',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoadingDocuments) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Ошибка: $_loadError', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _loadDocuments,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    if (_documents.isEmpty) {
      return const Center(
        child: Text(
          'Нет документов.\nНажмите "+" чтобы добавить новый.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      itemCount: _documents.length,
      itemBuilder: (context, index) {
        final doc = _documents[index];
        final firstLine = doc.recognizedText.split('\n').first;
        final isDeleting = _deletingIds.contains(doc.id);

        return Card(
          key: ValueKey(doc.id),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            leading: SizedBox(
              width: _thumbnailSize,
              height: _thumbnailSize,
              child: _buildThumbnail(doc.imagePath),
            ),
            title: Text(
              firstLine.isNotEmpty ? firstLine : "Пустой текст",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(DateFormat.yMMMd().add_Hms().format(doc.createdAt)),
            onTap: isDeleting
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            DocumentDetailScreen(document: doc),
                      ),
                    );
                    if (!mounted) return;
                    await _loadDocuments();
                  },
            trailing: isDeleting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    onPressed: () => _deleteDocument(doc.id),
                  ),
          ),
        );
      },
    );
  }

  Future<String> _persistPickedImage(XFile image) async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(appDir.path, 'documents_images'));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }

    var extension = p.extension(image.path).toLowerCase();
    if (extension.isEmpty) {
      extension = '.jpg';
    }

    final fileName = '${const Uuid().v4()}$extension';
    final targetPath = p.join(imagesDir.path, fileName);
    final sourceFile = File(image.path);

    try {
      if (await sourceFile.exists()) {
        await sourceFile.copy(targetPath);
      } else {
        final bytes = await image.readAsBytes();
        await File(targetPath).writeAsBytes(bytes, flush: true);
      }
    } catch (_) {
      final bytes = await image.readAsBytes();
      await File(targetPath).writeAsBytes(bytes, flush: true);
    }

    return targetPath;
  }

  Widget _buildThumbnail(String imagePath) {
    final file = File(imagePath);
    if (!file.existsSync()) {
      return _buildMissingThumbnail();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildMissingThumbnail(),
      ),
    );
  }

  Widget _buildMissingThumbnail() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined, color: Colors.white54),
    );
  }
}
