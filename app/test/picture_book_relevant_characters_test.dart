import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';

void main() {
  const bill = BookCharacter(
    name: 'Bill',
    description: 'A small, frail lizard sent down the chimney.',
  );
  const alice = BookCharacter(
    name: 'Alice',
    description: 'A curious seven-year-old girl in a blue dress.',
  );
  const mockTurtle = BookCharacter(
    name: 'Mock Turtle',
    description: 'A melancholy turtle-like sea creature.',
  );

  test('lowercase common noun bill does not match character Bill', () {
    final article = Article(
      title: "E32 - The Mock Turtle's Lessons",
      content:
          "Now at ours they had at the end of the bill, "
          "'French, music, and washing—extra.'",
      sentences: const [
        "Now at ours they had at the end of the bill, "
            "'French, music, and washing—extra.'",
        'Alice listened to the Mock Turtle.',
      ],
      createdAt: DateTime.utc(2026, 7, 12),
    );

    final relevant = PictureBookService.relevantCharactersForArticle(
      article,
      const [bill, alice, mockTurtle],
    );

    expect(relevant.map((c) => c.name), isNot(contains('Bill')));
    expect(relevant.map((c) => c.name), containsAll(['Alice', 'Mock Turtle']));
  });

  test('capitalized Bill mention still matches character Bill', () {
    final article = Article(
      title: 'Bill the Lizard',
      content: 'They sent Bill down the chimney.',
      sentences: const ['They sent Bill down the chimney.'],
      createdAt: DateTime.utc(2026, 7, 12),
    );

    final relevant = PictureBookService.relevantCharactersForArticle(
      article,
      const [bill, alice],
    );

    expect(relevant.map((c) => c.name), contains('Bill'));
    expect(relevant.map((c) => c.name), isNot(contains('Alice')));
  });

  test('possessive capitalized name still matches', () {
    final article = Article(
      title: "Bill's mishap",
      content: "Bill's friends helped him.",
      sentences: const ["Bill's friends helped him."],
      createdAt: DateTime.utc(2026, 7, 12),
    );

    final relevant = PictureBookService.relevantCharactersForArticle(
      article,
      const [bill],
    );

    expect(relevant.map((c) => c.name), contains('Bill'));
  });

  test('substring king inside shaking does not match character King', () {
    const king = BookCharacter(
      name: 'King',
      description: 'A timid Victorian monarch.',
    );
    final article = Article(
      title: "E32 - The Mock Turtle's Lessons",
      content: 'and it set to work shaking him and punching him in the back.',
      sentences: const [
        'and it set to work shaking him and punching him in the back.',
        'Alice listened to the Mock Turtle.',
      ],
      createdAt: DateTime.utc(2026, 7, 12),
    );

    final relevant = PictureBookService.relevantCharactersForArticle(
      article,
      const [king, alice, mockTurtle],
    );

    expect(relevant.map((c) => c.name), isNot(contains('King')));
    expect(relevant.map((c) => c.name), containsAll(['Alice', 'Mock Turtle']));
  });
}
