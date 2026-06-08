import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/services/chat_chapter_guide_service.dart';
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

  test('prepares and caches a semantic guide from the complete chapter',
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
                'content':
                    'Chapter summary: A compact guide.\nOrdered coverage points:\n1. Beginning.\n2. Middle.\n3. Ending.\nCompletion rubric: discuss the whole chapter.',
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

    expect(first.text, contains('Chapter summary'));
    expect(second.text, first.text);
    expect(postedBodies, hasLength(1));
    final messages = postedBodies.single['messages'] as List;
    final systemMessage = messages.first as Map;
    final userMessage = messages.last as Map;
    expect(
      systemMessage['content'] as String,
      contains('Choose the number of Ordered coverage points'),
    );
    expect(
      userMessage['content'] as String,
      contains('Complete chapter text'),
    );
    expect(userMessage['content'] as String, contains(fullChapter));
    expect(userMessage['content'] as String, contains('marker_0'));
    expect(userMessage['content'] as String, contains('marker_79'));
    expect(
      userMessage['content'] as String,
      isNot(contains('Keep the same number')),
    );
  });

  test('local fallback guide is compact and covers the ending', () {
    final sentences = List.generate(
      30,
      (index) => 'Sentence $index describes story marker_$index.',
    );

    final guide = ChatChapterGuideService.buildLocalGuide(
      articleTitle: 'Fallback Chapter',
      articleContent: sentences.join(' '),
      sentences: sentences,
    );

    expect(guide, contains('Ordered coverage points'));
    expect(guide, contains('marker_0'));
    expect(guide, contains('marker_29'));
    expect(guide.length, lessThan(2400));
  });

  test('submits chapter guide with content-safety rules applied', () async {
    _writeArkConfig();
    Map<String, dynamic>? seenBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'choices': [
            {
              'message': {'content': 'Chapter summary: safe guide.'},
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
  final securityDir = Directory('security')..createSync();
  File('${securityDir.path}${Platform.pathSeparator}ark.txt').writeAsStringSync(
    'ARK_API_KEY=ark-chat-guide-key-12345678901234567890\n'
    'ARK_TEXT_MODEL=doubao-seed-2-0-lite-260215\n',
  );
}
