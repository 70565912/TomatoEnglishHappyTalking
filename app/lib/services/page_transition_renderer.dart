import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

enum RecordingPageTransition {
  none,
  crossFade,
  panZoomFade,
  slide,
  pageCurl;

  static RecordingPageTransition parse(String value) {
    final normalized = value.trim();
    return RecordingPageTransition.values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => RecordingPageTransition.none,
    );
  }
}

/// Single source of truth for live playback and offline video transitions.
class PageTransitionRenderer {
  static const int durationMs = 500;
  static const int liveFrameCount = 8;
  static const int liveWidth = 1280;
  static const int liveHeight = 720;
  static const Color backgroundColor = Color(0xFF07111F);

  static void draw({
    required Canvas canvas,
    required Rect bounds,
    required ui.Image? fromImage,
    required ui.Image? toImage,
    required double progress,
    required RecordingPageTransition transition,
  }) {
    final raw = progress.clamp(0, 1).toDouble();
    if (transition == RecordingPageTransition.none) {
      _drawImage(canvas, toImage ?? fromImage, bounds, Paint());
      return;
    }

    final eased = _smoothStep(raw);
    switch (transition) {
      case RecordingPageTransition.crossFade:
        _drawImage(canvas, fromImage, bounds, _opacityPaint(1 - eased));
        _drawImage(canvas, toImage, bounds, _opacityPaint(eased));
      case RecordingPageTransition.panZoomFade:
        _drawImage(
          canvas,
          fromImage,
          bounds,
          _opacityPaint(1 - eased),
          scale: 1 + eased * 0.015,
        );
        _drawImage(
          canvas,
          toImage,
          bounds,
          _opacityPaint(eased),
          scale: 1.015 - eased * 0.015,
        );
      case RecordingPageTransition.slide:
        _drawImage(
          canvas,
          fromImage,
          bounds,
          Paint(),
          offset: Offset(-bounds.width * eased, 0),
        );
        _drawImage(
          canvas,
          toImage,
          bounds,
          Paint(),
          offset: Offset(bounds.width * (1 - eased), 0),
        );
      case RecordingPageTransition.pageCurl:
        _drawPageCurl(
          canvas: canvas,
          bounds: bounds,
          fromImage: fromImage,
          toImage: toImage,
          progress: raw,
        );
      case RecordingPageTransition.none:
        break;
    }
  }

  static Future<Uint8List> renderPng({
    required ui.Image? fromImage,
    required ui.Image? toImage,
    required double progress,
    required RecordingPageTransition transition,
    int width = liveWidth,
    int height = liveHeight,
  }) async {
    final size = Size(width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = backgroundColor);
    draw(
      canvas: canvas,
      bounds: bounds,
      fromImage: fromImage,
      toImage: toImage,
      progress: progress,
      transition: transition,
    );
    final picture = recorder.endRecording();
    ByteData? data;
    try {
      final image = await picture.toImage(width, height);
      try {
        data = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
    if (data == null) {
      throw StateError('绘本转场帧 PNG 编码失败');
    }
    return data.buffer.asUint8List();
  }

  static void _drawImage(
    Canvas canvas,
    ui.Image? image,
    Rect bounds,
    Paint paint, {
    double scale = 1,
    Offset offset = Offset.zero,
  }) {
    if (image == null) return;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, imageSize, bounds.size);
    var destination = Alignment.center.inscribe(fitted.destination, bounds);
    if (scale != 1) {
      destination = Rect.fromCenter(
        center: destination.center,
        width: destination.width * scale,
        height: destination.height * scale,
      );
    }
    destination = destination.shift(offset);
    paint.filterQuality = FilterQuality.medium;
    canvas.drawImageRect(image, Offset.zero & imageSize, destination, paint);
  }

  static void _drawPageCurl({
    required Canvas canvas,
    required Rect bounds,
    required ui.Image? fromImage,
    required ui.Image? toImage,
    required double progress,
  }) {
    if (progress <= 0) {
      _drawImage(canvas, fromImage ?? toImage, bounds, Paint());
      return;
    }
    if (progress >= 1) {
      _drawImage(canvas, toImage ?? fromImage, bounds, Paint());
      return;
    }
    if (toImage != null) {
      _drawImage(canvas, toImage, bounds, Paint());
    }
    if (fromImage == null) return;

    final eased = _smoothStep(progress);
    final bend = math.sin(math.pi * progress) * bounds.width * 0.055;
    final edgeX = _lerp(bounds.right, bounds.left, eased);
    final topEdge = Offset(edgeX + bend, bounds.top);
    final bottomEdge = Offset(edgeX - bend, bounds.bottom);
    final sheetPath = Path()
      ..moveTo(bounds.left, bounds.top)
      ..lineTo(topEdge.dx, topEdge.dy)
      ..lineTo(bottomEdge.dx, bottomEdge.dy)
      ..lineTo(bounds.left, bounds.bottom)
      ..close();

    canvas.save();
    canvas.clipPath(sheetPath, doAntiAlias: true);
    _drawImage(canvas, fromImage, bounds, Paint());
    canvas.restore();

    final shadowWidth = math.max(10.0, bounds.width * 0.025);
    final shadowRect = Rect.fromLTRB(
      math.max(bounds.left, edgeX - shadowWidth),
      bounds.top,
      math.min(bounds.right, edgeX + shadowWidth),
      bounds.bottom,
    );
    canvas.drawRect(
      shadowRect,
      Paint()
        ..shader = ui.Gradient.linear(
          shadowRect.centerLeft,
          shadowRect.centerRight,
          const [
            Color(0x00000000),
            Color(0x44000000),
            Color(0x00000000),
          ],
          const [0.0, 0.5, 1.0],
        ),
    );
    canvas.drawLine(
      topEdge,
      bottomEdge,
      Paint()
        ..color = const Color(0x88333333)
        ..strokeWidth = math.max(1.5, bounds.width * 0.0015),
    );
  }

  static Paint _opacityPaint(double opacity) => Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = ui.ColorFilter.mode(
      Color.fromRGBO(255, 255, 255, opacity.clamp(0, 1).toDouble()),
      BlendMode.modulate,
    );

  static double _smoothStep(double value) {
    final t = value.clamp(0, 1).toDouble();
    return t * t * (3 - 2 * t);
  }

  static double _lerp(double start, double end, double progress) =>
      start + (end - start) * progress;
}
