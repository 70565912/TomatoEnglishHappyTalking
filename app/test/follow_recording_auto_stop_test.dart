import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/features/follow_read/providers/follow_read_provider.dart';

void main() {
  group('follow recording auto stop detection', () {
    test('accepts a completed sentence with a matching ending', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText:
              '"Well, it must be removed," said the King very decidedly,',
          recognizedText:
              'Well it must be removed said the king very decidedly',
        ),
        isTrue,
      );
    });

    test('does not stop when only the final words were spoken', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText:
              '"Well, it must be removed," said the King very decidedly,',
          recognizedText: 'king very decidedly',
        ),
        isFalse,
      );
    });

    test('does not stop when the sentence ending does not match', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText:
              '"Well, it must be removed," said the King very decidedly,',
          recognizedText: 'Well it must be removed said the king very slowly',
        ),
        isFalse,
      );
    });

    test('allows common contraction expansion near the ending', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText: "I'll fetch the executioner myself.",
          recognizedText: 'I will fetch the executioner myself',
        ),
        isTrue,
      );
    });

    test('allows small recognition differences in the final word', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText: 'Tom finds a bright snack box.',
          recognizedText: 'Tom finds a bright snack bok',
        ),
        isTrue,
      );
    });

    test('allows homophone and omitted article near the ending', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText: 'and he called to the Queen,',
          recognizedText: 'And he called two queen.',
        ),
        isTrue,
      );
    });

    test('does not stop for the same ending phrase without enough coverage',
        () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText: 'and he called to the Queen,',
          recognizedText: 'two queen',
        ),
        isFalse,
      );
    });

    test('keeps recording while only the prefix has been recognized', () {
      expect(
        FollowRead.shouldAutoStopRecordingForTest(
          referenceText:
              '"Well, it must be removed," said the King very decidedly,',
          recognizedText: 'Well it must be removed said the king',
        ),
        isFalse,
      );
    });
  });
}
