import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';
import 'package:tomato_english_happy_talking/services/translation_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_translation_');
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

  test('uses imported sentence translation before Ark translation', () async {
    _writeArkConfig();
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('Ark translation should not be called for imported subtitles.');
      },
    );

    const sentence = 'Tom finds a bright snack box.';
    final now = DateTime.utc(2026, 1, 2);
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Snack Box',
        content: sentence,
        sentences: const [sentence],
        createdAt: now,
      ),
    );
    await DatabaseService.saveArticleSentenceTranslations(
      articleId,
      [
        ArticleSentenceTranslation(
          articleId: articleId,
          sentenceIndex: 0,
          englishSentence: sentence,
          chineseText: '汤姆发现了一个明亮的零食盒。',
          source: 'imported_bilingual',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    final translated = await TranslationService.toChinese(
      sentence,
      articleId: articleId,
      sentenceIndex: 0,
      cachePurpose: 'follow_translation',
    );

    expect(translated, '汤姆发现了一个明亮的零食盒。');
  });
}

void _writeArkConfig() {
  final securityDir = Directory('security')..createSync();
  File('${securityDir.path}${Platform.pathSeparator}ark.txt').writeAsStringSync(
    'ARK_API_KEY=ark-translation-key-12345678901234567890\n'
    'ARK_TEXT_MODEL=doubao-seed-2-0-lite-260215\n',
  );
}
