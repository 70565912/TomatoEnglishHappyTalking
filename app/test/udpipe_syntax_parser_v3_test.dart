import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/udpipe_syntax_parser_v3.dart';

void main() {
  test('decodes UTF-16 offsets and remaps presegmented tokens exactly', () {
    const synthetic = 'The café smiled.\nEmoji 😀 stayed.';
    const source = 'The café smiled.\n\nEmoji 😀 stayed.';
    final firstStart = synthetic.indexOf('The');
    final cafeStart = synthetic.indexOf('café');
    final smiledStart = synthetic.indexOf('smiled.');
    final emojiStart = synthetic.indexOf('Emoji');
    final faceStart = synthetic.indexOf('😀');
    final stayedStart = synthetic.indexOf('stayed.');
    final raw = jsonEncode({
      'parserVersion': 'udpipe-1.4.0',
      'healthy': true,
      'issues': const <String>[],
      'sentences': [
        {
          'start': firstStart,
          'end': smiledStart + 'smiled.'.length,
          'parseCost': -0.42,
          'parseCostPerToken': -0.14,
          'tokens': [
            _token(1, 'The', firstStart, 3, 2, 'det'),
            _token(2, 'café', cafeStart, 4, 3, 'nsubj'),
            _token(3, 'smiled.', smiledStart, 7, 0, 'root'),
          ],
        },
        {
          'start': emojiStart,
          'end': stayedStart + 'stayed.'.length,
          'tokens': [
            _token(1, 'Emoji', emojiStart, 5, 3, 'nsubj'),
            _token(2, '😀', faceStart, 2, 3, 'discourse'),
            _token(3, 'stayed.', stayedStart, 7, 0, 'root'),
          ],
        },
      ],
    });

    final decoded = UdpipeSyntaxParserV3.decodeDocumentForTest(
      source: synthetic,
      raw: raw,
    );
    final remapped = UdpipeSyntaxParserV3.remapDocumentToSourceForTest(
      source: source,
      document: decoded,
    );

    expect(remapped.sentences, hasLength(2));
    expect(
      remapped.sentences
          .expand((sentence) => sentence.tokens)
          .map((token) => source.substring(token.start, token.end)),
      const ['The', 'café', 'smiled.', 'Emoji', '😀', 'stayed.'],
    );
    expect(
      remapped.sentences[1].tokens[1].end -
          remapped.sentences[1].tokens[1].start,
      2,
    );
    expect(remapped.sentences[1].start, source.indexOf('Emoji'));
    expect(remapped.sentences[1].end, source.length);
    expect(remapped.sentences.first.parseCost, -0.42);
    expect(remapped.sentences.first.parseCostPerToken, -0.14);
    expect(remapped.sentences.last.parseCost, isNull);
  });

  test('rejects a presegmented parse that skips source punctuation', () {
    const source = 'Mole looked up.';
    final raw = jsonEncode({
      'parserVersion': 'udpipe-1.4.0',
      'healthy': true,
      'issues': const <String>[],
      'sentences': [
        {
          'start': 0,
          'end': 14,
          'tokens': [
            _token(1, 'Mole', 0, 4, 2, 'nsubj'),
            _token(2, 'looked', 5, 6, 0, 'root'),
            _token(3, 'up', 12, 2, 2, 'compound:prt'),
          ],
        },
      ],
    });
    final decoded = UdpipeSyntaxParserV3.decodeDocumentForTest(
      source: source,
      raw: raw,
    );

    expect(
      () => UdpipeSyntaxParserV3.remapDocumentToSourceForTest(
        source: source,
        document: decoded,
      ),
      throwsFormatException,
    );
  });

  test('rejects overlapping native token offsets before boundary resolution',
      () {
    const source = 'Mole';
    final raw = jsonEncode({
      'parserVersion': 'udpipe-1.4.0',
      'healthy': true,
      'issues': const <String>[],
      'sentences': [
        {
          'start': 0,
          'end': source.length,
          'tokens': [
            _token(1, 'Mole', 0, 4, 0, 'root'),
            _token(2, 'ole', 1, 3, 1, 'obj'),
          ],
        },
      ],
    });

    expect(
      () => UdpipeSyntaxParserV3.decodeDocumentForTest(
        source: source,
        raw: raw,
      ),
      throwsFormatException,
    );
  });
}

Map<String, Object> _token(
  int id,
  String text,
  int start,
  int length,
  int head,
  String relation,
) =>
    {
      'id': id,
      'text': text,
      'sourceText': text,
      'start': start,
      'end': start + length,
      'upos': relation == 'root' ? 'VERB' : 'NOUN',
      'head': head,
      'deprel': relation,
    };
