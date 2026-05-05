import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';

void main() {
  test('finds encrypted config files from a nested release directory', () {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_app_config_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    final encryptedFile = File(_joinPath(securityDirectory.path, 'api-key.txt'))
      ..writeAsStringSync('{}');
    final releaseDirectory = Directory(
      _joinPath(
        tempDirectory.path,
        'release/windows/tomato_english_happy_talking',
      ),
    )..createSync(recursive: true);

    Directory.current = releaseDirectory;

    final found = AppConfig.findExistingFileForTest(['security/api-key.txt']);

    expect(found?.absolute.path, encryptedFile.absolute.path);
  });
}

String _joinPath(String basePath, String childPath) {
  final separator = Platform.pathSeparator;
  final normalizedChild =
      childPath.replaceAll('/', separator).replaceAll(r'\', separator);
  if (basePath.endsWith(separator)) {
    return '$basePath$normalizedChild';
  }
  return '$basePath$separator$normalizedChild';
}
