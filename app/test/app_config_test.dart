import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';

void main() {
  test('finds local config files from a nested release directory', () {
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
    final speechKeyFile =
        File(_joinPath(securityDirectory.path, 'speech-api-key.txt'))
          ..writeAsStringSync('speech-key-from-security\n');
    final releaseDirectory = Directory(
      _joinPath(
        tempDirectory.path,
        'release/windows/tomato_english_happy_talking',
      ),
    )..createSync(recursive: true);

    Directory.current = releaseDirectory;

    final found =
        AppConfig.findExistingFileForTest(['security/speech-api-key.txt']);

    expect(found?.absolute.path, speechKeyFile.absolute.path);
  });

  test('does not read Ark image key from AccessKey.txt near release directory',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_access_key_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final accessKeyFile = File(_joinPath(tempDirectory.path, 'AccessKey.txt'))
      ..writeAsStringSync('image-key-from-file\n');
    final releaseDirectory = Directory(
      _joinPath(
        tempDirectory.path,
        'release/windows/tomato_english_happy_talking',
      ),
    )..createSync(recursive: true);

    Directory.current = releaseDirectory;

    expect(await AppConfig.volcArkImageApiKey, '');
    expect(accessKeyFile.existsSync(), isTrue);
  });

  test('reads Ark image key from ark.txt when AccessKey.txt also exists',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_ark_image_key_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    File(_joinPath(securityDirectory.path, 'ark.txt')).writeAsStringSync(
      'ARK_API_KEY=Bearer ark-image-key-12345678901234567890\n',
    );
    File(_joinPath(securityDirectory.path, 'AccessKey.txt')).writeAsStringSync(
      'AccessKeyId: visual-access-key-id\n'
      'SecretAccessKey: visual-secret-access-key\n',
    );
    final releaseDirectory = Directory(
      _joinPath(
        tempDirectory.path,
        'release/windows/tomato_english_happy_talking',
      ),
    )..createSync(recursive: true);

    Directory.current = releaseDirectory;

    expect(
      await AppConfig.volcArkImageApiKey,
      'ark-image-key-12345678901234567890',
    );
  });

  test('reads speech engine key from speech-api-key.txt near release directory',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_speech_key_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final speechKeyFile =
        File(_joinPath(tempDirectory.path, 'speech-api-key.txt'))
          ..writeAsStringSync(
            'short-legacy-looking-id\n'
            '550e8400-e29b-41d4-a716-446655440000\n',
          );
    final releaseDirectory = Directory(
      _joinPath(
        tempDirectory.path,
        'release/windows/tomato_english_happy_talking',
      ),
    )..createSync(recursive: true);

    Directory.current = releaseDirectory;

    expect(
      await AppConfig.volcSpeechApiKey,
      '550e8400-e29b-41d4-a716-446655440000',
    );
    expect(speechKeyFile.existsSync(), isTrue);
  });

  test('reads Ark text key and model from labeled security ark file', () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_ark_labeled_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    File(_joinPath(securityDirectory.path, 'ark.txt')).writeAsStringSync(
      'ARK_API_KEY=Bearer ark-labeled-key-12345678901234567890\n'
      'ARK_TEXT_MODEL=doubao-seed-2-0-lite-260215\n',
    );
    final releaseDirectory = Directory(
      _joinPath(
        tempDirectory.path,
        'release/windows/tomato_english_happy_talking',
      ),
    )..createSync(recursive: true);

    Directory.current = releaseDirectory;

    expect(
      await AppConfig.volcArkTextApiKey,
      'ark-labeled-key-12345678901234567890',
    );
    expect(
      await AppConfig.volcArkTextModel,
      'doubao-seed-2-0-lite-260215',
    );
  });

  test('strips Bearer prefix from Ark text key', () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_ark_bearer_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    File(_joinPath(tempDirectory.path, 'ark.txt')).writeAsStringSync(
      'Bearer ark-bearer-key-123456789012345678901234\n',
    );
    Directory.current = tempDirectory;

    expect(
      await AppConfig.volcArkTextApiKey,
      'ark-bearer-key-123456789012345678901234',
    );
  });

  test('reads MiniMax API key from security MiniMax file', () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_minimax_key_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    File(_joinPath(securityDirectory.path, 'MiniMax.txt')).writeAsStringSync(
      'MINIMAX_API_KEY=Bearer minimax-key-123456789012345678901234\n',
    );
    Directory.current = tempDirectory;

    expect(
      await AppConfig.miniMaxApiKey,
      'minimax-key-123456789012345678901234',
    );
  });

  test('chooses longest unlabeled Ark key candidate in multiline file',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_ark_unlabeled_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    File(_joinPath(tempDirectory.path, 'ark.txt')).writeAsStringSync(
      'short-value\n'
      'ark-long-key-123456789012345678901234567890\n'
      'ark-medium-key-12345678901234567890\n',
    );
    Directory.current = tempDirectory;

    expect(
      await AppConfig.volcArkTextApiKey,
      'ark-long-key-123456789012345678901234567890',
    );
    expect(
      await AppConfig.volcArkTextModel,
      AppConfig.defaultVolcArkTextModel,
    );
  });

  test('does not infer Ark model from unlabeled multiline file', () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_ark_model_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    File(_joinPath(tempDirectory.path, 'ark.txt')).writeAsStringSync(
      'ark-long-key-123456789012345678901234567890\n'
      'doubao-seed-2-0-pro-model-name-that-is-intentionally-long\n',
    );
    Directory.current = tempDirectory;

    expect(
      await AppConfig.volcArkTextModel,
      AppConfig.defaultVolcArkTextModel,
    );
  });

  test('does not treat AK SK lines as Ark bearer key', () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_ark_aksk_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    File(_joinPath(tempDirectory.path, 'ark.txt')).writeAsStringSync(
      'AccessKeyId: example-id\nSecretAccessKey: example-secret\n',
    );
    Directory.current = tempDirectory;

    expect(await AppConfig.volcArkTextApiKey, '');
  });

  test('does not treat AccessKeyId SecretAccessKey file as Ark bearer key',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_access_pair_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    File(_joinPath(tempDirectory.path, 'AccessKey.txt')).writeAsStringSync(
      'AccessKeyId: example-id\nSecretAccessKey: example-secret\n',
    );
    Directory.current = tempDirectory;

    expect(await AppConfig.volcArkImageApiKey, '');
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
