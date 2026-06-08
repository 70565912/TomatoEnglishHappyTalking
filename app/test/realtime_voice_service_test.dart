import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/realtime_voice_service.dart';

void main() {
  test('chapter guide prompt reuses compact guide instead of full chapter text',
      () {
    final chapter = List.generate(
      80,
      (index) =>
          'Story section $index keeps a unique marker marker_$index for the full chapter conversation.',
    ).join('\n\n');
    const guide = 'Chapter summary: A learner discusses the story in order.\n'
        'Ordered coverage points:\n'
        '1. Beginning event.\n'
        '2. Main choice.\n'
        '3. Ending and meaning.';

    final prompt = RealtimeVoiceService.chapterGuidePromptForTest(
      articleTitle: 'Long Chapter',
      chapterGuide: guide,
    );

    expect(prompt, contains('Cached compact teaching guide'));
    expect(prompt, contains('Chapter summary'));
    expect(prompt, isNot(contains(chapter)));
    expect(prompt, isNot(contains('marker_0')));
    expect(prompt, isNot(contains('marker_39')));
    expect(prompt, isNot(contains('marker_79')));
    expect(prompt, isNot(contains('[middle of chapter]')));
    expect(prompt, isNot(contains('[end of chapter]')));
  });

  test('conversation system prompt requires completion metadata', () {
    final prompt = RealtimeVoiceService.conversationSystemTurn().content;

    expect(prompt, contains('TOMATO_CHAPTER_DONE'));
    expect(prompt, contains('TOMATO_ABILITY_LEVEL'));
    expect(prompt, contains('TOMATO_SUMMARY'));
  });
}
