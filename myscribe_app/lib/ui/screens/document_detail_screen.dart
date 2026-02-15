import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:myscribe_app/config/api_config.dart';
import 'package:myscribe_app/models/correction.dart';
import 'package:myscribe_app/models/document.dart';
import 'package:myscribe_app/services/database_service.dart';
import 'package:myscribe_app/ui/widgets/selection_painter.dart';
import 'package:myscribe_app/utils/image_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

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
      print('Ошибка загрузки изображения: $e');
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
    if (!_isDrawingMode || _isSavingCorrection) return;
    final scenePoint = _transformationController.toScene(details.localPosition);
    _selectionStartScene = scenePoint;
    _setSelectionFromSceneRect(Rect.fromPoints(scenePoint, scenePoint));
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isDrawingMode ||
        _isSavingCorrection ||
        _selectionStartScene == null) {
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

  void _onPanEnd(DragEndDetails details) {
    if (!_isDrawingMode || _isSavingCorrection) return;

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

    _showCorrectionDialog(cropImageRect: cropImageRect);
  }

  Future<void> _showCorrectionDialog({required Rect cropImageRect}) async {
    final correctedTextController = TextEditingController();

    final correctedText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Исправление'),
        content: TextField(
          controller: correctedTextController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Правильный текст'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(context, correctedTextController.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (correctedText == null || correctedText.isEmpty) return;

    await _saveCorrection(
      cropImageRect: cropImageRect,
      correctedText: correctedText,
    );
  }

  Future<void> _saveCorrection({
    required Rect cropImageRect,
    required String correctedText,
  }) async {
    if (_isSavingCorrection || _imageSize == null || _imageLoadError != null) {
      return;
    }

    final dbService = Provider.of<DatabaseService>(context, listen: false);

    setState(() {
      _isSavingCorrection = true;
    });

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

      final uri = ApiConfig.feedbackUri;
      final request = http.MultipartRequest('POST', uri);
      request.fields['correct_text'] = correctedText;
      request.files.add(
        await http.MultipartFile.fromPath('file', fragmentPath),
      );
      await request.send();

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Отправлено!')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isSavingCorrection = false;
        });
      }
    }
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
                panEnabled: !_isDrawingMode && !_isSavingCorrection,
                scaleEnabled: !_isDrawingMode && !_isSavingCorrection,
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
                ignoring: !_isDrawingMode || _isSavingCorrection,
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
            if (_isSavingCorrection)
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
        onPressed:
            (_isImageLoaded && _imageLoadError == null && !_isSavingCorrection)
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
