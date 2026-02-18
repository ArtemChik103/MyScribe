import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:myscribe_app/config/api_config.dart';
import 'package:myscribe_app/models/correction.dart';
import 'package:myscribe_app/models/document.dart';
import 'package:myscribe_app/services/database_service.dart';
import 'package:myscribe_app/services/ocr_service.dart';
import 'package:myscribe_app/ui/widgets/selection_painter.dart';
import 'package:myscribe_app/utils/image_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

enum CorrectionSyncState {
  idle,
  savingLocal,
  savedLocal,
  sending,
  sent,
  sendFailed,
}

class DocumentDetailScreen extends StatefulWidget {
  final Document document;

  const DocumentDetailScreen({super.key, required this.document});

  @override
  State<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends State<DocumentDetailScreen> {
  late TextEditingController _textController;
  final TransformationController _transformationController =
      TransformationController();

  bool _isEditing = false;
  bool _isDrawingMode = false;
  bool _isSavingCorrection = false;
  bool _isRerunningOcr = false;

  CorrectionSyncState _syncState = CorrectionSyncState.idle;
  String? _syncStatusMessage;
  _PendingCorrectionUpload? _pendingCorrectionUpload;

  Size? _imageSize;
  bool _isImageLoaded = false;
  String? _imageLoadError;

  Offset? _selectionStartScene;
  Rect? _selectionSceneRect;
  Rect? _selectionViewportRect;

  final GlobalKey _viewportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: widget.document.recognizedText,
    );
    _calculateImageDimensions();
  }

  @override
  void dispose() {
    _textController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  bool get _isBusy => _isSavingCorrection || _isRerunningOcr;

  Future<void> _calculateImageDimensions() async {
    try {
      final file = File(widget.document.imagePath);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _imageLoadError = 'Файл изображения не найден.';
          _isImageLoaded = false;
        });
        return;
      }

      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        if (!mounted) return;
        setState(() {
          _imageLoadError = 'Не удалось прочитать изображение.';
          _isImageLoaded = false;
        });
        return;
      }

      final baked = img.bakeOrientation(decoded);
      if (!mounted) return;
      setState(() {
        _imageSize = Size(baked.width.toDouble(), baked.height.toDouble());
        _isImageLoaded = true;
        _imageLoadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _imageLoadError = 'Ошибка загрузки изображения.';
        _isImageLoaded = false;
      });
      debugPrint('Ошибка загрузки изображения: $e');
    }
  }

  Future<void> _saveChanges() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    widget.document.recognizedText = _textController.text;
    await dbService.updateDocumentText(
      widget.document.id,
      _textController.text,
    );
    if (!mounted) return;
    setState(() => _isEditing = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Текст сохранен')));
  }

  Future<void> _setRequiresReview(
    bool value, {
    bool showSnackBar = true,
  }) async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);
    await dbService.updateDocumentRequiresReview(widget.document.id, value);
    if (!mounted) return;
    setState(() {
      widget.document.requiresReview = value;
    });
    if (showSnackBar) {
      final text = value
          ? 'Документ помечен: требует проверки'
          : 'Документ помечен как проверенный';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Size? _getViewportSize() {
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.size;
    }
    return null;
  }

  Rect? _getImageRectInScene() {
    final viewportSize = _getViewportSize();
    final imageSize = _imageSize;
    if (viewportSize == null || imageSize == null) {
      return null;
    }

    return ImageUtils.fitRectInSize(
      containerSize: viewportSize,
      sourceSize: imageSize,
    );
  }

  Rect? _sceneRectToImageRect(Rect sceneRect, {required bool clamp}) {
    final imageSize = _imageSize;
    final imageRectInScene = _getImageRectInScene();

    if (imageSize == null ||
        imageRectInScene == null ||
        imageRectInScene == Rect.zero) {
      return null;
    }

    return ImageUtils.sceneRectToImageRect(
      sceneRect: sceneRect,
      imageRectInScene: imageRectInScene,
      imagePixelSize: imageSize,
      clamp: clamp,
    );
  }

  Rect _sceneRectToViewportRect(Rect sceneRect) {
    return ImageUtils.transformRect(_transformationController.value, sceneRect);
  }

  void _setSelectionFromSceneRect(Rect sceneRect) {
    setState(() {
      _selectionSceneRect = sceneRect;
      _selectionViewportRect = _sceneRectToViewportRect(sceneRect);
    });
  }

  void _onPanStart(DragStartDetails details) {
    if (!_isDrawingMode || _isBusy) return;
    final scenePoint = _transformationController.toScene(details.localPosition);
    _selectionStartScene = scenePoint;
    _setSelectionFromSceneRect(Rect.fromPoints(scenePoint, scenePoint));
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isDrawingMode || _isBusy || _selectionStartScene == null) {
      return;
    }

    final scenePoint = _transformationController.toScene(details.localPosition);
    _setSelectionFromSceneRect(
      Rect.fromPoints(_selectionStartScene!, scenePoint),
    );
  }

  void _clearSelectionOverlay() {
    setState(() {
      _selectionStartScene = null;
      _selectionSceneRect = null;
      _selectionViewportRect = null;
    });
  }

  Future<void> _onPanEnd(DragEndDetails details) async {
    if (!_isDrawingMode || _isBusy) return;

    final selectionSceneRect = _selectionSceneRect;
    final imageSize = _imageSize;

    _clearSelectionOverlay();

    if (selectionSceneRect == null || imageSize == null) {
      return;
    }

    final selectionImageRect = _sceneRectToImageRect(
      selectionSceneRect,
      clamp: true,
    );
    if (selectionImageRect == null || selectionImageRect == Rect.zero) {
      return;
    }

    final cropImageRect = ImageUtils.toPixelAlignedRect(
      selectionImageRect,
      imageSize,
    );
    if (cropImageRect.width < 10 || cropImageRect.height < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Слишком маленькая область выделения.')),
      );
      return;
    }

    final draft = await _showCorrectionSheet();
    if (!mounted || draft == null || draft.correctedText.isEmpty) {
      return;
    }

    await _saveCorrection(
      cropImageRect: cropImageRect,
      correctedText: draft.correctedText,
      sendToServer: draft.sendToServer,
    );
  }

  Future<_CorrectionDraft?> _showCorrectionSheet() async {
    final correctedTextController = TextEditingController();
    var sendToServer = true;

    final result = await showModalBottomSheet<_CorrectionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Добавить коррекцию',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: correctedTextController,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Введите правильный текст',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: sendToServer,
                    title: const Text('Отправить на сервер сразу'),
                    onChanged: (value) {
                      setModalState(() {
                        sendToServer = value;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Отмена'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(
                            context,
                            _CorrectionDraft(
                              correctedText: correctedTextController.text.trim(),
                              sendToServer: sendToServer,
                            ),
                          );
                        },
                        child: const Text('Сохранить'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    correctedTextController.dispose();
    return result;
  }

  Future<void> _saveCorrection({
    required Rect cropImageRect,
    required String correctedText,
    required bool sendToServer,
  }) async {
    if (_isSavingCorrection || _imageSize == null || _imageLoadError != null) {
      return;
    }

    final dbService = Provider.of<DatabaseService>(context, listen: false);

    setState(() {
      _isSavingCorrection = true;
    });
    _setSyncStatus(
      CorrectionSyncState.savingLocal,
      'Сохраняем локально...',
    );

    try {
      final sourceFile = File(widget.document.imagePath);
      if (!await sourceFile.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Файл изображения больше недоступен.')),
        );
        return;
      }

      final bytes = await sourceFile.readAsBytes();
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось прочитать изображение.')),
        );
        return;
      }

      final fullImage = img.bakeOrientation(decodedImage);
      final fullImageSize = Size(
        fullImage.width.toDouble(),
        fullImage.height.toDouble(),
      );
      final finalCropRect = ImageUtils.toPixelAlignedRect(
        cropImageRect,
        fullImageSize,
      );
      final croppedImage = ImageUtils.cropImage(fullImage, finalCropRect);

      final appDir = await getApplicationDocumentsDirectory();
      final fragmentPath = '${appDir.path}/frag_${const Uuid().v4()}.png';
      await File(fragmentPath).writeAsBytes(img.encodePng(croppedImage));

      await dbService.insertCorrection(
        Correction(
          documentId: widget.document.id,
          imageFragmentPath: fragmentPath,
          correctedText: correctedText,
        ),
      );

      await _setRequiresReview(true, showSnackBar: false);
      _setSyncStatus(CorrectionSyncState.savedLocal, 'Сохранено локально');

      if (sendToServer) {
        try {
          await _sendCorrectionToServer(
            fragmentPath: fragmentPath,
            correctedText: correctedText,
          );
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _pendingCorrectionUpload = _PendingCorrectionUpload(
              fragmentPath: fragmentPath,
              correctedText: correctedText,
            );
          });
          _setSyncStatus(
            CorrectionSyncState.sendFailed,
            'Сохранено локально, отправка не удалась',
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Ошибка отправки: ${_toUserError(e)}'),
              action: SnackBarAction(
                label: 'Retry',
                onPressed: _retryPendingUpload,
              ),
            ),
          );
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Коррекция сохранена')));
    } catch (e) {
      if (!mounted) return;
      _setSyncStatus(CorrectionSyncState.sendFailed, 'Ошибка сохранения');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: ${_toUserError(e)}')));
    } finally {
      if (mounted) {
        setState(() {
          _isSavingCorrection = false;
        });
      }
    }
  }

  Future<void> _sendCorrectionToServer({
    required String fragmentPath,
    required String correctedText,
  }) async {
    _setSyncStatus(CorrectionSyncState.sending, 'Отправка на сервер...');
    final uri = ApiConfig.feedbackUri;
    final request = http.MultipartRequest('POST', uri);
    request.fields['correct_text'] = correctedText;
    request.files.add(await http.MultipartFile.fromPath('file', fragmentPath));
    final response = await request.send();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (!mounted) return;
      setState(() {
        _pendingCorrectionUpload = null;
      });
      _setSyncStatus(CorrectionSyncState.sent, 'Отправлено на сервер');
      return;
    }

    throw Exception('Сервер вернул ${response.statusCode}');
  }

  Future<void> _retryPendingUpload() async {
    final pending = _pendingCorrectionUpload;
    if (pending == null || _isBusy) {
      return;
    }

    try {
      await _sendCorrectionToServer(
        fragmentPath: pending.fragmentPath,
        correctedText: pending.correctedText,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Повторная отправка успешна')));
    } catch (e) {
      if (!mounted) return;
      _setSyncStatus(
        CorrectionSyncState.sendFailed,
        'Отправка снова не удалась',
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: ${_toUserError(e)}')));
    }
  }

  Future<void> _copyText() async {
    await Clipboard.setData(ClipboardData(text: _textController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Текст скопирован')));
  }

  Future<void> _shareText() async {
    await SharePlus.instance.share(ShareParams(text: _textController.text));
  }

  Future<void> _rerunOcr() async {
    if (_isRerunningOcr || _isSavingCorrection) {
      return;
    }

    final ocrService = Provider.of<OcrService>(context, listen: false);
    final dbService = Provider.of<DatabaseService>(context, listen: false);

    try {
      setState(() {
        _isRerunningOcr = true;
      });

      final sourceFile = File(widget.document.imagePath);
      if (!await sourceFile.exists()) {
        throw Exception('Файл изображения недоступен');
      }

      final imageBytes = await sourceFile.readAsBytes();

      _setSyncStatus(CorrectionSyncState.sending, 'Повторное OCR...');
      final recognizedText = await ocrService.runOCR(imageBytes);

      _textController.text = recognizedText;
      widget.document.recognizedText = recognizedText;
      await dbService.updateDocumentText(widget.document.id, recognizedText);

      _setSyncStatus(CorrectionSyncState.sent, 'Текст обновлен');
      if (widget.document.requiresReview) {
        await _setRequiresReview(false, showSnackBar: false);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('OCR выполнен повторно')));
    } catch (e) {
      if (!mounted) return;
      _setSyncStatus(CorrectionSyncState.sendFailed, 'Ошибка повторного OCR');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка: ${_toUserError(e)}'),
          action: SnackBarAction(label: 'Retry', onPressed: _rerunOcr),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRerunningOcr = false;
        });
      }
    }
  }

  void _setSyncStatus(CorrectionSyncState state, String? message) {
    if (!mounted) return;
    setState(() {
      _syncState = state;
      _syncStatusMessage = message;
    });
  }

  Future<void> _deleteCurrentDocument() async {
    final dbService = Provider.of<DatabaseService>(context, listen: false);

    try {
      await dbService.deleteDocument(widget.document.id);
      final imageFile = File(widget.document.imagePath);
      if (await imageFile.exists()) {
        await imageFile.delete();
      }

      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка удаления: $e')));
    }
  }

  Widget _buildImageWorkspace() {
    final imageSize = _imageSize;
    if (imageSize == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);

        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transformationController,
                minScale: 1.0,
                maxScale: 5.0,
                panEnabled: !_isDrawingMode && !_isBusy,
                scaleEnabled: !_isDrawingMode && !_isBusy,
                child: SizedBox(
                  width: viewportSize.width,
                  height: viewportSize.height,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: imageSize.width,
                      height: imageSize.height,
                      child: Image.file(
                        File(widget.document.imagePath),
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildMissingImageState();
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_isDrawingMode || _isBusy,
                child: GestureDetector(
                  key: _viewportKey,
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: CustomPaint(
                    painter: SelectionPainter(rect: _selectionViewportRect),
                  ),
                ),
              ),
            ),
            if (_isBusy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        );
      },
    );
  }

  Color _syncColor(CorrectionSyncState state) {
    return switch (state) {
      CorrectionSyncState.idle => Colors.blueGrey,
      CorrectionSyncState.savingLocal => Colors.orange,
      CorrectionSyncState.savedLocal => Colors.blue,
      CorrectionSyncState.sending => Colors.teal,
      CorrectionSyncState.sent => Colors.green,
      CorrectionSyncState.sendFailed => Colors.redAccent,
    };
  }

  IconData _syncIcon(CorrectionSyncState state) {
    return switch (state) {
      CorrectionSyncState.idle => Icons.info_outline,
      CorrectionSyncState.savingLocal => Icons.save_outlined,
      CorrectionSyncState.savedLocal => Icons.check_circle_outline,
      CorrectionSyncState.sending => Icons.cloud_upload_outlined,
      CorrectionSyncState.sent => Icons.cloud_done_outlined,
      CorrectionSyncState.sendFailed => Icons.error_outline,
    };
  }

  String _toUserError(Object error) {
    final message = error.toString();
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
  }

  Widget _buildSyncStatusBanner() {
    final message = _syncStatusMessage;
    if (message == null || _syncState == CorrectionSyncState.idle) {
      return const SizedBox.shrink();
    }

    final color = _syncColor(_syncState);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(_syncIcon(_syncState), color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          if (_syncState == CorrectionSyncState.sendFailed &&
              _pendingCorrectionUpload != null)
            TextButton(onPressed: _retryPendingUpload, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
            onPressed: _copyText,
          ),
          ActionChip(
            avatar: const Icon(Icons.share, size: 18),
            label: const Text('Share'),
            onPressed: _shareText,
          ),
          ActionChip(
            avatar: const Icon(Icons.refresh, size: 18),
            label: const Text('Re-run OCR'),
            onPressed: _isBusy ? null : _rerunOcr,
          ),
          FilterChip(
            label: const Text('Требует проверки'),
            selected: widget.document.requiresReview,
            onSelected: (value) => _setRequiresReview(value),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Просмотр'),
        actions: [
          if (_isEditing)
            IconButton(icon: const Icon(Icons.save), onPressed: _saveChanges),
          IconButton(
            icon: Icon(_isEditing ? Icons.visibility : Icons.edit),
            onPressed: () => setState(() => _isEditing = !_isEditing),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: _imageLoadError != null
                  ? _buildMissingImageState()
                  : !_isImageLoaded
                  ? const Center(child: CircularProgressIndicator())
                  : _buildImageWorkspace(),
            ),
          ),
          _buildQuickActions(),
          _buildSyncStatusBanner(),
          Expanded(
            flex: 2,
            child: TextField(
              controller: _textController,
              maxLines: null,
              expands: true,
              readOnly: !_isEditing,
              decoration: InputDecoration(
                filled: true,
                fillColor: _isEditing ? Colors.grey[800] : Colors.transparent,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_isImageLoaded && _imageLoadError == null && !_isBusy)
            ? () {
                setState(() {
                  _isDrawingMode = !_isDrawingMode;
                  _selectionStartScene = null;
                  _selectionSceneRect = null;
                  _selectionViewportRect = null;
                });
              }
            : null,
        backgroundColor: _isDrawingMode ? Colors.redAccent : Colors.tealAccent,
        icon: Icon(_isDrawingMode ? Icons.check : Icons.crop_free),
        label: Text(_isDrawingMode ? 'Готово' : 'Выделить'),
      ),
    );
  }

  Widget _buildMissingImageState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              size: 56,
              color: Colors.white70,
            ),
            const SizedBox(height: 12),
            Text(
              _imageLoadError ?? 'Изображение недоступно.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _deleteCurrentDocument,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Удалить документ'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CorrectionDraft {
  final String correctedText;
  final bool sendToServer;

  const _CorrectionDraft({
    required this.correctedText,
    required this.sendToServer,
  });
}

class _PendingCorrectionUpload {
  final String fragmentPath;
  final String correctedText;

  const _PendingCorrectionUpload({
    required this.fragmentPath,
    required this.correctedText,
  });
}
