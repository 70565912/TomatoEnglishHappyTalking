/// Helpers for listening sentences stored with empty-string hidden slots.
library;

bool isHiddenListeningSentence(String sentence) => sentence.trim().isEmpty;

int visibleSentenceCount(List<String> sentences) {
  var count = 0;
  for (final sentence in sentences) {
    if (!isHiddenListeningSentence(sentence)) {
      count += 1;
    }
  }
  return count;
}

Iterable<int> visibleSentenceIndexes(List<String> sentences) sync* {
  for (var index = 0; index < sentences.length; index += 1) {
    if (!isHiddenListeningSentence(sentences[index])) {
      yield index;
    }
  }
}

int? firstVisibleSentenceIndex(List<String> sentences) {
  for (var index = 0; index < sentences.length; index += 1) {
    if (!isHiddenListeningSentence(sentences[index])) {
      return index;
    }
  }
  return null;
}

int? nextVisibleSentenceIndex(List<String> sentences, int fromIndex) {
  for (var index = fromIndex + 1; index < sentences.length; index += 1) {
    if (!isHiddenListeningSentence(sentences[index])) {
      return index;
    }
  }
  return null;
}

int? previousVisibleSentenceIndex(List<String> sentences, int fromIndex) {
  for (var index = fromIndex - 1; index >= 0; index -= 1) {
    if (!isHiddenListeningSentence(sentences[index])) {
      return index;
    }
  }
  return null;
}

List<String> visibleSentences(List<String> sentences) {
  return sentences
      .where((sentence) => !isHiddenListeningSentence(sentence))
      .toList(growable: false);
}

String rebuildArticleContentFromSentences(List<String> sentences) {
  return visibleSentences(sentences).join(' ');
}
