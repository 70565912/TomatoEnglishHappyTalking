import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/core/practice/listening_sentence_visibility.dart';

void main() {
  group('listening sentence visibility', () {
    test('detects hidden sentences', () {
      expect(isHiddenListeningSentence(''), isTrue);
      expect(isHiddenListeningSentence('   '), isTrue);
      expect(isHiddenListeningSentence('Hello.'), isFalse);
    });

    test('counts visible sentences with empty slots preserved', () {
      const sentences = ['A', '', 'C', ''];
      expect(visibleSentenceCount(sentences), 2);
      expect(visibleSentenceIndexes(sentences).toList(), [0, 2]);
    });

    test('navigates visible indexes', () {
      const sentences = ['A', '', '', 'D'];
      expect(firstVisibleSentenceIndex(sentences), 0);
      expect(nextVisibleSentenceIndex(sentences, 0), 3);
      expect(nextVisibleSentenceIndex(sentences, 1), 3);
      expect(nextVisibleSentenceIndex(sentences, 3), isNull);
      expect(previousVisibleSentenceIndex(sentences, 3), 0);
    });

    test('rebuilds article content without hidden slots', () {
      const sentences = ['First.', '', 'Third.'];
      expect(
        rebuildArticleContentFromSentences(sentences),
        'First. Third.',
      );
    });
  });
}
