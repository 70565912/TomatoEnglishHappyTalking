import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/orthographic_sentence_boundary_v3.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  group('OrthographicSentenceBoundaryV3', () {
    test('does not trust a spurious UDPipe sentence boundary', () {
      const source = 'The Mole worked. Rat waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['The'],
          ['Mole', 'worked', '.'],
          ['Rat', 'waited', '.'],
        ],
      );

      expect(
        _texts(
            source,
            OrthographicSentenceBoundaryV3.resolve(
              source: source,
              document: document,
            )),
        const ['The Mole worked.', 'Rat waited.'],
      );
    });

    test('does not split abbreviations or decimals represented as words', () {
      const source = 'Mr. Toad paid 3.5 shillings. Rat waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['Mr.', 'Toad', 'paid', '3.5', 'shillings', '.'],
          ['Rat', 'waited', '.'],
        ],
      );

      expect(
        _texts(
            source,
            OrthographicSentenceBoundaryV3.resolve(
              source: source,
              document: document,
            )),
        const ['Mr. Toad paid 3.5 shillings.', 'Rat waited.'],
      );
    });

    test('locks a standalone source terminal even when POS tagging is wrong',
        () {
      const source = 'One sentence. Another follows.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['One', 'sentence', '.'],
          ['Another', 'follows', '.'],
        ],
        relations: const {
          0: {
            3: (head: 2, relation: 'dep', upos: 'X'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
          ),
        ),
        const ['One sentence.', 'Another follows.'],
      );
    });

    test('keeps a closing quote when its POS tagging is wrong', () {
      const source = '"What lies there?" asked Rat. Mole waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'What', 'lies', 'there', '?', '"', 'asked', 'Rat', '.'],
          ['Mole', 'waited', '.'],
        ],
        relations: const {
          0: {
            6: (head: 7, relation: 'dep', upos: 'X'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"What lies there?"', 'asked Rat.', 'Mole waited.'],
      );
    });

    test('keeps closing brackets with the sentence terminal', () {
      const source = 'Mole answered (very softly.) Rat listened.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['Mole', 'answered', '(', 'very', 'softly', '.', ')'],
          ['Rat', 'listened', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
          ),
        ),
        const ['Mole answered (very softly.)', 'Rat listened.'],
      );
    });

    test('keeps a quote attribution only after dependency verification', () {
      const source = '"Look!" Rat asked. Then Mole smiled.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Look', '!', '"', 'Rat', 'asked', '.'],
          ['Then', 'Mole', 'smiled', '.'],
        ],
        relations: const {
          0: {
            2: (head: 6, relation: 'ccomp', upos: 'VERB'),
            5: (head: 6, relation: 'nsubj', upos: 'PROPN'),
            6: (head: 0, relation: 'root', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
            source,
            OrthographicSentenceBoundaryV3.resolve(
              source: source,
              document: document,
              requireVerifiedQuoteAttribution: true,
            )),
        const ['"Look!" Rat asked.', 'Then Mole smiled.'],
      );
    });

    test('keeps a predicate-first attribution without a parsed subject', () {
      const source = '"What?" asked the Mole anxiously. Rat waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'What', '?', '"', 'asked', 'the', 'Mole', 'anxiously', '.'],
          ['Rat', 'waited', '.'],
        ],
        relations: const {
          0: {
            2: (head: 5, relation: 'parataxis', upos: 'PRON'),
            5: (head: 0, relation: 'root', upos: 'VERB'),
            7: (head: 5, relation: 'xcomp', upos: 'PROPN'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"What?" asked the Mole anxiously.', 'Rat waited.'],
      );
    });

    test('locks adjacent quoted sentences instead of attaching the next one',
        () {
      const source = '"Yes!" "No," Rat replied.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Yes', '!', '"'],
          ['"', 'No', ',', '"', 'Rat', 'replied', '.'],
        ],
        relations: const {
          1: {
            2: (head: 6, relation: 'ccomp', upos: 'INTJ'),
            5: (head: 6, relation: 'nsubj', upos: 'PROPN'),
            6: (head: 0, relation: 'root', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"Yes!"', '"No," Rat replied.'],
      );
    });

    test('does not absorb the opening quote of the next sentence', () {
      const source =
          'The sooner we make a start the better." "But what about Toad?" '
          'asked the Mole anxiously.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            'The',
            'sooner',
            'we',
            'make',
            'a',
            'start',
            'the',
            'better',
            '.',
            '"'
          ],
          [
            '"',
            'But',
            'what',
            'about',
            'Toad',
            '?',
            '"',
            'asked',
            'the',
            'Mole',
            'anxiously',
            '.'
          ],
        ],
        relations: const {
          1: {
            2: (head: 8, relation: 'advmod', upos: 'CCONJ'),
            5: (head: 8, relation: 'ccomp', upos: 'VERB'),
            8: (head: 0, relation: 'root', upos: 'VERB'),
            10: (head: 8, relation: 'nsubj', upos: 'NOUN'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const [
          'The sooner we make a start the better."',
          '"But what about Toad?" asked the Mole anxiously.',
        ],
      );
    });

    test('accepts a postposed speaker mislabelled as object by the parser', () {
      const source = '"Hold up!" said a rabbit. Mole waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Hold', 'up', '!', '"', 'said', 'a', 'rabbit', '.'],
          ['Mole', 'waited', '.'],
        ],
        relations: const {
          0: {
            2: (head: 6, relation: 'ccomp', upos: 'VERB'),
            6: (head: 0, relation: 'root', upos: 'VERB'),
            8: (head: 6, relation: 'obj', upos: 'NOUN'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"Hold up!" said a rabbit.', 'Mole waited.'],
      );
    });

    test('keeps a quote joined to a following coordinated clause', () {
      const source = '"Go!" and Mole waited. Sunshine returned.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Go', '!', '"', 'and', 'Mole', 'waited', '.'],
          ['Sunshine', 'returned', '.'],
        ],
        relations: const {
          0: {
            2: (head: 0, relation: 'root', upos: 'VERB'),
            5: (head: 7, relation: 'cc', upos: 'CCONJ'),
            6: (head: 7, relation: 'nsubj', upos: 'NOUN'),
            7: (head: 2, relation: 'conj', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"Go!" and Mole waited.', 'Sunshine returned.'],
      );
    });

    test('keeps sibling quote and clause conjuncts together', () {
      const source = '"Blow!" and "Hang on!" and Mole waited. Rat left.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            '"',
            'Blow',
            '!',
            '"',
            'and',
            '"',
            'Hang',
            'on',
            '!',
            '"',
            'and',
            'Mole',
            'waited',
            '.',
          ],
          ['Rat', 'left', '.'],
        ],
        relations: const {
          0: {
            2: (head: 0, relation: 'root', upos: 'VERB'),
            5: (head: 7, relation: 'cc', upos: 'CCONJ'),
            7: (head: 2, relation: 'conj', upos: 'VERB'),
            11: (head: 13, relation: 'cc', upos: 'CCONJ'),
            12: (head: 13, relation: 'nsubj', upos: 'NOUN'),
            13: (head: 2, relation: 'conj', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const [
          '"Blow!" and "Hang on!" and Mole waited.',
          'Rat left.',
        ],
      );
    });

    test('does not treat capitalized And as an internal coordination', () {
      const source = '"Stop!" And Mole waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Stop', '!', '"', 'And', 'Mole', 'waited', '.'],
        ],
        relations: const {
          0: {
            2: (head: 0, relation: 'root', upos: 'VERB'),
            5: (head: 7, relation: 'cc', upos: 'CCONJ'),
            6: (head: 7, relation: 'nsubj', upos: 'NOUN'),
            7: (head: 2, relation: 'conj', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"Stop!"', 'And Mole waited.'],
      );
    });

    test('keeps a quoted command followed by a determiner-led attribution', () {
      const source = '"Get out!" the Mole heard him mutter. Rat left.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            '"',
            'Get',
            'out',
            '!',
            '"',
            'the',
            'Mole',
            'heard',
            'him',
            'mutter',
            '.',
          ],
          ['Rat', 'left', '.'],
        ],
        relations: const {
          0: {
            2: (head: 0, relation: 'root', upos: 'VERB'),
            7: (head: 2, relation: 'obj', upos: 'NOUN'),
            8: (head: 2, relation: 'parataxis', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const [
          '"Get out!" the Mole heard him mutter.',
          'Rat left.',
        ],
      );
    });

    test('keeps an embedded quote inside its containing dependency tree', () {
      const source = 'He whispered "Stop!" he could only wait. Rat left.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            'He',
            'whispered',
            '"',
            'Stop',
            '!',
            '"',
            'he',
            'could',
            'only',
            'wait',
            '.',
          ],
          ['Rat', 'left', '.'],
        ],
        relations: const {
          0: {
            1: (head: 2, relation: 'nsubj', upos: 'PRON'),
            2: (head: 10, relation: 'advcl', upos: 'VERB'),
            4: (head: 2, relation: 'discourse', upos: 'INTJ'),
            7: (head: 10, relation: 'nsubj', upos: 'PRON'),
            8: (head: 10, relation: 'aux', upos: 'AUX'),
            10: (head: 0, relation: 'root', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['He whispered "Stop!" he could only wait.', 'Rat left.'],
      );
    });

    test('keeps a deeply embedded quote linked to the following main clause',
        () {
      const source =
          'And instead of having an uneasy conscience pricking him and whispering "whitewash!" he somehow could only feel how jolly it was.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            'And',
            'instead',
            'of',
            'having',
            'an',
            'uneasy',
            'conscience',
            'pricking',
            'him',
            'and',
            'whispering',
            '"',
            'whitewash',
            '!',
            '"',
            'he',
            'somehow',
            'could',
            'only',
            'feel',
            'how',
            'jolly',
            'it',
            'was',
            '.',
          ],
        ],
        relations: const {
          0: {
            4: (head: 20, relation: 'advcl', upos: 'VERB'),
            8: (head: 4, relation: 'xcomp', upos: 'VERB'),
            11: (head: 8, relation: 'conj', upos: 'VERB'),
            13: (head: 11, relation: 'discourse', upos: 'INTJ'),
            16: (head: 20, relation: 'nsubj', upos: 'PRON'),
            18: (head: 20, relation: 'aux', upos: 'AUX'),
            20: (head: 0, relation: 'root', upos: 'VERB'),
            24: (head: 20, relation: 'ccomp', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        [source],
      );
    });

    test('rejects an attribution-shaped clause without a quote dependency', () {
      const source = '"Go!" Alice ran. Sunshine returned.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Go', '!', '"', 'Alice', 'ran', '.'],
          ['Sunshine', 'returned', '.'],
        ],
        relations: const {
          0: {
            2: (head: 0, relation: 'root', upos: 'VERB'),
            5: (head: 6, relation: 'nsubj', upos: 'PROPN'),
            6: (head: 2, relation: 'advcl', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
            source,
            OrthographicSentenceBoundaryV3.resolve(
              source: source,
              document: document,
              requireVerifiedQuoteAttribution: true,
            )),
        const ['"Go!"', 'Alice ran.', 'Sunshine returned.'],
      );
    });

    test('splits multiple sentences inside one pair of quotation marks', () {
      const source = '"Look here! If you are free, come along?" Rat asked.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Look', 'here', '!'],
          ['If', 'you', 'are', 'free', ',', 'come', 'along', '?', '"'],
          ['Rat', 'asked', '.'],
        ],
        relations: const {
          2: {
            1: (head: 2, relation: 'nsubj', upos: 'PROPN'),
            2: (head: 0, relation: 'root', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
            source,
            OrthographicSentenceBoundaryV3.resolve(
              source: source,
              document: document,
            )),
        const ['"Look here!', 'If you are free, come along?" Rat asked.'],
      );
    });

    test('keeps a lowercase non-predicate continuation after a quoted sentence',
        () {
      const source = '"Up we go!" till at last, pop! His snout appeared.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            '"',
            'Up',
            'we',
            'go',
            '!',
            '"',
            'till',
            'at',
            'last',
            ',',
            'pop',
            '!',
          ],
          ['His', 'snout', 'appeared', '.'],
        ],
        relations: const {
          0: {
            4: (head: 0, relation: 'root', upos: 'VERB'),
            7: (head: 9, relation: 'case', upos: 'ADP'),
            9: (head: 11, relation: 'obl', upos: 'ADJ'),
            11: (head: 0, relation: 'root', upos: 'NOUN'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"Up we go!" till at last, pop!', 'His snout appeared.'],
      );
    });

    test('keeps lowercase continuation after emphatic punctuation', () {
      const source =
          'yes!-no!-yes! certainly a narrow face appeared. Rat waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            'yes',
            '!',
            '-',
            'no',
            '!',
            '-',
            'yes',
            '!',
            'certainly',
            'a',
            'narrow',
            'face',
            'appeared',
            '.',
          ],
          ['Rat', 'waited', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
          ),
        ),
        const [
          'yes!-no!-yes! certainly a narrow face appeared.',
          'Rat waited.',
        ],
      );
    });

    test('keeps lowercase continuation inside an open quotation', () {
      const source = '"O, pooh! boating!" interrupted the Toad. Rat waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          [
            '"',
            'O',
            ',',
            'pooh',
            '!',
            'boating',
            '!',
            '"',
            'interrupted',
            'the',
            'Toad',
            '.',
          ],
          ['Rat', 'waited', '.'],
        ],
        relations: const {
          0: {
            6: (head: 9, relation: 'ccomp', upos: 'NOUN'),
            9: (head: 0, relation: 'root', upos: 'VERB'),
            11: (head: 9, relation: 'obj', upos: 'PROPN'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"O, pooh! boating!" interrupted the Toad.', 'Rat waited.'],
      );
    });

    test('splits a quoted question from following uppercase narration', () {
      const source =
          '"Ratty! Is that really you?" The Rat crept inside. Mole waited.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'Ratty', '!'],
          ['Is', 'that', 'really', 'you', '?', '"'],
          ['The', 'Rat', 'crept', 'inside', '.'],
          ['Mole', 'waited', '.'],
        ],
        relations: const {
          2: {
            1: (head: 3, relation: 'det', upos: 'DET'),
            2: (head: 3, relation: 'nsubj', upos: 'PROPN'),
            3: (head: 0, relation: 'root', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const [
          '"Ratty!',
          'Is that really you?"',
          'The Rat crept inside.',
          'Mole waited.',
        ],
      );
    });

    test('treats spaced dot leaders as one terminal sequence', () {
      const source = 'SONG. . . . BY TOAD. Words by the. . . COMPOSER.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['SONG', '.', '.', '.', '.', 'BY', 'TOAD', '.'],
          ['Words', 'by', 'the', '.', '.', '.', 'COMPOSER', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
          ),
        ),
        const [
          'SONG. . . .',
          'BY TOAD.',
          'Words by the. . .',
          'COMPOSER.',
        ],
      );
    });

    test('keeps a trailing punctuation emoticon with its sentence', () {
      const source = 'Best result so far! :) Another followed.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['Best', 'result', 'so', 'far', '!', ':', ')'],
          ['Another', 'followed', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
          ),
        ),
        const ['Best result so far! :)', 'Another followed.'],
      );
    });

    test(
        'keeps continuation after the final sentence in a multi-sentence quote',
        () {
      const source =
          'She muttered, "Keep moving! Keep moving!" till at last, pop! The door opened.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['She', 'muttered', ',', '"', 'Keep', 'moving', '!'],
          [
            'Keep',
            'moving',
            '!',
            '"',
            'till',
            'at',
            'last',
            ',',
            'pop',
            '!',
          ],
          ['The', 'door', 'opened', '.'],
        ],
        relations: const {
          1: {
            2: (head: 0, relation: 'root', upos: 'VERB'),
            5: (head: 9, relation: 'nsubj', upos: 'NOUN'),
            9: (head: 2, relation: 'advcl', upos: 'VERB'),
          },
        },
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const [
          'She muttered, "Keep moving!',
          'Keep moving!" till at last, pop!',
          'The door opened.',
        ],
      );
    });

    test('treats paragraph breaks as hard boundaries without a word list', () {
      const source =
          'A heading without punctuation\n\nA new paragraph follows.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['A', 'heading', 'without', 'punctuation'],
          ['A', 'new', 'paragraph', 'follows', '.'],
        ],
      );

      expect(
        _texts(
            source,
            OrthographicSentenceBoundaryV3.resolve(
              source: source,
              document: document,
            )),
        const [
          'A heading without punctuation',
          'A new paragraph follows.',
        ],
      );
    });

    test('does not carry an unmatched quote into the next paragraph', () {
      const source = '"An unclosed quotation.\n\n"What?" asked Rat.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['"', 'An', 'unclosed', 'quotation', '.'],
          ['"', 'What', '?', '"'],
          ['asked', 'Rat', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const ['"An unclosed quotation.', '"What?"', 'asked Rat.'],
      );
    });

    test('uses source context for fragmentary straight closing quotes', () {
      const source =
          'They had better not," he added. "Why should they?" asked Mole.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['They', 'had', 'better', 'not', ',', '"', 'he', 'added', '.'],
          ['"', 'Why', 'should', 'they', '?', '"'],
          ['asked', 'Mole', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
            requireVerifiedQuoteAttribution: true,
          ),
        ),
        const [
          'They had better not," he added.',
          '"Why should they?"',
          'asked Mole.',
        ],
      );
    });

    test('attaches an adjacent straight closing quote without an opener', () {
      const source = 'He ended there." Next began.';
      final document = _documentFromRawGroups(
        source,
        const [
          ['He', 'ended', 'there', '.', '"'],
          ['Next', 'began', '.'],
        ],
      );

      expect(
        _texts(
          source,
          OrthographicSentenceBoundaryV3.resolve(
            source: source,
            document: document,
          ),
        ),
        const ['He ended there."', 'Next began.'],
      );
    });
  });
}

List<String> _texts(
  String source,
  List<OrthographicSentenceRangeV3> ranges,
) =>
    ranges.map((range) => range.textOf(source)).toList(growable: false);

DependencyDocumentV3 _documentFromRawGroups(
  String source,
  List<List<String>> groups, {
  Map<int, Map<int, ({int head, String relation, String upos})>> relations =
      const {},
}) {
  var cursor = 0;
  final sentences = <DependencySentenceV3>[];
  for (var sentenceIndex = 0;
      sentenceIndex < groups.length;
      sentenceIndex += 1) {
    final tokens = <DependencyTokenV3>[];
    for (var index = 0; index < groups[sentenceIndex].length; index += 1) {
      final value = groups[sentenceIndex][index];
      final start = source.indexOf(value, cursor);
      if (start < 0) throw StateError('Token not found after $cursor: $value');
      final end = start + value.length;
      final id = index + 1;
      final relation = relations[sentenceIndex]?[id];
      tokens.add(
        DependencyTokenV3(
          id: id,
          text: value,
          sourceText: value,
          start: start,
          end: end,
          upos: relation?.upos ?? (_isPunctuation(value) ? 'PUNCT' : 'NOUN'),
          head: relation?.head ?? 0,
          deprel: relation?.relation ?? 'root',
        ),
      );
      cursor = end;
    }
    sentences.add(
      DependencySentenceV3(
        start: tokens.first.start,
        end: tokens.last.end,
        tokens: tokens,
      ),
    );
  }
  return DependencyDocumentV3(
    parserVersion: 'test-parser',
    modelSha256: 'test-model',
    sentences: sentences,
    healthy: true,
  );
}

bool _isPunctuation(String value) =>
    RegExp(r'^[.!?,;:"()\[\]{}\-\u2013\u2014\u201c\u201d\u2018\u2019]+$')
        .hasMatch(value);
