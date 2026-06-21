import 'dart:math' as math;
import 'dart:typed_data';

class RecordingBitrateProfile {
  const RecordingBitrateProfile(this.targetKbps, this.maxKbps);

  final int targetKbps;
  final int maxKbps;
}

class RecordingSubtitleCue {
  const RecordingSubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.english,
    required this.chinese,
  });

  final int startMs;
  final int endMs;
  final String english;
  final String chinese;
}

class RecordingExportUtils {
  const RecordingExportUtils._();

  static String? selectEncoder(String codec, String encodersOutput) {
    final candidates = selectEncoderCandidates(codec, encodersOutput);
    return candidates.isEmpty ? null : candidates.first;
  }

  static List<String> selectEncoderCandidates(
    String codec,
    String encodersOutput,
  ) {
    final normalized = codec.trim().toLowerCase();
    final candidates = normalized == 'h265'
        ? const ['hevc_nvenc', 'hevc_qsv', 'hevc_amf', 'hevc_mf', 'libx265']
        : const ['h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_mf', 'libx264'];
    final available = <String>[];
    for (final candidate in candidates) {
      if (RegExp(r'(^|\s)' + RegExp.escape(candidate) + r'(\s|$)',
              multiLine: true)
          .hasMatch(encodersOutput)) {
        available.add(candidate);
      }
    }
    return available;
  }

  static RecordingBitrateProfile bitrateProfile(
    String resolution,
    String codec,
  ) {
    final normalizedResolution = resolution.trim().toLowerCase();
    final normalizedCodec = codec.trim().toLowerCase();
    switch ((normalizedResolution, normalizedCodec)) {
      case ('1280x720', 'h264'):
        return const RecordingBitrateProfile(2500, 4500);
      case ('1280x720', 'h265'):
        return const RecordingBitrateProfile(1600, 3200);
      case ('1920x1080', 'h264'):
        return const RecordingBitrateProfile(5000, 9000);
      case ('1920x1080', 'h265'):
        return const RecordingBitrateProfile(3200, 6500);
      case ('2560x1440', 'h264'):
        return const RecordingBitrateProfile(9000, 15000);
      case ('2560x1440', 'h265'):
        return const RecordingBitrateProfile(5500, 10000);
      default:
        return const RecordingBitrateProfile(5000, 9000);
    }
  }

  static String srtForCues(List<RecordingSubtitleCue> cues) {
    final buffer = StringBuffer();
    for (var i = 0; i < cues.length; i += 1) {
      final cue = cues[i];
      buffer
        ..write(i + 1)
        ..write('\r\n');
      buffer
        ..write(formatSrtTime(cue.startMs))
        ..write(' --> ')
        ..write(formatSrtTime(cue.endMs))
        ..write('\r\n')
        ..write(cleanSubtitleText(cue.english))
        ..write('\r\n');
      final chinese = cleanSubtitleText(cue.chinese);
      if (chinese.isNotEmpty) {
        buffer
          ..write(chinese)
          ..write('\r\n');
      }
      buffer.write('\r\n');
    }
    return buffer.toString();
  }

  static String formatSrtTime(int ms) {
    final duration = Duration(milliseconds: math.max(0, ms));
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final millis = duration.inMilliseconds.remainder(1000);
    return '${_two(hours)}:${_two(minutes)}:${_two(seconds)},'
        '${millis.toString().padLeft(3, '0')}';
  }

  static String cleanSubtitleText(String text) => text
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int estimateMp3DurationMs(Uint8List bytes) {
    if (bytes.isEmpty) {
      return 0;
    }
    var offset = _skipId3v2(bytes);
    var totalSamples = 0;
    var sampleRate = 0;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF || (bytes[offset + 1] & 0xE0) != 0xE0) {
        offset += 1;
        continue;
      }
      final header = _parseMp3Header(bytes, offset);
      if (header == null || header.frameLength <= 0) {
        offset += 1;
        continue;
      }
      totalSamples += header.samplesPerFrame;
      sampleRate = header.sampleRate;
      offset += header.frameLength;
    }
    if (totalSamples <= 0 || sampleRate <= 0) {
      return 0;
    }
    return (totalSamples * 1000 / sampleRate).round();
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static int _skipId3v2(Uint8List bytes) {
    if (bytes.length < 10 ||
        bytes[0] != 0x49 ||
        bytes[1] != 0x44 ||
        bytes[2] != 0x33) {
      return 0;
    }
    final size = ((bytes[6] & 0x7F) << 21) |
        ((bytes[7] & 0x7F) << 14) |
        ((bytes[8] & 0x7F) << 7) |
        (bytes[9] & 0x7F);
    return math.min(bytes.length, 10 + size);
  }

  static _Mp3Header? _parseMp3Header(Uint8List bytes, int offset) {
    final b1 = bytes[offset + 1];
    final b2 = bytes[offset + 2];
    final versionBits = (b1 >> 3) & 0x03;
    final layerBits = (b1 >> 1) & 0x03;
    final bitrateIndex = (b2 >> 4) & 0x0F;
    final sampleRateIndex = (b2 >> 2) & 0x03;
    final padding = (b2 >> 1) & 0x01;
    if (versionBits == 1 ||
        layerBits != 1 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15 ||
        sampleRateIndex == 3) {
      return null;
    }
    final mpeg1 = versionBits == 3;
    final bitrate =
        (mpeg1 ? _mpeg1Layer3Bitrates : _mpeg2Layer3Bitrates)[bitrateIndex] *
            1000;
    final sampleRate = switch (versionBits) {
      3 => const [44100, 48000, 32000][sampleRateIndex],
      2 => const [22050, 24000, 16000][sampleRateIndex],
      0 => const [11025, 12000, 8000][sampleRateIndex],
      _ => 0,
    };
    if (bitrate <= 0 || sampleRate <= 0) {
      return null;
    }
    return _Mp3Header(
      frameLength:
          ((mpeg1 ? 144 : 72) * bitrate / sampleRate).floor() + padding,
      samplesPerFrame: mpeg1 ? 1152 : 576,
      sampleRate: sampleRate,
    );
  }

  static const _mpeg1Layer3Bitrates = [
    0,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
  ];

  static const _mpeg2Layer3Bitrates = [
    0,
    8,
    16,
    24,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    144,
    160,
  ];
}

class _Mp3Header {
  const _Mp3Header({
    required this.frameLength,
    required this.samplesPerFrame,
    required this.sampleRate,
  });

  final int frameLength;
  final int samplesPerFrame;
  final int sampleRate;
}
