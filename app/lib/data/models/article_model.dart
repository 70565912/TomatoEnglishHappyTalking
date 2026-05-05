import 'dart:convert';

class Article {
  final int? id;
  final String title;
  final String content;
  final List<String> sentences;
  final DateTime createdAt;

  const Article({
    this.id,
    required this.title,
    required this.content,
    required this.sentences,
    required this.createdAt,
  });

  Article copyWith({
    int? id,
    String? title,
    String? content,
    List<String>? sentences,
    DateTime? createdAt,
  }) =>
      Article(
        id: id ?? this.id,
        title: title ?? this.title,
        content: content ?? this.content,
        sentences: sentences ?? this.sentences,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'content': content,
        'sentences': jsonEncode(sentences),
        'created_at': createdAt.toIso8601String(),
      };

  factory Article.fromMap(Map<String, dynamic> map) => Article(
        id: map['id'] as int?,
        title: map['title'] as String,
        content: map['content'] as String,
        sentences: List<String>.from(
          jsonDecode(map['sentences'] as String) as List,
        ),
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}
