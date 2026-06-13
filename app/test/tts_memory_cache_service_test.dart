// ignore_for_file: experimental_member_use

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:tomato_english_happy_talking/services/recording_export_service.dart';
import 'package:tomato_english_happy_talking/services/recording_export_utils.dart';
import 'package:tomato_english_happy_talking/services/tts_memory_cache_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('strict memory lookup misses without loading disk or remote TTS',
      () async {
    expect(
      await TtsMemoryCacheService.hasInMemory(
        text: 'This sentence has not been preloaded.',
        cachePurpose: 'listening_tts',
        preferRequestedVoice: true,
      ),
      isFalse,
    );
    expect(
      () => TtsMemoryCacheService.requireInMemory(
        text: 'This sentence has not been preloaded.',
        cachePurpose: 'listening_tts',
        preferRequestedVoice: true,
      ),
      throwsA(isA<TtsException>()),
    );
  });

  test('memory MP3 source serves full non-range response from bytes', () async {
    final bytes =
        Uint8List.fromList(List<int>.generate(150000, (i) => i % 251));
    final handle = TtsMemoryHandle(
      key: 'unit',
      bytes: bytes,
      filePath: 'unused.mp3',
    );

    final source = handle.toAudioSource() as StreamAudioSource;
    final response = await source.request(128, 4096);
    final chunks = await response.stream.toList();
    final served = chunks.expand((chunk) => chunk).toList(growable: false);

    expect(response.rangeRequestsSupported, isFalse);
    expect(response.sourceLength, isNull);
    expect(response.offset, isNull);
    expect(response.contentLength, bytes.length);
    expect(served, bytes);
  });

  test('recording export utility profiles stay compact for picture books', () {
    final r720 = RecordingExportUtils.bitrateProfile('1280x720', 'h264');
    final r1080 = RecordingExportUtils.bitrateProfile('1920x1080', 'h265');
    final r1440 = RecordingExportUtils.bitrateProfile('2560x1440', 'h264');

    expect(r720.targetKbps, 2500);
    expect(r720.maxKbps, 4500);
    expect(r1080.targetKbps, 3200);
    expect(r1080.maxKbps, 6500);
    expect(r1440.targetKbps, 9000);
    expect(r1440.maxKbps, 15000);
  });

  test('recording export utility chooses encoders and writes clean srt', () {
    const h264Encoders = '''
 V..... h264_nvenc           NVIDIA NVENC H.264 encoder
 V..... libx264              libx264 H.264 / AVC encoder
''';
    const h265SoftwareOnly = '''
 V..... libx265              libx265 H.265 / HEVC encoder
''';

    expect(
      RecordingExportUtils.selectEncoder('h264', h264Encoders),
      'h264_nvenc',
    );
    expect(
      RecordingExportUtils.selectEncoder('h265', h265SoftwareOnly),
      'libx265',
    );
    expect(
      RecordingExportUtils.selectEncoder('h265', h264Encoders),
      isNull,
    );

    final srt = RecordingExportUtils.srtForCues([
      const RecordingSubtitleCue(
        startMs: 0,
        endMs: 1530,
        english: 'Hello <b>Alice</b>!\nAre you ready?',
        chinese: '你好，爱丽丝！',
      ),
    ]);

    expect(srt, contains('1\r\n00:00:00,000 --> 00:00:01,530'));
    expect(srt, contains('Hello Alice! Are you ready?\r\n你好，爱丽丝！'));
    expect(srt, isNot(contains('<b>')));
  });

  test('recording output basename omits playback mode suffix', () {
    final baseName = RecordingExportService.outputBaseNameForTest(
      seriesTitle: 'Space Story Series',
      articleTitle: 'Space Snacks',
      now: DateTime(2026, 6, 12, 9, 8, 7),
    );

    expect(baseName, 'Space Story Series - Space Snacks - 20260612-090807');
    expect(baseName, isNot(contains('english')));
    expect(baseName, isNot(contains('bilingual')));
  });

  test('recording export utility estimates mp3 duration from frames', () {
    final bytes = _syntheticMpeg1Layer3Frames(frameCount: 10);
    final durationMs = RecordingExportUtils.estimateMp3DurationMs(bytes);

    expect(durationMs, inInclusiveRange(250, 270));
  });
}

Uint8List _syntheticMpeg1Layer3Frames({required int frameCount}) {
  // MPEG1 Layer III, 128kbps, 44.1kHz. Frame length is 417 bytes.
  final header = <int>[0xFF, 0xFB, 0x90, 0x64];
  const frameLength = 417;
  final bytes = <int>[];
  for (var i = 0; i < frameCount; i += 1) {
    bytes.addAll(header);
    bytes.addAll(List<int>.filled(frameLength - header.length, 0));
  }
  return Uint8List.fromList(bytes);
}
