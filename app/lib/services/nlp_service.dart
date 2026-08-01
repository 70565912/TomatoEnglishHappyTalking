import 'read_aloud_splitter_v2.dart';

/// Offline conservative entry used by native callers that cannot provide the
/// shared TypeScript splitter output. New Web/Node creation paths should pass
/// their v2 sentences explicitly and let the bridge validate them.
class NlpService {
  static List<String> splitSentences(String text) =>
      ReadAloudSplitterV2.splitSentences(text);
}
