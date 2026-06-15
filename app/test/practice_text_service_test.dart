import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
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

  test('mixed-material AI prompt keeps story only and can translate Chinese',
      () async {
    _writeArkConfig();
    Map<String, dynamic>? seenBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': 'Alice walked back to the garden.',
              },
            }
          ],
        };
      },
    );

    final reply = await PracticeTextService.translateToEnglishForPractice(
      content: '''
课程导读
这段是讲解。

中文故事
爱丽丝走回花园。

【文化卡片】
生词好句
I can't stand it when people don't attend to the rules.
''',
    );

    final messages = seenBody?['messages'] as List;
    final system = (messages.first as Map)['content'] as String;
    final user = (messages.last as Map)['content'] as String;
    expect(reply.source, TextGenerationReplySource.remote);
    expect(reply.text, 'Alice walked back to the garden.');
    expect(system, contains('If the story content is Chinese'));
    expect(system,
        contains('translate only that story content into natural English'));
    expect(system, contains('Remove lesson introductions'));
    expect(system, contains('vocabulary lists'));
    expect(user, contains('Remove all non-story material'));
  });

  test('strict English practice translation fails without Ark key', () async {
    expect(
      () => PracticeTextService.translateToEnglishForPracticeStrict(
        content: '妈妈为孩子做了一个选择。',
      ),
      throwsA(isA<TextGenerationException>()),
    );
  });

  test('strict English practice translation uses text cache before remote',
      () async {
    _writeArkConfig();
    final prompt = PracticeTextService.englishPracticePromptForTest(
      '妈妈为孩子做了一个选择。',
    );
    final request = await TextGenerationService.cacheRequestForTest(
      turns: prompt.turns,
      purpose: 'translate_to_english_practice',
      maxTokens: 1600,
    );
    final cacheKey = await ApiCacheService.keyForJson('openai_text', request);
    await ApiCacheService.putText(
      cacheKey: cacheKey,
      kind: 'openai_text',
      purpose: 'translate_to_english_practice',
      request: request,
      textValue: 'A mother makes a choice for her child.',
    );
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('strict cached translation should not call remote Ark');
      },
    );

    final reply = await PracticeTextService.translateToEnglishForPracticeStrict(
      content: '妈妈为孩子做了一个选择。',
    );

    expect(reply.source, TextGenerationReplySource.cached);
    expect(reply.text, 'A mother makes a choice for her child.');
  });

  test('strict sentence translation batches subtitles in one Ark request',
      () async {
    _writeArkConfig();
    var remoteCalls = 0;
    Map<String, dynamic>? seenBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        remoteCalls += 1;
        seenBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'translations': [
                    {'index': 0, 'chinese': '汤姆发现了一个明亮的零食盒。'},
                    {'index': 1, 'chinese': '他把它分享给自己的队友。'},
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final batch = await PracticeTextService.translateSentencesToChineseStrict(
      sentencesByIndex: const {
        0: 'Tom finds a bright snack box.',
        1: 'He shares it with his team.',
      },
      articleId: 42,
    );

    final messages = seenBody?['messages'] as List;
    final user = (messages.last as Map)['content'] as String;
    expect(remoteCalls, 1);
    expect(seenBody?['response_format'], {'type': 'json_object'});
    expect(user, contains('"index":0'));
    expect(user, contains('"index":1'));
    expect(batch.source, TextGenerationReplySource.remote);
    expect(batch.translationsByIndex, {
      0: '汤姆发现了一个明亮的零食盒。',
      1: '他把它分享给自己的队友。',
    });
  });

  test('strict sentence translation fails when Ark omits a sentence', () async {
    _writeArkConfig();
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'translations': [
                    {'index': 0, 'chinese': '汤姆发现了一个明亮的零食盒。'},
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    expect(
      () => PracticeTextService.translateSentencesToChineseStrict(
        sentencesByIndex: const {
          0: 'Tom finds a bright snack box.',
          1: 'He shares it with his team.',
        },
        articleId: 42,
      ),
      throwsA(
        isA<TextGenerationException>().having(
          (error) => error.message,
          'message',
          contains('完整中文对照'),
        ),
      ),
    );
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
  AppConfig.setRuntimeConfigForTest(
    aiProvider: AppConfig.aiProviderVolcengine,
    volcArkApiKey: 'ark-practice-key-12345678901234567890',
    volcArkTextModel: 'doubao-seed-2-0-lite-260215',
  );
}
