import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/core/practice/listening_sentence_visibility.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/listening_audio_material_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_listening_hide_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
    ListeningAudioMaterialService.setPreloadOverrideForTest(null);
  });

  tearDown(() async {
    ListeningAudioMaterialService.setPreloadOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('preserves empty slots and translation indexes after hiding middle sentence',
      () async {
    const sentences = ['First.', 'Second.', 'Third.'];
    final now = DateTime.utc(2026, 7, 5);
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Hide sample',
        content: sentences.join(' '),
        sentences: sentences,
        createdAt: now,
      ),
    );
    await DatabaseService.saveArticleSentenceTranslations(
      articleId,
      [
        for (var index = 0; index < sentences.length; index += 1)
          ArticleSentenceTranslation(
            articleId: articleId,
            sentenceIndex: index,
            englishSentence: sentences[index],
            chineseText: '中文$index',
            source: 'import',
            createdAt: now,
            updatedAt: now,
          ),
      ],
    );

    final hiddenSentences = ['First.', '', 'Third.'];
    await DatabaseService.updateArticleContentAndSentences(
      articleId,
      rebuildArticleContentFromSentences(hiddenSentences),
      hiddenSentences,
    );
    await DatabaseService.deleteArticleSentenceTranslation(articleId, 1);

    final article = await DatabaseService.getArticleById(articleId);
    expect(article?.sentences, hiddenSentences);
    expect(visibleSentenceCount(article?.sentences ?? const []), 2);

    final translations =
        await DatabaseService.getArticleSentenceTranslationsForSentences(
      articleId: articleId,
      sentences: article?.sentences ?? const [],
    );
    expect(translations[0], '中文0');
    expect(translations.containsKey(1), isFalse);
    expect(translations[2], '中文2');
  });

  test('listening audio material status skips hidden sentences', () async {
    const sentences = ['Alpha.', 'Beta.', 'Gamma.'];
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Audio hide sample',
        content: sentences.join(' '),
        sentences: sentences,
        createdAt: DateTime.utc(2026, 7, 5),
      ),
    );

    await _writeCachedListeningTts(articleId: articleId, text: 'Alpha.', bytes: [1]);
    await _writeCachedListeningTts(articleId: articleId, text: 'Beta.', bytes: [2]);
    await _writeCachedListeningTts(articleId: articleId, text: 'Gamma.', bytes: [3]);

    final before = await ListeningAudioMaterialService.status(articleId);
    expect(before.total, 3);
    expect(before.ready, 3);

    await DatabaseService.updateArticleContentAndSentences(
      articleId,
      'Alpha. Gamma.',
      ['Alpha.', '', 'Gamma.'],
    );

    final after = await ListeningAudioMaterialService.status(articleId);
    expect(after.total, 2);
    expect(after.ready, 2);
    expect(after.missing, isEmpty);
  });
}

Future<void> _writeCachedListeningTts({
  required int articleId,
  required String text,
  required List<int> bytes,
}) async {
  final keys = await TtsService.cacheKeysForText(
    text: text,
    cachePurpose: ListeningAudioMaterialService.cachePurpose,
  );
  expect(keys, isNotEmpty);
  await ApiCacheService.putFileBytes(
    cacheKey: keys.first,
    kind: 'tts',
    purpose: ListeningAudioMaterialService.cachePurpose,
    request: {'service': 'unit_tts', 'text': text, 'purpose': ListeningAudioMaterialService.cachePurpose},
    bytes: bytes,
    subdirectory: 'tts',
    extension: 'mp3',
    contentType: 'audio/mpeg',
    articleId: articleId,
  );
}
