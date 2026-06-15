import 'dart:io';

import 'package:path/path.dart' as path_lib;

class AssetPathService {
  const AssetPathService._();

  static String programDirectory() =>
      File(Platform.resolvedExecutable).parent.absolute.path;

  static String defaultSunoOutputDirectory() =>
      path_lib.join(programDirectory(), 'suno-music');

  static String defaultSunoOutputDirectorySetting() => 'suno-music';

  static String resolvePersistentDirectory({
    required String configured,
    required String defaultDirectory,
    String? baseDirectory,
  }) {
    final trimmed = configured.trim();
    final base = _baseDirectory(baseDirectory);
    if (trimmed.isEmpty ||
        isTemporaryAssetDirectory(trimmed, baseDirectory: base)) {
      return defaultDirectory;
    }
    if (!path_lib.isAbsolute(trimmed)) {
      return path_lib.normalize(path_lib.join(base, trimmed));
    }
    return path_lib.normalize(path_lib.absolute(trimmed));
  }

  static bool isTemporaryAssetDirectory(
    String value, {
    String? baseDirectory,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return false;
    }

    final normalized = _absolutePath(trimmed, baseDirectory: baseDirectory);
    final segments = path_lib
        .split(normalized)
        .map((segment) => segment.toLowerCase())
        .toList(growable: false);
    if (segments.contains('.tmp')) {
      return true;
    }

    final systemTemp =
        path_lib.normalize(path_lib.absolute(Directory.systemTemp.path));
    return _sameOrWithin(systemTemp, normalized);
  }

  static Future<String> migrateTemporaryAssetFileIfNeeded({
    required String sourcePath,
    required String targetDirectory,
  }) async {
    final trimmed = sourcePath.trim();
    if (trimmed.isEmpty || !isTemporaryAssetDirectory(trimmed)) {
      return trimmed;
    }

    final source = File(trimmed);
    if (!await source.exists()) {
      return trimmed;
    }

    final directory = Directory(targetDirectory);
    await directory.create(recursive: true);
    final target = await _uniqueTargetForCopy(
      directory: directory,
      filename: path_lib.basename(source.path),
      sourceLength: await source.length(),
    );
    if (path_lib.equals(
      path_lib.normalize(path_lib.absolute(source.path)),
      path_lib.normalize(path_lib.absolute(target.path)),
    )) {
      return source.path;
    }
    if (await target.exists() &&
        await target.length() == await source.length()) {
      return target.path;
    }
    await source.copy(target.path);
    return target.path;
  }

  static Future<File> _uniqueTargetForCopy({
    required Directory directory,
    required String filename,
    required int sourceLength,
  }) async {
    final safeName = _safeFilename(filename);
    final extension = path_lib.extension(safeName);
    final stem = path_lib.basenameWithoutExtension(safeName);
    var candidate = File(path_lib.join(directory.path, safeName));
    if (!await candidate.exists() || await candidate.length() == sourceLength) {
      return candidate;
    }

    for (var index = 2; index < 10000; index++) {
      final nextName =
          extension.isEmpty ? '${stem}_$index' : '${stem}_$index$extension';
      candidate = File(path_lib.join(directory.path, nextName));
      if (!await candidate.exists() ||
          await candidate.length() == sourceLength) {
        return candidate;
      }
    }
    return File(
      path_lib.join(
        directory.path,
        '${stem}_${DateTime.now().millisecondsSinceEpoch}$extension',
      ),
    );
  }

  static String _safeFilename(String filename) {
    final cleaned = filename
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty
        ? 'asset_${DateTime.now().millisecondsSinceEpoch}'
        : cleaned;
  }

  static String _absolutePath(String value, {String? baseDirectory}) {
    final trimmed = value.trim();
    if (path_lib.isAbsolute(trimmed)) {
      return path_lib.normalize(trimmed);
    }
    return path_lib
        .normalize(path_lib.join(_baseDirectory(baseDirectory), trimmed));
  }

  static String _baseDirectory(String? baseDirectory) {
    final trimmed = (baseDirectory ?? '').trim();
    if (trimmed.isNotEmpty) {
      return path_lib.normalize(path_lib.absolute(trimmed));
    }
    return programDirectory();
  }

  static bool _sameOrWithin(String parent, String child) {
    final normalizedParent =
        path_lib.normalize(path_lib.absolute(parent)).toLowerCase();
    final normalizedChild =
        path_lib.normalize(path_lib.absolute(child)).toLowerCase();
    return path_lib.equals(normalizedParent, normalizedChild) ||
        path_lib.isWithin(normalizedParent, normalizedChild);
  }
}
