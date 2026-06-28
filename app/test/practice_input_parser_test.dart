import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/practice_input_parser.dart';
import 'package:tomato_english_happy_talking/services/nlp_service.dart';

void main() {
  group('PracticeInputParser', () {
    test('parses standard bilingual story locally', () {
      final parsed = PracticeInputParser.parse('''
Chapter Eight

The Queen's Croquet - Ground

第八章 女王的槌球场地

First came ten soldiers carrying clubs; these were all shaped like the three gardeners, oblong and flat, with their hands and feet at the corners;
最先走来的是十个拿着梅花棒的士兵；他们都像那三个园丁一样，长方形而扁平，手脚长在四个角上；

next the ten courtiers; these were ornamented all over with diamonds, and walked two and two, as the soldiers did.
接着是十个朝臣；他们浑身装饰着方块，两两并排行走，就像士兵们一样。

（注：原文中出现的扑克牌角色名称，只作为译注保留。）
''');

      expect(
        parsed.sourceKind,
        PracticeInputSourceKind.standardBilingual,
      );
      expect(parsed.titleCandidate, "The Queen's Croquet-Ground");
      expect(parsed.translationNotes, contains('扑克牌角色'));
      expect(parsed.englishContent, contains('First came ten soldiers'));
      expect(parsed.englishContent, contains('\n\nnext the ten courtiers'));
      expect(parsed.englishContent, isNot(contains('第八章')));
      expect(parsed.englishContent, isNot(contains('最先走来')));
      expect(parsed.englishContent, isNot(contains('注：')));
      expect(parsed.paragraphPairs, hasLength(2));
    });

    test('keeps full standard bilingual text and paragraph boundaries', () {
      final buffer = StringBuffer('A Long Garden Story\n\n长长的花园故事\n\n');
      for (var i = 0; i < 80; i++) {
        buffer
          ..writeln('Alice finds rose - tree number $i in the garden.')
          ..writeln('爱丽丝在花园里发现了第 $i 棵玫瑰树。')
          ..writeln();
      }

      final parsed = PracticeInputParser.parse(buffer.toString());

      expect(
        parsed.sourceKind,
        PracticeInputSourceKind.standardBilingual,
      );
      expect(parsed.titleCandidate, 'A Long Garden Story');
      expect(parsed.englishContent, contains('rose-tree number 0'));
      expect(parsed.englishContent, contains('rose-tree number 79'));
      expect(parsed.englishContent.split('\n\n'), hasLength(80));
      expect(parsed.englishContent, isNot(contains('爱丽丝')));
    });

    test('builds imported sentence translations for standard bilingual input',
        () {
      final parsed = PracticeInputParser.parse('''
Tom's Small Choice

汤姆的小选择

Tom finds a bright snack box. He shares it with his team.
汤姆发现了一个明亮的零食盒。他把它分享给自己的队友。

They smile and walk home.
他们微笑着走回家。
''');
      final sentences = NlpService.splitSentences(parsed.englishContent);

      final rows = parsed.buildSentenceTranslations(
        articleId: 7,
        sentences: sentences,
        now: DateTime.utc(2026, 1, 2),
      );

      expect(rows, hasLength(sentences.length));
      expect(rows.first.articleId, 7);
      expect(rows.first.sentenceIndex, 0);
      expect(rows.first.chineseText, '汤姆发现了一个明亮的零食盒。');
      expect(rows[1].chineseText, '他把它分享给自己的队友。');
      expect(rows.last.chineseText, '他们微笑着走回家。');
    });

    test('stops standard bilingual import at generic learning sections', () {
      final parsed = PracticeInputParser.parse('''
Mina's Garden Map

米娜的花园地图

Mina opens a garden map. She marks the first path.
米娜打开花园地图。她标出第一条小路。

The lanterns turn blue, and Mina walks home.
灯笼变成蓝色，米娜走回家。

Vocabulary: Key words
map
英 [mæp] 美 [mæp]
Useful phrases
She needs to attend class.
参考译文
她需要去上课。
''');
      final sentences = NlpService.splitSentences(parsed.englishContent);
      final rows = parsed.buildSentenceTranslations(
        articleId: 8,
        sentences: sentences,
        now: DateTime.utc(2026, 1, 2),
      );
      final importedChinese = rows.map((row) => row.chineseText).join('\n');

      expect(parsed.sourceKind, PracticeInputSourceKind.standardBilingual);
      expect(parsed.englishContent, contains('Mina opens a garden map.'));
      expect(parsed.englishContent, contains('Mina walks home.'));
      expect(parsed.englishContent, isNot(contains('Vocabulary')));
      expect(parsed.englishContent, isNot(contains('英 [')));
      expect(parsed.englishContent, isNot(contains('attend class')));
      expect(sentences.last, contains('walks home.'));
      expect(rows, hasLength(sentences.length));
      expect(importedChinese, isNot(contains('参考译文')));
      expect(importedChinese, isNot(contains('需要去上课')));
    });

    test('keeps imported translations aligned near the end of a long story',
        () {
      final parsed = PracticeInputParser.parse('''
The Queen's Croquet - Ground

女王的槌球场地

"Are their heads off?" shouted the Queen.
“他们的头砍掉了吗？”王后喊道。

"Their heads are gone, if it please your majesty!" the soldiers shouted in reply.
“启禀陛下，他们的头都没了！”士兵们大声回答。

"That's right!" shouted the Queen.
“很好！”王后喊道。

"Can you play croquet?"
“你会玩槌球吗？”

The soldiers were silent, and looked at Alice, as the question was evidently meant for her.
士兵们沉默不语，看着爱丽丝，显然这个问题是问她的。

"Yes!" shouted Alice.
“会！”爱丽丝大声回答。

"Come on then!" roared the Queen, and Alice joined the procession, wondering very much what would happen next.
“那就过来！”王后吼道，爱丽丝加入了游行队伍，心里非常好奇接下来会发生什么。
''');
      final sentences = NlpService.splitSentences(parsed.englishContent);

      final rows = parsed.buildSentenceTranslations(
        articleId: 9,
        sentences: sentences,
        now: DateTime.utc(2026, 1, 2),
      );
      final joinedRow = rows.firstWhere(
        (row) => row.englishSentence.contains('Alice joined the procession'),
      );

      expect(rows, hasLength(sentences.length));
      expect(rows.every((row) => row.chineseText.trim().isNotEmpty), isTrue);
      expect(joinedRow.chineseText, contains('爱丽丝加入了游行队伍'));
      expect(joinedRow.chineseText, contains('接下来会发生什么'));
      expect(joinedRow.chineseText, isNot(contains('会！"爱丽丝大声回答')));
    });

    test('keeps translations when phrase chunks merge across paragraphs', () {
      final parsed = PracticeInputParser.parse('''
The Queen's Croquet - Ground

女王的槌球场地

The Queen turned crimson with fury, and began screaming, "Off with her head! Off-"
王后气得满脸通红，然后开始尖叫：“砍掉她的头！砍——”

"Nonsense!" said Alice, very loudly and decidedly, and the Queen was silent.
“胡扯！”爱丽丝非常大声而坚决地说，王后一下子沉默了。
''');
      final sentences = NlpService.splitSentences(parsed.englishContent);

      final rows = parsed.buildSentenceTranslations(
        articleId: 10,
        sentences: sentences,
        now: DateTime.utc(2026, 1, 2),
      );

      expect(rows, hasLength(sentences.length));
      expect(rows.map((row) => row.sentenceIndex).toSet(),
          hasLength(sentences.length));
      expect(rows.every((row) => row.chineseText.trim().isNotEmpty), isTrue);
      expect(
        rows
            .firstWhere((row) => row.englishSentence.contains('Nonsense'))
            .chineseText,
        isNotEmpty,
      );
    });

    test('fills imported translation for sentence spanning two paragraphs', () {
      final parsed = PracticeInputParser.parse('''
The Queen's Croquet - Ground

女王的槌球场地

"I see!" said the Queen, who had meanwhile been examining the roses. "Off with their heads!"
“我明白了！”王后说，她刚才一直在仔细查看那些玫瑰，“砍掉他们的头！”

and the procession moved on, three of the soldiers remaining behind to execute the unfortunate gardeners, who ran to Alice for protection.
游行队伍继续前进，三名士兵留下来处决这三个倒霉的园丁，园丁们跑向爱丽丝寻求保护。

"Are their heads off?" shouted the Queen.
“他们的头砍掉了吗？”王后喊道。
''');
      final sentences = NlpService.splitSentences(parsed.englishContent);

      final rows = parsed.buildSentenceTranslations(
        articleId: 11,
        sentences: sentences,
        now: DateTime.utc(2026, 1, 2),
      );
      final mergedRow = rows.firstWhere(
        (row) => row.englishSentence.contains('procession moved on'),
      );

      expect(rows, hasLength(sentences.length));
      expect(rows.map((row) => row.sentenceIndex).toSet(),
          hasLength(sentences.length));
      expect(rows.every((row) => row.chineseText.trim().isNotEmpty), isTrue);
      expect(mergedRow.chineseText, anyOf(contains('砍掉'), contains('游行队伍')));
      expect(mergedRow.chineseText, isNot(contains('他们的头砍掉了吗')));
    });

    test('classifies pure English and pure Chinese without mixed extraction',
        () {
      final english = PracticeInputParser.parse(
        'Mia opens a map.\n\nShe starts a gentle adventure.',
      );
      final chinese = PracticeInputParser.parse('小米打开地图，开始了一段冒险。');

      expect(english.sourceKind, PracticeInputSourceKind.english);
      expect(english.englishContent, contains('\n\nShe starts'));
      expect(chinese.sourceKind, PracticeInputSourceKind.chinese);
      expect(chinese.englishContent, isEmpty);
    });

    test('extracts English original section from lesson notes locally', () {
      final parsed = PracticeInputParser.parse('''
E27 拿火烈鸟当球槌：王后真的在打球赛吗？
课程导读
这里是中文导读，不应该进入英文正文。

英文原文

"It's—it's a very fine day!" said a timid voice at her side.
"Very," said Alice. "where's the Duchess?"
"Did you say 'What a pity!'?" the Rabbit asked.

The Queen said—
"Get to your places!" shouted the Queen in a voice of thunder, and people began running about in all directions.

【文化卡片】

生词好句
1.look over one's shoulder
某人回头看
''');

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.usesLocalEnglish, isTrue);
      expect(parsed.englishContent, contains("It's—it's a very fine day"));
      expect(parsed.englishContent, contains("say 'What a pity!'"));
      expect(parsed.englishContent, contains('The Queen said—'));
      expect(parsed.englishContent, contains("Get to your places"));
      expect(parsed.englishContent, contains('The Queen said— "Get'));
      expect(parsed.englishContent, isNot(contains('课程导读')));
      expect(parsed.englishContent, isNot(contains('文化卡片')));
      expect(
          parsed.englishContent, isNot(contains("look over one's shoulder")));
    });

    test('extracts full E28 story around inserted expansion notes', () {
      final raw = File(
        'test/fixtures/e28_cheshire_cat_raw_input.txt',
      ).readAsStringSync();

      final parsed = PracticeInputParser.parse(raw);
      final sentences = NlpService.splitSentences(parsed.englishContent);

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.usesLocalEnglish, isTrue);
      expect(parsed.englishContent,
          contains('"I don\'t think they play at all fairly," Alice began'));
      expect(parsed.englishContent,
          contains('"A cat may look at a king," said Alice.'));
      expect(parsed.englishContent,
          contains('"Well, it must be removed," said the King'));
      expect(parsed.englishContent,
          contains('The moment Alice appeared, she was appealed to'));
      expect(parsed.englishContent, contains('what they said.'));
      expect(parsed.englishContent, isNot(contains('【拓展】')));
      expect(parsed.englishContent, isNot(contains('精神抵抗形式')));
      expect(
          parsed.englishContent, isNot(contains('A Cat May Look Upon a King')));
      expect(parsed.englishContent, isNot(contains('【文化卡片】')));
      expect(parsed.englishContent, isNot(contains('生词好句')));
      expect(parsed.englishContent,
          isNot(contains("I can't stand it when people don't attend")));
      expect(parsed.englishContent,
          isNot(contains('This seems to me an excellent opportunity')));
      expect(sentences.length, greaterThan(20));
      expect(sentences.last, contains('what they said.'));
    });

    test('extracts E01 preface poem from raw lesson input', () {
      final raw = File(
        'test/fixtures/e01_preface_poem_raw_input.txt',
      ).readAsStringSync();

      final parsed = PracticeInputParser.parse(raw);

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.usesLocalEnglish, isTrue);
      expect(parsed.englishContent, contains('All in the golden afternoon'));
      expect(
          parsed.englishContent, contains('Against three tongues together?'));
      expect(parsed.englishContent, contains('Imperious Prima flashes forth'));
      expect(parsed.englishContent, contains('The happy voices cry.'));
      expect(
          parsed.englishContent, contains('Thus grew the tale of Wonderland:'));
      expect(parsed.englishContent, contains("Pluck'd in a far-off land."));
      expect(parsed.englishContent,
          isNot(contains('ALICE’S ADVENTURES IN WONDERLAND')));
      expect(parsed.englishContent, isNot(contains('Clotho')));
      expect(parsed.englishContent, isNot(contains('Hippocrene')));
      expect(parsed.englishContent, isNot(contains('【文化卡片】')));
      expect(parsed.englishContent, isNot(contains('生词好句')));
      expect(parsed.englishContent, isNot(contains('英 [')));
      expect(parsed.englishContent, isNot(contains('hammer n. 锤子')));
      expect(
        parsed.englishContent.trim(),
        endsWith("Pluck'd in a far-off land."),
      );
    });

    test('extracts E27 croquet story from raw lesson input', () {
      final raw = File(
        'test/fixtures/e27_croquet_ground_raw_input.txt',
      ).readAsStringSync();

      final parsed = PracticeInputParser.parse(raw);
      final sentences = NlpService.splitSentences(parsed.englishContent);

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.usesLocalEnglish, isTrue);
      expect(parsed.englishContent,
          contains("\"It's—it's a very fine day!\" said a timid voice"));
      expect(parsed.englishContent, contains('"Get to your places!"'));
      expect(parsed.englishContent,
          contains('Alice thought she had never seen such a curious'));
      expect(parsed.englishContent,
          contains('The chief difficulty Alice found at first'));
      expect(parsed.englishContent,
          contains('now I shall have somebody to talk to.'));
      expect(parsed.englishContent, contains('no more of it appeared.'));
      expect(parsed.englishContent, isNot(contains('【文化卡片】')));
      expect(parsed.englishContent, isNot(contains('生词好句')));
      expect(parsed.englishContent,
          isNot(contains('Everything is under control')));
      expect(parsed.englishContent,
          isNot(contains('I need time to straighten out my finances')));
      expect(parsed.englishContent,
          isNot(contains('The diaries contained a detailed account')));
      expect(sentences.length, greaterThan(20));
      expect(sentences.last, contains('no more of it appeared.'));
    });

    test('extracts E11 Mouse story from raw lesson input', () {
      final raw = File(
        'test/fixtures/e11_mouse_sad_tale_raw_input.txt',
      ).readAsStringSync();

      final parsed = PracticeInputParser.parse(raw);
      final sentences = NlpService.splitSentences(parsed.englishContent);

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.usesLocalEnglish, isTrue);
      expect(
        parsed.englishContent,
        contains('"You promised to tell me your history'),
      );
      expect(parsed.englishContent, contains('Fury said to a mouse'));
      expect(parsed.englishContent, contains('condemn you to death'));
      expect(parsed.englishContent, contains('"I didn\'t mean it!"'));
      expect(
        parsed.englishContent,
        contains('coming back to finish his story.'),
      );
      expect(parsed.englishContent, isNot(contains('concrete poetry')));
      expect(
        parsed.englishContent,
        isNot(contains('with so evident a design')),
      );
      expect(parsed.englishContent, isNot(contains('Anticlimax')));
      expect(
        parsed.englishContent,
        isNot(contains('attend vs. pay attention')),
      );
      expect(parsed.englishContent, isNot(contains('英 [')));
      expect(parsed.englishContent, isNot(contains('pretext vs. excuse')));
      expect(sentences, isNotEmpty);
      expect(sentences.last, contains('finish his story.'));
    });

    test('stops Mouse sad tale import before learning notes', () {
      final raw = File(
        'test/fixtures/mouse_sad_tale_with_learning_notes.txt',
      ).readAsStringSync();

      final parsed = PracticeInputParser.parse(raw);
      final sentences = NlpService.splitSentences(parsed.englishContent);
      final rows = parsed.buildSentenceTranslations(
        articleId: 56,
        sentences: sentences,
        now: DateTime.utc(2026, 6, 27),
      );
      final importedChinese = rows.map((row) => row.chineseText).join('\n');
      const learningNoteNeedles = [
        'attend vs. pay attention',
        'Bill has not been attending',
        '英 [',
        '美 [',
        "lose one's temper",
        'pretext',
      ];

      expect(parsed.sourceKind, PracticeInputSourceKind.standardBilingual);
      expect(parsed.usesLocalEnglish, isTrue);
      expect(parsed.titleCandidate, "The Mouse's Sad Tale");
      expect(
        parsed.englishContent,
        contains('"You promised to tell me your history'),
      );
      expect(
        parsed.englishContent,
        contains('coming back to finish his story.'),
      );
      for (final needle in learningNoteNeedles) {
        expect(parsed.englishContent, isNot(contains(needle)));
      }
      expect(sentences, isNotEmpty);
      expect(sentences.last, contains('finish his story.'));
      expect(sentences.last, isNot(contains('pretext')));
      expect(importedChinese, isNot(contains('文化卡片')));
      expect(importedChinese, isNot(contains('生词好句')));
      expect(
          rows.every((row) => row.englishSentence.trim().isNotEmpty), isTrue);
    });

    test('skips generic explanation insertions and resumes story prose', () {
      final parsed = PracticeInputParser.parse('''
英文原文

Alice looked at the Cat and smiled.

【难句解析】

这一段是在讲解句子结构，不是故事正文。
An Explanation Title Without Story Action

The King went behind Alice and spoke in a low voice.

【补充说明】

这里继续讲解背景知识。

"Well, it must be removed," said the King very decidedly.

生词好句
I can't stand it when people don't attend to the rules.
''');

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.englishContent, contains('Alice looked at the Cat'));
      expect(parsed.englishContent, contains('The King went behind Alice'));
      expect(parsed.englishContent,
          contains('"Well, it must be removed," said the King'));
      expect(parsed.englishContent, isNot(contains('讲解句子结构')));
      expect(parsed.englishContent,
          isNot(contains('An Explanation Title Without Story Action')));
      expect(parsed.englishContent,
          isNot(contains("I can't stand it when people don't attend")));
    });

    test('skips non-bracket lesson insertions and stops at vocab sections', () {
      final parsed = PracticeInputParser.parse('''
英文原文

Alice walked across the court and looked for the Cat.

Background Knowledge:

这一段是背景说明，不是故事正文。
The Cheshire Cat in folklore

Teacher's Note

这里是老师提示，也不应进入正文。

The King hurried after Alice and whispered to her. She listened carefully while the cards argued nearby.

Vocabulary: Key words
attend to
I can't stand it when people don't attend to the rules.
Reference Translation
国王追上爱丽丝，小声对她说话。
''');

      expect(parsed.sourceKind, PracticeInputSourceKind.english);
      expect(parsed.englishContent, contains('Alice walked across the court'));
      expect(parsed.englishContent, contains('The King hurried after Alice'));
      expect(parsed.englishContent, contains('cards argued nearby'));
      expect(parsed.englishContent, isNot(contains('背景说明')));
      expect(parsed.englishContent,
          isNot(contains('The Cheshire Cat in folklore')));
      expect(parsed.englishContent, isNot(contains("Teacher's Note")));
      expect(parsed.englishContent,
          isNot(contains("I can't stand it when people don't attend")));
      expect(parsed.englishContent, isNot(contains('Reference Translation')));
    });

    test('falls back to mixed when inserted notes hide possible story text',
        () {
      final parsed = PracticeInputParser.parse('''
课程导读
中文导读。

英文原文

Alice looked at the Cat.

【拓展】

A Cat May Look Upon a King

【文化卡片】

生词好句
I can't stand it when people don't attend to the rules.
''');

      expect(parsed.sourceKind, PracticeInputSourceKind.mixed);
      expect(parsed.englishContent, isEmpty);
    });
  });
}
