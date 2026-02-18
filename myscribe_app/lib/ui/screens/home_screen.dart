import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:myscribe_app/models/document.dart';
import 'package:myscribe_app/services/database_service.dart';
import 'package:myscribe_app/services/ocr_service.dart';
import 'package:myscribe_app/ui/screens/document_detail_screen.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

enum HomeOcrState { idle, uploading, detecting, recognizing, done, error }

enum HomeDateFilter { allTime, last7Days, last30Days }

enum HomeReviewFilter { all, requiresReview, reviewed }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const double _thumbnailSize = 50;
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _searchController = TextEditingController();

  List<Document> _documents = [];
  bool _isLoadingDocuments = true;
  String? _loadError;
  final Set<String> _deletingIds = <String>{};
  final Set<String> _selectedDocumentIds = <String>{};
  bool _isSelectionMode = false;

  HomeOcrState _ocrState = HomeOcrState.idle;
  String? _ocrMessage;
  String? _ocrError;
  String? _retryImagePath;

  HomeDateFilter _dateFilter = HomeDateFilter.allTime;
  HomeReviewFilter _reviewFilter = HomeReviewFilter.all;
  String _searchQuery = '';

  bool get _isOcrInProgress {
    return _ocrState == HomeOcrState.uploading ||
        _ocrState == HomeOcrState.detecting ||
        _ocrState == HomeOcrState.recognizing;
  }

  List<Document> get _filteredDocuments {
    final now = DateTime.now();
    return _documents.where((doc) {
      final matchesSearch =
          _searchQuery.isEmpty ||
          doc.recognizedText.toLowerCase().contains(_searchQuery);

      final matchesReview = switch (_reviewFilter) {
        HomeReviewFilter.all => true,
        HomeReviewFilter.requiresReview => doc.requiresReview,
        HomeReviewFilter.reviewed => !doc.requiresReview,
      };

      final threshold = switch (_dateFilter) {
        HomeDateFilter.allTime => null,
        HomeDateFilter.last7Days => now.subtract(const Duration(days: 7)),
        HomeDateFilter.last30Days => now.subtract(const Duration(days: 30)),
      };
      final matchesDate =
          threshold == null ||
          doc.createdAt.isAfter(threshold) ||
          doc.createdAt.isAtSameMomentAs(threshold);

      return matchesSearch && matchesReview && matchesDate;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _initializeScreen();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
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

  void _onSearchChanged() {
    final nextQuery = _searchController.text.trim().toLowerCase();
    if (_searchQuery == nextQuery) {
      return;
    }
    setState(() {
      _searchQuery = nextQuery;
    });
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
        _selectedDocumentIds.removeWhere(
          (selectedId) => !_documents.any((doc) => doc.id == selectedId),
        );
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
    if (_isOcrInProgress) {
      return;
    }

    final permissionStatus = source == ImageSource.camera
        ? await Permission.camera.request()
        : await Permission.photos.request();

    if (!permissionStatus.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет разрешения на доступ к изображению.')),
      );
      return;
    }

    final XFile? image = await _picker.pickImage(source: source);
    if (image == null || !mounted) return;

    await _startOcrFlow(image);
  }

  Future<void> _startOcrFlow(XFile image) async {
    _setOcrState(
      HomeOcrState.uploading,
      message: 'Uploading: подготовка изображения...',
    );

    String persistentImagePath = '';
    try {
      persistentImagePath = await _persistPickedImage(image);
      await _runOcrForPersistentImage(persistentImagePath);
    } catch (e) {
      if (persistentImagePath.isNotEmpty) {
        await _deleteFileIfExists(persistentImagePath);
      }
      if (!mounted) return;
      _setOcrState(
        HomeOcrState.error,
        error: 'Ошибка обработки изображения: ${_toUserError(e)}',
      );
    }
  }

  Future<void> _runOcrForPersistentImage(String imagePath) async {
    final ocrService = Provider.of<OcrService>(context, listen: false);
    final dbService = Provider.of<DatabaseService>(context, listen: false);

    try {
      final imageBytes = await File(imagePath).readAsBytes();
      _setOcrState(
        HomeOcrState.detecting,
        message: 'Detecting: анализ изображения...',
        retryImagePath: imagePath,
      );

      final recognizedText = await ocrService.runOCR(
        imageBytes,
        onStage: (stage) {
          if (!mounted) return;
          switch (stage) {
            case OcrProcessingStage.sending:
              _setOcrState(
                HomeOcrState.detecting,
                message: 'Detecting: отправка на сервер...',
                retryImagePath: imagePath,
              );
              break;
            case OcrProcessingStage.processing:
            case OcrProcessingStage.parsing:
              _setOcrState(
                HomeOcrState.recognizing,
                message: 'Recognizing: получение текста...',
                retryImagePath: imagePath,
              );
              break;
          }
        },
      );

      final newDoc = Document(
        id: const Uuid().v4(),
        imagePath: imagePath,
        recognizedText: recognizedText,
        createdAt: DateTime.now(),
        requiresReview: recognizedText.trim().isEmpty,
      );

      await dbService.insertDocument(newDoc);
      if (!mounted) return;
      await _loadDocuments();
      if (!mounted) return;

      _setOcrState(HomeOcrState.done, message: 'Done: документ создан.');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      _setOcrState(HomeOcrState.idle);

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => DocumentDetailScreen(document: newDoc),
        ),
      );
      if (!mounted) return;
      await _loadDocuments();
    } catch (e) {
      if (!mounted) return;
      _setOcrState(
        HomeOcrState.error,
        error: 'Ошибка OCR: ${_toUserError(e)}',
        retryImagePath: imagePath,
      );
    }
  }

  Future<void> _retryFailedOcr() async {
    final imagePath = _retryImagePath;
    if (imagePath == null || _isOcrInProgress) {
      return;
    }
    await _runOcrForPersistentImage(imagePath);
  }

  Future<void> _dismissOcrError() async {
    final imagePath = _retryImagePath;
    if (imagePath != null) {
      await _deleteFileIfExists(imagePath);
    }
    if (!mounted) return;
    _setOcrState(HomeOcrState.idle);
  }

  void _setOcrState(
    HomeOcrState state, {
    String? message,
    String? error,
    String? retryImagePath,
  }) {
    if (!mounted) return;
    setState(() {
      _ocrState = state;
      _ocrMessage = message;
      _ocrError = error;
      _retryImagePath = retryImagePath;
    });
  }

  Future<void> _deleteDocument(String id) async {
    await _deleteDocumentsByIds(<String>{id});
  }

  Future<void> _deleteSelectedDocuments() async {
    if (_selectedDocumentIds.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удаление документов'),
        content: Text(
          'Удалить выбранные документы: ${_selectedDocumentIds.length} шт.?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await _deleteDocumentsByIds(_selectedDocumentIds);
  }

  Future<void> _deleteDocumentsByIds(Set<String> ids) async {
    if (ids.isEmpty) return;

    final dbService = Provider.of<DatabaseService>(context, listen: false);
    final idsToDelete = Set<String>.from(ids);
    final imagePathsById = <String, String>{
      for (final doc in _documents.where((doc) => idsToDelete.contains(doc.id)))
        doc.id: doc.imagePath,
    };

    setState(() {
      _deletingIds.addAll(idsToDelete);
    });

    try {
      for (final id in idsToDelete) {
        await dbService.deleteDocument(id);
        final imagePath = imagePathsById[id];
        if (imagePath != null) {
          await _deleteFileIfExists(imagePath);
        }
      }

      if (!mounted) return;
      await _loadDocuments();
      if (!mounted) return;

      setState(() {
        _selectedDocumentIds.removeAll(idsToDelete);
        if (_selectedDocumentIds.isEmpty) {
          _isSelectionMode = false;
        }
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Удалено документов: ${idsToDelete.length}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка удаления: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _deletingIds.removeAll(idsToDelete);
        });
      }
    }
  }

  Future<void> _exportDocuments({Set<String>? ids}) async {
    final sourceDocs = ids == null
        ? _filteredDocuments
        : _documents.where((doc) => ids.contains(doc.id)).toList();

    if (sourceDocs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Нет документов для экспорта.')));
      return;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final exportFilePath = p.join(
      appDir.path,
      'documents_export_${DateTime.now().millisecondsSinceEpoch}.json',
    );

    final payload = sourceDocs
        .map(
          (doc) => {
            'id': doc.id,
            'imagePath': doc.imagePath,
            'recognizedText': doc.recognizedText,
            'createdAt': doc.createdAt.toIso8601String(),
            'requiresReview': doc.requiresReview,
          },
        )
        .toList();

    final exportFile = File(exportFilePath);
    await exportFile.writeAsString(jsonEncode(payload), flush: true);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(exportFile.path)],
        text: 'Экспортировано документов: ${sourceDocs.length}',
      ),
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedDocumentIds.clear();
      }
    });
  }

  void _toggleDocumentSelection(String id) {
    setState(() {
      if (_selectedDocumentIds.contains(id)) {
        _selectedDocumentIds.remove(id);
      } else {
        _selectedDocumentIds.add(id);
      }
      if (_selectedDocumentIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
  }

  String _toUserError(Object error) {
    final message = error.toString();
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
  }

  Future<void> _deleteFileIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selectedDocumentIds.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSelectionMode
              ? 'Выбрано: $selectedCount'
              : 'MyScribe Документы',
        ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Выйти из выбора',
                  onPressed: _toggleSelectionMode,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Удалить выбранное',
                  onPressed:
                      selectedCount == 0 ? null : _deleteSelectedDocuments,
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  tooltip: 'Экспорт выбранного',
                  onPressed: selectedCount == 0
                      ? null
                      : () => _exportDocuments(ids: _selectedDocumentIds),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.cleaning_services_outlined),
                  tooltip: 'Очистить поврежденные',
                  onPressed: _cleanupBrokenDocuments,
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  tooltip: 'Экспорт текущей выборки',
                  onPressed: _exportDocuments,
                ),
                IconButton(
                  icon: const Icon(Icons.checklist_outlined),
                  tooltip: 'Массовый выбор',
                  onPressed: _toggleSelectionMode,
                ),
              ],
      ),
      body: _buildBody(),
      floatingActionButton: _isSelectionMode
          ? null
          : Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  onPressed: _isOcrInProgress
                      ? null
                      : () => _pickImage(ImageSource.gallery),
                  label: const Text('Галерея'),
                  icon: const Icon(Icons.photo_library),
                  heroTag: 'gallery',
                ),
                const SizedBox(width: 10),
                FloatingActionButton.extended(
                  onPressed: _isOcrInProgress
                      ? null
                      : () => _pickImage(ImageSource.camera),
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

    final docs = _filteredDocuments;

    return Column(
      children: [
        if (_ocrState != HomeOcrState.idle) _buildOcrStatusBanner(),
        _buildFilterControls(),
        Expanded(
          child: docs.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final firstLine = doc.recognizedText.split('\n').first;
                    final isDeleting = _deletingIds.contains(doc.id);
                    final isSelected = _selectedDocumentIds.contains(doc.id);

                    return Card(
                      key: ValueKey(doc.id),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: ListTile(
                        onLongPress: isDeleting
                            ? null
                            : () {
                                if (!_isSelectionMode) {
                                  setState(() {
                                    _isSelectionMode = true;
                                    _selectedDocumentIds.add(doc.id);
                                  });
                                }
                              },
                        leading: SizedBox(
                          width: _thumbnailSize,
                          height: _thumbnailSize,
                          child: _buildThumbnail(doc.imagePath),
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                firstLine.isNotEmpty ? firstLine : 'Пустой текст',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (doc.requiresReview)
                              const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Chip(
                                  label: Text('Требует проверки'),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          DateFormat.yMMMd().add_Hms().format(doc.createdAt),
                        ),
                        onTap: isDeleting
                            ? null
                            : () async {
                                if (_isSelectionMode) {
                                  _toggleDocumentSelection(doc.id);
                                  return;
                                }
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
                            : _isSelectionMode
                            ? Checkbox(
                                value: isSelected,
                                onChanged: (_) => _toggleDocumentSelection(doc.id),
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
                ),
        ),
      ],
    );
  }

  Widget _buildOcrStatusBanner() {
    final isError = _ocrState == HomeOcrState.error;
    final isDone = _ocrState == HomeOcrState.done;
    final color = isError
        ? Colors.redAccent
        : isDone
        ? Colors.green
        : Colors.teal;
    final text = isError ? (_ocrError ?? 'Ошибка OCR') : (_ocrMessage ?? 'OCR');
    final icon = isError
        ? Icons.error_outline
        : isDone
        ? Icons.check_circle_outline
        : Icons.sync;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
              if (_isOcrInProgress)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (isError)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _retryFailedOcr,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: _dismissOcrError,
                    child: const Text('Закрыть'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Поиск по тексту документа',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              DropdownButton<HomeReviewFilter>(
                value: _reviewFilter,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _reviewFilter = value;
                  });
                },
                items: const [
                  DropdownMenuItem(
                    value: HomeReviewFilter.all,
                    child: Text('Все статусы'),
                  ),
                  DropdownMenuItem(
                    value: HomeReviewFilter.requiresReview,
                    child: Text('Требует проверки'),
                  ),
                  DropdownMenuItem(
                    value: HomeReviewFilter.reviewed,
                    child: Text('Проверенные'),
                  ),
                ],
              ),
              DropdownButton<HomeDateFilter>(
                value: _dateFilter,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _dateFilter = value;
                  });
                },
                items: const [
                  DropdownMenuItem(
                    value: HomeDateFilter.allTime,
                    child: Text('За все время'),
                  ),
                  DropdownMenuItem(
                    value: HomeDateFilter.last7Days,
                    child: Text('Последние 7 дней'),
                  ),
                  DropdownMenuItem(
                    value: HomeDateFilter.last30Days,
                    child: Text('Последние 30 дней'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final hasAnyDocs = _documents.isNotEmpty;
    final text = hasAnyDocs
        ? 'Нет документов по текущим фильтрам.'
        : 'Нет документов.\nДобавьте новый через кнопку ниже.';
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
      ),
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
