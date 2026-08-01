import 'dart:convert';

class Article {
  static const legacySentenceSplitVersion = 'legacy_v1';

  final int? id;
  final String title;
  final String content;
  final List<String> sentences;
  final String sentenceSplitVersion;
  final DateTime createdAt;

  const Article({
    this.id,
    required this.title,
    required this.content,
    required this.sentences,
    this.sentenceSplitVersion = legacySentenceSplitVersion,
    required this.createdAt,
  });

  Article copyWith({
    int? id,
    String? title,
    String? content,
    List<String>? sentences,
    String? sentenceSplitVersion,
    DateTime? createdAt,
  }) =>
      Article(
        id: id ?? this.id,
        title: title ?? this.title,
        content: content ?? this.content,
        sentences: sentences ?? this.sentences,
        sentenceSplitVersion: sentenceSplitVersion ?? this.sentenceSplitVersion,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'content': content,
        'sentences': jsonEncode(sentences),
        'sentence_split_version': sentenceSplitVersion,
        'created_at': createdAt.toIso8601String(),
      };

  factory Article.fromMap(Map<String, dynamic> map) => Article(
        id: map['id'] as int?,
        title: map['title'] as String,
        content: map['content'] as String,
        sentences: List<String>.from(
          jsonDecode(map['sentences'] as String) as List,
        ),
        sentenceSplitVersion:
            (map['sentence_split_version'] as String?)?.trim().isNotEmpty ==
                    true
                ? (map['sentence_split_version'] as String).trim()
                : legacySentenceSplitVersion,
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}
