import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  static Rect fitRectInSize({
    required Size containerSize,
    required Size sourceSize,
  }) {
    if (containerSize.width <= 0 ||
        containerSize.height <= 0 ||
        sourceSize.width <= 0 ||
        sourceSize.height <= 0) {
      return Rect.zero;
    }

    final widthRatio = containerSize.width / sourceSize.width;
    final heightRatio = containerSize.height / sourceSize.height;
    final scale = widthRatio < heightRatio ? widthRatio : heightRatio;

    final fittedWidth = sourceSize.width * scale;
    final fittedHeight = sourceSize.height * scale;
    final left = (containerSize.width - fittedWidth) / 2;
    final top = (containerSize.height - fittedHeight) / 2;

    return Rect.fromLTWH(left, top, fittedWidth, fittedHeight);
  }

  static Rect sceneRectToImageRect({
    required Rect sceneRect,
    required Rect imageRectInScene,
    required Size imagePixelSize,
    bool clamp = true,
  }) {
    if (imageRectInScene.width <= 0 ||
        imageRectInScene.height <= 0 ||
        imagePixelSize.width <= 0 ||
        imagePixelSize.height <= 0) {
      return Rect.zero;
    }

    final normalizedScene = Rect.fromLTRB(
      sceneRect.left < sceneRect.right ? sceneRect.left : sceneRect.right,
      sceneRect.top < sceneRect.bottom ? sceneRect.top : sceneRect.bottom,
      sceneRect.left > sceneRect.right ? sceneRect.left : sceneRect.right,
      sceneRect.top > sceneRect.bottom ? sceneRect.top : sceneRect.bottom,
    );

    final relativeRect = Rect.fromLTRB(
      normalizedScene.left - imageRectInScene.left,
      normalizedScene.top - imageRectInScene.top,
      normalizedScene.right - imageRectInScene.left,
      normalizedScene.bottom - imageRectInScene.top,
    );

    final scaleX = imagePixelSize.width / imageRectInScene.width;
    final scaleY = imagePixelSize.height / imageRectInScene.height;

    final imageRect = Rect.fromLTRB(
      relativeRect.left * scaleX,
      relativeRect.top * scaleY,
      relativeRect.right * scaleX,
      relativeRect.bottom * scaleY,
    );

    if (!clamp) {
      return imageRect;
    }

    return clampRectToSize(imageRect, imagePixelSize);
  }

  static Rect transformRect(Matrix4 matrix, Rect rect) {
    final points = <Offset>[
      MatrixUtils.transformPoint(matrix, rect.topLeft),
      MatrixUtils.transformPoint(matrix, rect.topRight),
      MatrixUtils.transformPoint(matrix, rect.bottomLeft),
      MatrixUtils.transformPoint(matrix, rect.bottomRight),
    ];

    double minX = points.first.dx;
    double maxX = points.first.dx;
    double minY = points.first.dy;
    double maxY = points.first.dy;

    for (final point in points.skip(1)) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static Rect clampRectToSize(Rect rect, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return Rect.zero;
    }

    double left = rect.left.clamp(0.0, size.width);
    double top = rect.top.clamp(0.0, size.height);
    double right = rect.right.clamp(0.0, size.width);
    double bottom = rect.bottom.clamp(0.0, size.height);

    if (right < left) {
      final temp = left;
      left = right;
      right = temp;
    }
    if (bottom < top) {
      final temp = top;
      top = bottom;
      bottom = temp;
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }

  static Rect toPixelAlignedRect(Rect rect, Size imagePixelSize) {
    Rect clamped = clampRectToSize(rect, imagePixelSize);

    double left = clamped.left.floorToDouble();
    double top = clamped.top.floorToDouble();
    double right = clamped.right.ceilToDouble();
    double bottom = clamped.bottom.ceilToDouble();

    left = left.clamp(0.0, imagePixelSize.width);
    top = top.clamp(0.0, imagePixelSize.height);
    right = right.clamp(0.0, imagePixelSize.width);
    bottom = bottom.clamp(0.0, imagePixelSize.height);

    if (right <= left) {
      right = (left + 1).clamp(0.0, imagePixelSize.width);
      left = (right - 1).clamp(0.0, imagePixelSize.width);
    }
    if (bottom <= top) {
      bottom = (top + 1).clamp(0.0, imagePixelSize.height);
      top = (bottom - 1).clamp(0.0, imagePixelSize.height);
    }

    clamped = Rect.fromLTRB(left, top, right, bottom);
    return clampRectToSize(clamped, imagePixelSize);
  }

  static img.Image cropImage(img.Image originalImage, Rect cropRect) {
    int x = cropRect.left.toInt();
    int y = cropRect.top.toInt();
    int w = cropRect.width.toInt();
    int h = cropRect.height.toInt();

    // Защита от вылетов
    x = x.clamp(0, originalImage.width - 1);
    y = y.clamp(0, originalImage.height - 1);
    if (x + w > originalImage.width) w = originalImage.width - x;
    if (y + h > originalImage.height) h = originalImage.height - y;

    if (w <= 0 || h <= 0) return originalImage;

    return img.copyCrop(originalImage, x: x, y: y, width: w, height: h);
  }
}
