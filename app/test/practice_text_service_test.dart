import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/practice_text_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_practice_text_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    TextGenerationService.setPostOverrideForTest(null);
  });

  tearDown(() async {
    TextGenerationService.setPostOverrideForTest(null);
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('generates fallback English practice article from Chinese story',
      () async {
    final reply = await PracticeTextService.translateToEnglishForPractice(
      content: '妈妈为孩子做了一个选择。她想着爱、家庭和未来。',
    );

    expect(reply.source, TextGenerationReplySource.mockNoKey);
    expect(reply.text, contains('A mother makes a choice'));
    expect(reply.text, isNot(contains(RegExp(r'[\u3400-\u9FFF]'))));
  });

  test('extracts English body from mixed Chinese and English material',
      () async {
    final reply = await PracticeTextService.translateToEnglishForPractice(
      content:
          '中文：汤姆发现了一个明亮的零食盒。\nTom finds a bright snack box.\n译文：汤姆发现了一个明亮的零食盒。',
    );

    expect(reply.source, TextGenerationReplySource.mockNoKey);
    expect(reply.text, 'Tom finds a bright snack box.');
  });

  test('cleans generated title to a compact English title', () async {
    _writeArkConfig();
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {
                'content':
                    "Title: the unbelievably long sparkling adventure across tomorrow's garden and beyond.\nDo not use this line.",
              },
            }
          ],
        };
      },
    );

    final reply = await PracticeTextService.suggestArticleTitle(
      content:
          'Mia opens a map and begins a sparkling adventure across the garden.',
    );

    expect(reply.source, TextGenerationReplySource.remote);
    expect(reply.text.length, lessThanOrEqualTo(80));
    expect(reply.text.split(RegExp(r'\s+')), hasLength(5));
    expect(reply.text, isNot(contains('Title:')));
    expect(reply.text, isNot(contains('Do not use this line')));
  });

  test('uses word lookup fallback when Ark returns invalid JSON', () async {
    _writeArkConfig();
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {'content': 'not json'},
            }
          ],
        };
      },
    );

    final lookup = await PracticeTextService.lookupWordForLearning(
      word: 'bright',
      sentence: 'Tom finds a bright snack box.',
    );

    expect(lookup.source, TextGenerationReplySource.remote);
    expect(lookup.word, 'bright');
    expect(lookup.phonetic, '/brait/');
    expect(lookup.meaning, contains('明亮'));
    expect(lookup.sentenceMeaning, contains('明亮'));
  });
}

void _writeArkConfig() {
  final securityDir = Directory('security')..createSync();
  File('${securityDir.path}${Platform.pathSeparator}ark.txt').writeAsStringSync(
    'ARK_API_KEY=ark-practice-key-12345678901234567890\n'
    'ARK_TEXT_MODEL=doubao-seed-2-0-lite-260215\n',
  );
}
