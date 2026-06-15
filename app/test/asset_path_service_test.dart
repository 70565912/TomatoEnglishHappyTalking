import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:tomato_english_happy_talking/services/asset_path_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tomato_asset_path_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('detects workspace .tmp and system temp directories as temporary', () {
    expect(
      AssetPathService.isTemporaryAssetDirectory(
        path_lib.join(tempDir.path, '.tmp', 'qa-suno-song', 'downloads'),
      ),
      isTrue,
    );
    expect(
      AssetPathService.isTemporaryAssetDirectory(
        path_lib.join(Directory.systemTemp.path, 'tomato-song'),
      ),
      isTrue,
    );
    expect(
      AssetPathService.isTemporaryAssetDirectory(
        path_lib.join(Directory.current.path, 'suno-music'),
      ),
      isFalse,
    );
  });

  test('resolves temporary configured directory to the persistent default', () {
    final defaultDirectory = path_lib.join(tempDir.path, 'suno-music');
    final resolved = AssetPathService.resolvePersistentDirectory(
      configured: path_lib.join(tempDir.path, '.tmp', 'downloads'),
      defaultDirectory: defaultDirectory,
    );

    expect(resolved, defaultDirectory);
  });

  test('resolves relative configured directory from program directory', () {
    final programDir = path_lib.join(Directory.current.path, 'program-root');
    final defaultDirectory = path_lib.join(programDir, 'suno-music');

    expect(
      AssetPathService.defaultSunoOutputDirectorySetting(),
      'suno-music',
    );
    expect(
      AssetPathService.resolvePersistentDirectory(
        configured: 'songs/suno',
        defaultDirectory: defaultDirectory,
        baseDirectory: programDir,
      ),
      path_lib.join(programDir, 'songs', 'suno'),
    );
    expect(
      AssetPathService.resolvePersistentDirectory(
        configured: defaultDirectory,
        defaultDirectory: path_lib.join(programDir, 'fallback'),
        baseDirectory: programDir,
      ),
      defaultDirectory,
    );
  });

  test('copies temporary asset file into persistent target directory',
      () async {
    final temporaryDir = Directory(path_lib.join(tempDir.path, '.tmp'));
    await temporaryDir.create(recursive: true);
    final source = File(path_lib.join(temporaryDir.path, 'song.mp3'));
    await source.writeAsBytes([1, 2, 3, 4], flush: true);
    final targetDir = path_lib.join(tempDir.path, 'suno-music');

    final migrated = await AssetPathService.migrateTemporaryAssetFileIfNeeded(
      sourcePath: source.path,
      targetDirectory: targetDir,
    );

    expect(migrated, path_lib.join(targetDir, 'song.mp3'));
    expect(await File(migrated).readAsBytes(), [1, 2, 3, 4]);
    expect(await source.exists(), isTrue);
  });
}
