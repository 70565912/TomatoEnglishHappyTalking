import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';
import 'package:tomato_english_happy_talking/services/practice_text_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';

void main() {
  final article = Article(
    title: 'Untitled Chapter',
    content: 'Alice looked at the table. The Hatter offered wine.',
    sentences: const [
      'Alice looked at the table.',
      'The Hatter offered wine.',
    ],
    createdAt: DateTime.utc(2026, 7, 12),
  );

  test('chapter plan JSON shape includes title only when requested', () {
    final withTitle = PictureBookService.chapterPlanJsonShapeForTest(
      includeTitle: true,
    );
    final withoutTitle = PictureBookService.chapterPlanJsonShapeForTest(
      includeTitle: false,
    );

    expect(withTitle, contains('"title":"..."'));
    expect(withTitle, contains('"chapterDescription":"...'));
    expect(withoutTitle, isNot(contains('"title":"')));
    expect(withoutTitle, contains('"chapterDescription":"...'));
  });

  test('chapter plan prompt asks for title only when includeTitle is true', () {
    final withTitle = PictureBookService.chapterPlanPromptTurnsForTest(
      article: article,
      bookDescription: 'A wonderland picture book.',
      relevantCharacters: const [],
      includeTitle: true,
    );
    final withoutTitle = PictureBookService.chapterPlanPromptTurnsForTest(
      article: article,
      bookDescription: 'A wonderland picture book.',
      relevantCharacters: const [],
      includeTitle: false,
    );

    expect(withTitle.last.content, contains('"title":"..."'));
    expect(
      withTitle.last.content,
      contains('Also include top-level "title"'),
    );
    expect(withoutTitle.last.content, isNot(contains('"title":"')));
    expect(
      withoutTitle.last.content,
      isNot(contains('Also include top-level "title"')),
    );
  });

  test('parseGeneratedChapterPlan cleans optional title from JSON', () {
    final parsed = PictureBookService.parseGeneratedChapterPlan(
      {
        'planKind': 'picture_book_chapter_scene_plan_v2',
        'title': 'title: mothers tea party!!',
        'chapterDescription':
            'Alice sits at a tea table while the Hatter offers wine with no bottle in sight.',
        'scenes': [
          {
            'pageIndex': 0,
            'sentenceStartIndex': 0,
            'sentenceEndIndex': 0,
            'sceneDescription': 'Alice looks across the empty tea table.',
          },
          {
            'pageIndex': 1,
            'sentenceStartIndex': 1,
            'sentenceEndIndex': 1,
            'sceneDescription':
                'The Hatter gestures toward wine though none sits on the table.',
          },
        ],
        'newCharacters': const [],
      },
      sentenceCount: article.sentences.length,
      source: TextGenerationReplySource.remote,
      requireTitle: true,
    );

    expect(parsed, isNotNull);
    expect(parsed!.title, 'Mother\'s Tea Party');
    expect(parsed.plan.chapterDescription, isNotEmpty);
    expect(parsed.plan.scenes, hasLength(2));
  });

  test('parseGeneratedChapterPlan rejects more than twelve scenes', () {
    final parsed = PictureBookService.parseGeneratedChapterPlan(
      {
        'planKind': 'picture_book_chapter_scene_plan_v2',
        'chapterDescription': 'A long chapter with too many scene rows.',
        'scenes': [
          for (var index = 0; index < 13; index += 1)
            {
              'pageIndex': index,
              'sentenceStartIndex': index,
              'sentenceEndIndex': index,
              'sceneDescription': 'Visible scene ${index + 1}.',
            },
        ],
        'newCharacters': const [],
      },
      sentenceCount: 13,
      source: TextGenerationReplySource.remote,
    );

    expect(parsed, isNull);
  });

  test('parseGeneratedChapterPlan rejects coverage gaps', () {
    final parsed = PictureBookService.parseGeneratedChapterPlan(
      {
        'planKind': 'picture_book_chapter_scene_plan_v2',
        'chapterDescription': 'A chapter with an invalid missing slot.',
        'scenes': const [
          {
            'pageIndex': 0,
            'sentenceStartIndex': 0,
            'sentenceEndIndex': 0,
            'sceneDescription': 'Alice enters the room.',
          },
          {
            'pageIndex': 1,
            'sentenceStartIndex': 2,
            'sentenceEndIndex': 2,
            'sceneDescription': 'Alice leaves the room.',
          },
        ],
        'newCharacters': const [],
      },
      sentenceCount: 3,
      source: TextGenerationReplySource.remote,
    );

    expect(parsed, isNull);
  });

  test('cleanArticleTitle matches practice title rules', () {
    expect(
      PracticeTextService.cleanArticleTitle('the queens croquet ground.'),
      'The Queens Croquet Ground',
    );
  });
}
