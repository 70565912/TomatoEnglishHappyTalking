import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/page_transition_renderer.dart';

void main() {
  test('renders every transition at stable endpoints', () async {
    final fromImage = await _solidImage(const ui.Color(0xFFCC3333));
    final toImage = await _solidImage(const ui.Color(0xFF3366CC));
    addTearDown(fromImage.dispose);
    addTearDown(toImage.dispose);

    for (final transition in RecordingPageTransition.values) {
      for (final progress in [0.0, 0.5, 1.0]) {
        final png = await PageTransitionRenderer.renderPng(
          fromImage: fromImage,
          toImage: toImage,
          progress: progress,
          transition: transition,
          width: 64,
          height: 36,
        );
        expect(png.length, greaterThan(32));
        expect(png.take(8), [
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ]);
        final codec = await ui.instantiateImageCodec(png);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 64);
        expect(frame.image.height, 36);
        frame.image.dispose();
        codec.dispose();
      }
    }
  });

  test('keeps shared live renderer constants aligned with export timing', () {
    expect(PageTransitionRenderer.durationMs, 500);
    expect(PageTransitionRenderer.liveFrameCount, 8);
    expect(PageTransitionRenderer.liveWidth, 1280);
    expect(PageTransitionRenderer.liveHeight, 720);
    expect(RecordingPageTransition.parse('unsupported'),
        RecordingPageTransition.none);
  });
}

Future<ui.Image> _solidImage(ui.Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 32, 18),
    ui.Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 18);
  picture.dispose();
  return image;
}
