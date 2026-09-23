import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/logging/tomato_logger.dart';
import 'page_transition_renderer.dart';
import 'picture_book_service.dart';

/// Generates a small, bounded frame batch for WebView live playback.
class PictureBookTransitionService {
  static Future<Map<String, dynamic>> renderFrames({
    required int articleId,
    required int fromPageIndex,
    required int toPageIndex,
    required RecordingPageTransition pageTransition,
  }) async {
    if (fromPageIndex == toPageIndex) {
      throw const FormatException('绘本转场必须切换到另一页');
    }
    if (pageTransition == RecordingPageTransition.none) {
      return _emptyPayload(
        articleId: articleId,
        fromPageIndex: fromPageIndex,
        toPageIndex: toPageIndex,
        pageTransition: pageTransition,
      );
    }

    final stopwatch = Stopwatch()..start();
    final fromBytes = await PictureBookService.pageImageBytes(
      articleId: articleId,
      pageIndex: fromPageIndex,
    );
    final toBytes = await PictureBookService.pageImageBytes(
      articleId: articleId,
      pageIndex: toPageIndex,
    );
    if (fromBytes == null || toBytes == null) {
      throw StateError('绘本转场图片不可用');
    }

    ui.Image? fromImage;
    ui.Image? toImage;
    try {
      fromImage = await _decodeImage(fromBytes);
      toImage = await _decodeImage(toBytes);
      final frames = <String>[];
      for (var index = 0;
          index < PageTransitionRenderer.liveFrameCount;
          index += 1) {
        final progress = index / (PageTransitionRenderer.liveFrameCount - 1);
        final png = await PageTransitionRenderer.renderPng(
          fromImage: fromImage,
          toImage: toImage,
          progress: progress,
          transition: pageTransition,
          width: PageTransitionRenderer.liveWidth,
          height: PageTransitionRenderer.liveHeight,
        );
        frames.add('data:image/png;base64,${base64Encode(png)}');
      }
      final bytes = frames.fold<int>(0, (total, frame) => total + frame.length);
      TomatoLogger.info(
        category: 'picture_book',
        event: 'transition_frames.generated',
        data: {
          'articleId': articleId,
          'fromPageIndex': fromPageIndex,
          'toPageIndex': toPageIndex,
          'transition': pageTransition.name,
          'frameCount': frames.length,
          'estimatedChars': bytes,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      return {
        'articleId': articleId,
        'fromPageIndex': fromPageIndex,
        'toPageIndex': toPageIndex,
        'pageTransition': pageTransition.name,
        'durationMs': PageTransitionRenderer.durationMs,
        'width': PageTransitionRenderer.liveWidth,
        'height': PageTransitionRenderer.liveHeight,
        'frames': frames,
      };
    } finally {
      fromImage?.dispose();
      toImage?.dispose();
    }
  }

  static Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  static Map<String, dynamic> _emptyPayload({
    required int articleId,
    required int fromPageIndex,
    required int toPageIndex,
    required RecordingPageTransition pageTransition,
  }) =>
      {
        'articleId': articleId,
        'fromPageIndex': fromPageIndex,
        'toPageIndex': toPageIndex,
        'pageTransition': pageTransition.name,
        'durationMs': PageTransitionRenderer.durationMs,
        'width': PageTransitionRenderer.liveWidth,
        'height': PageTransitionRenderer.liveHeight,
        'frames': const <String>[],
      };
}
