import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/nlp_service.dart';

void main() {
  group('NlpService.splitSentences', () {
    test('returns empty list for empty text', () {
      expect(NlpService.splitSentences('   \n\t  '), isEmpty);
    });

    test('keeps ordinary short sentences', () {
      expect(
        NlpService.splitSentences(
          'Tom finds a bright snack box. He shares it with his team.',
        ),
        [
          'Tom finds a bright snack box.',
          'He shares it with his team.',
        ],
      );
    });

    test('splits long natural sentences into read-aloud chunks', () {
      final chunks = NlpService.splitSentences(
        'Tom walks into the bright library, finds a tiny blue robot beside the big window, and asks it to help him read a funny story before lunch, because his little sister wants to hear every silly voice before bedtime.',
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.split(RegExp(r'\s+')).length <= 32),
          isTrue);
    });

    test('keeps moderate comma sentences in readable phrase groups', () {
      final chunks = NlpService.splitSentences(
        'The rocket jumps over the moon, then turns around slowly, because Tom wants everyone to see the shiny snack box before the team goes home.',
      );

      expect(chunks.join(' '),
          'The rocket jumps over the moon, then turns around slowly, because Tom wants everyone to see the shiny snack box before the team goes home.');
      expect(_hasDanglingBreak(chunks), isFalse);
      expect(_maxWords(chunks), lessThanOrEqualTo(32));
    });

    test('keeps hyphenated words joined for read-aloud text', () {
      final chunks = NlpService.splitSentences(
        'The well - known mother - in - law smiles at the child.',
      );
      final joined = chunks.join(' ');

      expect(joined, contains('well-known'));
      expect(joined, contains('mother-in-law'));
      expect(joined, isNot(contains('well - known')));
    });

    test('does not split common abbreviations into standalone chunks', () {
      final chunks = NlpService.splitSentences(
        'Dr. Smith met Tom after school. They read a book together.',
      );

      expect(chunks, isNot(contains('Dr.')));
      expect(chunks.first, startsWith('Dr. Smith'));
      expect(chunks.length, 2);
    });

    test('skips imported episode headings before read-aloud text', () {
      final chunks = NlpService.splitSentences(
        'E25\n\n'
        '爱丽丝梦游仙境（原著领读版）- E61\n\n'
        'Alice\'s Adventures in Wonderland - Episod 61\n'
        '"They were learning to draw," the Dormouse went on, '
        'yawning and rubbing its eyes, for it was getting very sleepy.',
      );

      expect(chunks.first, startsWith('"They were learning to draw,"'));
      expect(chunks.join(' '), isNot(contains('爱丽丝')));
      expect(chunks.join(' '), isNot(contains('E25')));
      expect(chunks.join(' '), isNot(contains('Episod 61')));
    });

    test('removes repeated imported headings inside long pasted text', () {
      final chunks = NlpService.splitSentences(
        'Alice was silent.\n\n'
        '爱丽丝梦游仙境（原著领读版）- E62\n\n'
        'Alice\'s Adventures in Wonderland - Episod 62\n\n'
        'Chapter Eight\n'
        'The Queen\'s Croquet - Ground\n\n'
        'A large rose-tree stood near the entrance of the garden.',
      );

      expect(chunks, contains('Alice was silent.'));
      expect(chunks.last, startsWith('A large rose-tree stood'));
      expect(chunks.join(' '), isNot(contains('Croquet - Ground')));
      expect(chunks.join(' '), isNot(contains('Episod 62')));
    });

    test('splits Alice Mad Tea-Party natural sentences into phrase chunks', () {
      final chunks = NlpService.splitSentences(
        'A Mad Tea-Party\n'
        'There was a table set out under a tree in front of the house, '
        'and the March Hare and the Hatter were having tea at it: '
        'a Dormouse was sitting between them, fast asleep, and '
        'the other two were using it as a cushion, resting their elbows on it, '
        'and talking over its head.\n'
        '"Very uncomfortable for the Dormouse," thought Alice: '
        '"only as it\'s asleep, I suppose it doesn\'t mind."\n'
        'The table was a large one, but the three were all crowded together at '
        'one corner of it: "No room! No room!" they cried out when they saw '
        'Alice coming.',
      );

      expect(chunks.length, greaterThanOrEqualTo(4));
      expect(chunks.join(' '), contains('a Dormouse was sitting between them'));
      expect(chunks.join(' '), contains('"No room! No room!"'));
      expect(_hasDanglingBreak(chunks), isFalse);
      expect(_maxWords(chunks), lessThanOrEqualTo(32));
      expect(chunks.join(' '), isNot(contains('A Mad Tea-Party')));
    });

    test('keeps selected real database chapters readable', () {
      final samples = {
        'E10 - The Caucus Race': _e10CaucusRace,
        'E11 - The Mouse\'s Sad Tale': _e11MouseSadTale,
        'E12 - The White Rabbit\'s Search': _e12WhiteRabbitSearch,
      };

      for (final sample in samples.entries) {
        final chunks = NlpService.splitSentences(sample.value);

        expect(chunks, isNotEmpty, reason: sample.key);
        expect(_maxWords(chunks), lessThanOrEqualTo(32), reason: sample.key);
        expect(_hasOneWordFragment(chunks), isFalse, reason: sample.key);
        expect(_hasDanglingBreak(chunks), isFalse, reason: sample.key);
      }

      final e10 = NlpService.splitSentences(_e10CaucusRace);
      expect(
        _containsSingleChunkWithAll(
          e10,
          ['energetic remedies', 'Speak English'],
        ),
        isFalse,
      );
      expect(e10.join('\n'), isNot(contains('when the race\nwas over')));

      final e11 = NlpService.splitSentences(_e11MouseSadTale);
      expect(
        _containsSingleChunkWithAll(
          e11,
          ['condemn you to death', 'You are not attending'],
        ),
        isFalse,
      );
      expect(e11, isNot(contains('low-spirited.')));

      final e12 = NlpService.splitSentences(_e12WhiteRabbitSearch);
      expect(e12.join(' '), isNot(contains('The Rabbit Sends')));
      expect(e12.join('\n'), isNot(contains("She'll get me\nexecuted")));
      expect(e12.join('\n'), isNot(contains('fetch me\na pair')));
      expect(e12.any((chunk) => chunk.startsWith('RABBIT,')), isFalse);
      expect(
        e12.any(
          (chunk) =>
              chunk.contains('Where can I have dropped them, I wonder!"'),
        ),
        isTrue,
      );
    });

    test('splits direct speech when a quote follows a phrase without colon',
        () {
      final chunks = NlpService.splitSentences(
        'The table was a large one, but the three were all crowded together at '
        'one corner of it "No room! No room!" they cried out when they saw '
        'Alice coming.',
      );

      expect(chunks.join(' '), contains('"No room! No room!"'));
      expect(chunks.join(' '), contains('they cried out when they saw Alice'));
      expect(_hasDanglingBreak(chunks), isFalse);
      expect(_maxWords(chunks), lessThanOrEqualTo(32));
    });

    test('keeps direct command together after an em dash', () {
      final chunks = NlpService.splitSentences(
        '"The Queen will hear you! You see she came rather late, and the Queen said—" '
        '"Get to your places!" shouted the Queen in a voice of thunder, and people began running about in all directions.',
      );

      expect(chunks, isNot(contains('"Get')));
      expect(
        chunks.any(
          (chunk) => chunk.startsWith(
            '"Get to your places!" shouted the Queen in a voice of thunder,',
          ),
        ),
        isTrue,
      );
    });
  });
}

int _maxWords(List<String> chunks) => chunks
    .map(_wordCount)
    .fold<int>(0, (max, count) => count > max ? count : max);

int _wordCount(String text) =>
    text.split(RegExp(r'\s+')).where((token) => token.trim().isNotEmpty).length;

bool _hasOneWordFragment(List<String> chunks) =>
    chunks.any((chunk) => _wordCount(chunk) == 1);

bool _hasDanglingBreak(List<String> chunks) {
  final danglingEnd = RegExp(
    r'\b(?:a|an|the|and|or|but|as|if|to|of|for|with|from|into|upon|about|like|than|that|which|who|what|how|why|where|when|me|my|your|his|her|their|our|very)\s*["”’)\]}》]*$',
    caseSensitive: false,
  );
  return chunks.any((chunk) => danglingEnd.hasMatch(chunk.trim()));
}

bool _containsSingleChunkWithAll(List<String> chunks, List<String> needles) {
  return chunks.any(
    (chunk) => needles.every((needle) => chunk.contains(needle)),
  );
}

const _e10CaucusRace =
    r'''"In that case," said the Dodo solemnly, rising to its feet, "I move that the meeting adjourn, for the immediate adoption of more energetic remedies—"

"Speak English!" said the Eaglet. "I don't know the meaning of half those long words, and what's more, I don't believe you do either!" And the Eaglet bent down his head to hide a smile: some of the other birds tittered audibly.

"What I was going to say," said the Dodo in an offended tone, "was, that the best thing to get us dry would be a caucus-race."

"what is a caucus-race?" said Alice; not that she much wanted to know, but the Dodo had paused as if it thought that somebody ought to speak, and no one else seemed inclined to say anything.

"Why," said the Dodo, "the best way to explain it is to do it." (And as you might like to try the thing yourself, some winter day, I will tell you how the Dodo managed it.)

First it marked out a race-course, in a sort of circle ("the exact shape doesn't matter," it said), and then all the party were placed along the course, here and there. There was no "One, two, three, and away," but they began running when they liked and left off when they liked so that it was not easy to know when the race was over. However, when they had been running half an hour or so, and were quite dry again, the Dodo suddenly called out, "The race is over!" and they all crowded round it, panting, and asking, "But who has won?"

This question the Dodo could not answer without a great deal of thought, and it sat for a long time with one finger pressed upon its forehead (the position in which you usually see Shakespeare, in the pictures of him), while the rest waited in silence. At last the Dodo said, "Everybody has won, and all must have prizes."

"But who is to give the prizes?" quite a chorus of voices asked.

"Why, she, of course," said the Dodo, pointing to Alice with one finger; and the whole party at once crowded round her, calling out in a confused way, "Prizes, prizes!"

Alice had no idea what to do, and in despair she put her hand in her pocket, and pulled out a box of comfits, (luckily the salt water had not got into it), and handed them round as prizes. There was exactly one a-piece, all round.

"But she must have a prize herself, you know," said the Mouse.

"Of course," the Dodo replied very gravely. "What else have you got in your pocket?" he went on, turning to Alice.

"Only a thimble," said Alice sadly.

"Hand it over here," said the Dodo.

Then they all crowded round her once more, while the Dodo solemnly presented the thimble, saying "We beg your acceptance of this elegant thimble;" and, when it had finished this short speech, they all cheered.

Alice thought the whole thing very absurd, but they all looked so grave that she did not dare to laugh; and as she could not think of anything to say, she simply bowed, and took the thimble, looking as solemn as she could.

The next thing was to eat the comfits: this caused some noise and confusion, as the large birds complained that they could not taste theirs, and the small ones choked and had to be patted on the back. However, it was over at last, and they sat down again in a ring, and begged the Mouse to tell them something more.''';

const _e11MouseSadTale =
    r'''"You promised to tell me your history, you know," said Alice, "and why it is you hate—C and D," she added in a whisper, half afraid that it would be offended again.

"Mine is a long and a sad tale!" said the Mouse, turning to Alice, and sighing.

"It is a long tail, certainly," said Alice, looking down with wonder at the Mouse's tail; "but why do you call it sad?" And she kept on puzzling about it while the Mouse was speaking, so that her idea of the tale was something like this:

"Fury said to a mouse, That he met in the house, 'Let us both go to law: I will prosecute you.—Come, I'll take no denial; We must have a trial: For really this morning I've nothing to do.' Said the mouse to the cur, 'Such a trial, dear sir, With no jury or judge, would be wasting our breath.' 'I'll be judge, I'll be jury,' Said cunning old Fury: 'I'll try the whole cause, and condemn you to death.'"

"You are not attending!" said the Mouse to Alice, severely. "What are you thinking of?"

"I beg your pardon," said Alice very humbly: "you had got to the fifth bend, I think?"

"I had not!" cried the Mouse, sharply and very angrily.

"A knot!" said Alice, always ready to make herself useful, and looking anxiously about her. "Oh, do let me help to undo it!"

"I shall do nothing of the sort," said the Mouse, getting up and walking away. "You insult me by talking such nonsense!"

"I didn't mean it!" pleaded poor Alice. "But you're so easily offended, you know!"

The Mouse only growled in reply.

"Please come back, and finish your story!" Alice called after it; and the others all joined in chorus, "Yes, please do!" but the Mouse only shook its head impatiently, and walked a little quicker.

"What a pity it wouldn't stay!" sighed the Lory, as soon as it was quite out of sight; and an old crab took the opportunity of saying to her daughter, "Ah, my dear! Let this be a lesson to you never to lose your temper!" "Hold your tongue, ma!" said the young crab, a little snappishly. "You're enough to try the patience of an oyster!"

"I wish I had our Dinah here, I know I do!" said Alice aloud, addressing nobody in particular. "She'd soon fetch it back!"

"And who is Dinah, if I might venture to ask the question" said the Lory.

Alice replied eagerly, for she was always ready to talk about her pet. "Dinah's our cat. And she's such a capital one for catching mice you can't think! And oh, I wish you could see her after the birds! Why, she'll eat a little bird as soon as look at it!"

This speech caused a remarkable sensation among the party. Some of the birds hurried off at once: one old magpie began wrapping itself up very carefully, remarking, "I really must be getting home; the night air doesn't suit my throat!" and a canary called out in a trembling voice to its children, "Come away, my dears! It's high time you were all in bed!" On various pretexts they all moved off, and Alice was soon left alone.

"I wish I hadn't mentioned Dinah!" she said to herself in a melancholy tone. "Nobody seems to like her, down here, and I'm sure she's the best cat in the world! Oh, my dear Dinah! I wonder if I shall ever see you any more!" And here poor Alice began to cry again, for she felt very lonely and low-spirited. In a little while, however, she again heard a little pattering of footsteps in the distance, and she looked up eagerly, half hoping that the Mouse had changed his mind and was coming back to finish his story.''';

const _e12WhiteRabbitSearch = r'''The Rabbit Sends in a Little Bill

It was the White Rabbit, trotting slowly back again, and looking anxiously about as it went, as if it had lost something; and she heard it muttering to itself, "The Duchess! The Duchess! Oh my dear paws! Oh my fur and whiskers! She'll get me executed, as sure as ferrets are ferrets! Where can I have dropped them, I wonder!" Alice guessed in a moment that it was looking for the fan and the pair of white kid gloves, and she very good-naturedly began hunting about for them, but they were nowhere to be seen—everything seemed to have changed since her swim in the pool, and the great hall, with the glass table and the little door, had vanished completely.

Very soon the Rabbit noticed Alice, as she went hunting about, and called out to her in an angry tone, "Why, Mary Ann, what are you doing out here? Run home this moment, and fetch me a pair of gloves and a fan! Quick, now!" And Alice was so much frightened that she ran off at once in the direction it pointed to, without trying to explain the mistake it had made.

"He took me for his housemaid," she said to herself as she ran. "How surprised he'll be when he finds out who I am! But I'd better take him his fan and gloves—that is, if I can find them." As she said this, she came upon a neat little house, on the door of which was a bright brass plate with the name "W. RABBIT," engraved upon it. She went in without knocking, and hurried upstairs, in great fear lest she should meet the real Mary Ann, and be turned out of the house before she had found the fan and gloves.

"How queer it seems," Alice said to herself, "to be going messages for a rabbit! I suppose Dinah'll be sending me on messages next!" And she began fancying the sort of thing that would happen: "'Miss Alice! Come here directly, and get ready for your walk!' 'Coming in a minute, nurse! But I've got to watch this mousehole till Dinah comes back, and see that the mouse doesn't get out.' Only I don't think," Alice went on, "that they'd let Dinah stop in the house if it began ordering people about like that!"

By this time she had found her way into a tidy little room with a table in the window, and on it (as she had hoped) a fan and two or three pairs of tiny white kid gloves: she took up the fan and a pair of the gloves, and was just going to leave the room, when her eye fell upon a little bottle that stood near the looking-glass. There was no label this time with the words "DRINK ME," but nevertheless she uncorked it and put it to her lips. "I know something interesting is sure to happen," she said to herself, "whenever I eat or drink anything; so I'll just see what this bottle does. I do hope it'll make me grow large again, for really I'm quite tired of being such a tiny little thing!"''';
