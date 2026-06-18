import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/chat_chapter_guide_service.dart';
import 'package:tomato_english_happy_talking/services/content_safety_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
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
    tempDir = await Directory.systemTemp.createTemp('tomato_chat_guide_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    TextGenerationService.setPostOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDown(() async {
    TextGenerationService.setPostOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('prepares and stores a semantic guide from the complete chapter',
      () async {
    _writeArkConfig();
    final fullChapter = List.generate(
      80,
      (index) =>
          'Story section $index keeps unique chapter marker marker_$index for guide generation.',
    ).join('\n\n');
    final postedBodies = <Map<String, dynamic>>[];
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postedBodies.add(Map<String, dynamic>.from(body));
        return {
          'choices': [
            {
              'message': {
                'content': '''
Chapter summary: A compact guide.
Ordered coverage points:
1. Beginning scene.
2. Middle scene.
3. Ending scene.
Completion rubric: Finish after the learner covers every point.
Ability assessment cues: Listen for ordered retelling.
''',
              },
            }
          ],
        };
      },
    );

    final first = await ChatChapterGuideService.prepareGuide(
      articleTitle: 'Long Chapter',
      articleContent: fullChapter,
      sentences: fullChapter.split(RegExp(r'\n\s*\n+')),
      articleId: 7,
    );
    final second = await ChatChapterGuideService.prepareGuide(
      articleTitle: 'Long Chapter',
      articleContent: fullChapter,
      sentences: fullChapter.split(RegExp(r'\n\s*\n+')),
      articleId: 7,
    );

    expect(first.source, TextGenerationReplySource.remote);
    expect(second.source, TextGenerationReplySource.stored);
    expect(first.text, contains('Chapter summary'));
    expect(second.text, first.text);
    expect(postedBodies, hasLength(1));
    final db = await DatabaseService.database;
    final guideRows = await db.query('article_chat_guides');
    final cacheRows = await db.query('api_cache_entries');
    expect(guideRows, hasLength(1));
    expect(guideRows.single['article_id'], 7);
    expect(guideRows.single['purpose'], ChatChapterGuideService.cachePurpose);
    expect(guideRows.single['guide_text'], contains('Chapter summary'));
    expect(cacheRows, isEmpty);
    final messages = postedBodies.single['messages'] as List;
    final systemMessage = messages.first as Map;
    final userMessage = messages.last as Map;
    expect(
      systemMessage['content'] as String,
      contains('conversation guide'),
    );
    expect(
      userMessage['content'] as String,
      contains('Numbered chapter sentences'),
    );
    expect(userMessage['content'] as String, contains('marker_0'));
    expect(userMessage['content'] as String, contains('marker_79'));
    expect(
      userMessage['content'] as String,
      isNot(contains('Keep the same number')),
    );
  });

  test('guide generation fails without a text key', () async {
    expect(
      () => ChatChapterGuideService.prepareGuide(
        articleTitle: 'No Key Chapter',
        articleContent: 'Sentence one. Sentence two.',
        sentences: const ['Sentence one.', 'Sentence two.'],
      ),
      throwsA(isA<TextGenerationException>()),
    );
  });

  test('submits chapter guide with content-safety rules applied', () async {
    _writeArkConfig();
    await _insertContentSafetyRule('heads', 'he-ads');
    await _insertContentSafetyRule('execution', 'exe-cution');
    Map<String, dynamic>? seenBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': 'Chapter summary: safe guide\n'
                    'Ordered coverage points:\n'
                    '1. The Queen shouts.\n'
                    'Completion rubric: Finish after the point is discussed.\n'
                    'Ability assessment cues: Listen for clear retelling.',
              },
            }
          ],
        };
      },
    );

    await ChatChapterGuideService.prepareGuide(
      articleTitle: 'Queen Chapter',
      articleContent:
          'The Queen shouted "Off with their heads!" before an execution.',
      sentences: const [
        'The Queen shouted "Off with their heads!" before an execution.',
      ],
      articleId: 9,
    );

    final messages = seenBody?['messages'] as List;
    final userMessage = messages.last as Map;
    final promptText = userMessage['content'] as String;
    expect(promptText, contains('he-ads'));
    expect(promptText, contains('exe-cution'));
    expect(promptText, contains('Queen shouted'));
    expect(promptText, isNot(contains('royal punishment')));
    expect(promptText, isNot(contains('serious trouble')));
  });
}

void _writeArkConfig() {
  AppConfig.setRuntimeConfigForTest(
    aiProvider: AppConfig.aiProviderVolcengine,
    volcArkApiKey: 'ark-chat-guide-key-12345678901234567890',
    volcArkTextModel: 'doubao-seed-2-0-lite-260215',
  );
}

Future<void> _insertContentSafetyRule(
  String sourceTerm,
  String replacement,
) async {
  final db = await DatabaseService.database;
  final now = DateTime.now().toIso8601String();
  await db.insert('content_safety_rules', {
    'source_term': sourceTerm,
    'replacement': replacement,
    'service_kind': ContentSafetyService.serviceOpenAiText,
    'purpose_scope': ContentSafetyService.purposeAny,
    'match_type': 'word',
    'confidence': 0.9,
    'enabled': 1,
    'source_failure_id': null,
    'created_at': now,
    'updated_at': now,
  });
}
