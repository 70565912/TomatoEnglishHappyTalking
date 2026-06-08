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
      expect(joinedRow.chineseText.startsWith('"'), isFalse);
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
  });
}
