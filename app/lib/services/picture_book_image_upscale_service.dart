import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;

typedef PictureBookUpscaleProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

class PictureBookImageUpscaleException implements Exception {
  const PictureBookImageUpscaleException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs the bundled Real-ESRGAN NCNN Vulkan executable for picture-book pages.
class PictureBookImageUpscaleService {
  static const String modelName2x = 'realesr-animevideov3-x2';
  static const String modelName4x = 'realesr-animevideov3-x4';
  static const Duration processTimeout = Duration(minutes: 10);

  @visibleForTesting
  static String? executablePathOverride;

  @visibleForTesting
  static bool? windowsPlatformOverride;

  @visibleForTesting
  static PictureBookUpscaleProcessRunner? processRunnerOverride;

  static String programDirectory() =>
      File(Platform.resolvedExecutable).parent.absolute.path;

  static String bundledDirectoryPath() =>
      path_lib.join(programDirectory(), 'realesrgan');

  static String bundledExecutablePath() =>
      path_lib.join(bundledDirectoryPath(), 'realesrgan-ncnn-vulkan.exe');

  static bool get isSupportedPlatform =>
      windowsPlatformOverride ?? Platform.isWindows;

  @visibleForTesting
  static void resetTestOverrides() {
    executablePathOverride = null;
    windowsPlatformOverride = null;
    processRunnerOverride = null;
  }

  static Future<Uint8List> upscalePng({
    required Uint8List inputBytes,
    required int scale,
  }) async {
    if (inputBytes.isEmpty) {
      throw const PictureBookImageUpscaleException('待超分图片为空');
    }
    if (scale != 2 && scale != 4) {
      throw PictureBookImageUpscaleException('不支持的超分倍数：$scale');
    }
    if (!isSupportedPlatform) {
      throw const PictureBookImageUpscaleException('当前平台暂不支持本地绘本图片超分');
    }

    final executable = executablePathOverride?.trim().isNotEmpty == true
        ? executablePathOverride!.trim()
        : bundledExecutablePath();
    final executableFile = File(executable);
    if (!await executableFile.exists()) {
      throw PictureBookImageUpscaleException('程序目录缺少绘本超分工具：$executable');
    }

    final modelName = scale == 4 ? modelName4x : modelName2x;
    final modelDirectory = path_lib.join(executableFile.parent.path, 'models');
    for (final extension in const ['param', 'bin']) {
      final modelPath = path_lib.join(modelDirectory, '$modelName.$extension');
      if (!await File(modelPath).exists()) {
        throw PictureBookImageUpscaleException('程序目录缺少绘本超分模型：$modelPath');
      }
    }

    final tempDirectory = await Directory.systemTemp.createTemp(
      'tomato_picture_upscale_',
    );
    try {
      final inputPath = path_lib.join(tempDirectory.path, 'input.png');
      final outputPath = path_lib.join(tempDirectory.path, 'output.png');
      await File(inputPath).writeAsBytes(inputBytes, flush: true);

      final runner = processRunnerOverride ?? _runProcess;
      final result = await runner(executable, [
        '-i',
        inputPath,
        '-o',
        outputPath,
        '-n',
        modelName,
        '-s',
        '$scale',
        '-t',
        '32',
        '-m',
        modelDirectory,
      ], workingDirectory: executableFile.parent.path).timeout(processTimeout);

      if (result.exitCode != 0) {
        final detail = _processDetail(result);
        throw PictureBookImageUpscaleException(
          detail.isEmpty
              ? '绘本图片超分失败（退出码 ${result.exitCode}）'
              : '绘本图片超分失败：$detail',
        );
      }

      final outputFile = File(outputPath);
      if (!await outputFile.exists()) {
        throw const PictureBookImageUpscaleException('绘本图片超分未生成输出文件');
      }
      final outputBytes = await outputFile.readAsBytes();
      if (outputBytes.isEmpty) {
        throw const PictureBookImageUpscaleException('绘本图片超分输出为空');
      }
      return Uint8List.fromList(outputBytes);
    } on TimeoutException {
      throw const PictureBookImageUpscaleException('绘本图片超分超时，请稍后重试');
    } finally {
      try {
        await tempDirectory.delete(recursive: true);
      } catch (_) {
        // Temporary cleanup is best effort; the import result takes priority.
      }
    }
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    final stdoutFuture = process.stdout
        .transform(systemEncoding.decoder)
        .join();
    final stderrFuture = process.stderr
        .transform(systemEncoding.decoder)
        .join();
    try {
      final exitCode = await process.exitCode.timeout(processTimeout);
      return ProcessResult(
        process.pid,
        exitCode,
        await stdoutFuture,
        await stderrFuture,
      );
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      rethrow;
    }
  }

  static String _processDetail(ProcessResult result) {
    final stderr = result.stderr?.toString().trim() ?? '';
    final stdout = result.stdout?.toString().trim() ?? '';
    final detail = stderr.isNotEmpty ? stderr : stdout;
    if (detail.length <= 800) {
      return detail;
    }
    return detail.substring(detail.length - 800);
  }
}
