class ArticleSentenceTranslation {
  const ArticleSentenceTranslation({
    required this.articleId,
    required this.sentenceIndex,
    required this.englishSentence,
    required this.chineseText,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
  });

  final int articleId;
  final int sentenceIndex;
  final String englishSentence;
  final String chineseText;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
        'article_id': articleId,
        'sentence_index': sentenceIndex,
        'english_sentence': englishSentence,
        'chinese_text': chineseText,
        'source': source,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ArticleSentenceTranslation.fromMap(Map<String, dynamic> map) =>
      ArticleSentenceTranslation(
        articleId: (map['article_id'] as num).toInt(),
        sentenceIndex: (map['sentence_index'] as num).toInt(),
        englishSentence: map['english_sentence'] as String,
        chineseText: map['chinese_text'] as String,
        source: map['source'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}
