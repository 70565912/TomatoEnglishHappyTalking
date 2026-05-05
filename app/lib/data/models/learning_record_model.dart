class LearningRecord {
  final int? id;
  final int articleId;
  final String sentence;
  final double overallScore;
  final double accuracyScore;
  final double fluencyScore;
  final double completenessScore;
  final double prosodyScore;
  final String? tokenScoresJson;
  final String? evaluationMetaJson;
  final DateTime createdAt;

  const LearningRecord({
    this.id,
    required this.articleId,
    required this.sentence,
    required this.overallScore,
    required this.accuracyScore,
    required this.fluencyScore,
    required this.completenessScore,
    required this.prosodyScore,
    this.tokenScoresJson,
    this.evaluationMetaJson,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'article_id': articleId,
        'sentence': sentence,
        'overall_score': overallScore,
        'accuracy_score': accuracyScore,
        'fluency_score': fluencyScore,
        'completeness_score': completenessScore,
        'prosody_score': prosodyScore,
        'token_scores_json': tokenScoresJson,
        'evaluation_meta_json': evaluationMetaJson,
        'created_at': createdAt.toIso8601String(),
      };

  factory LearningRecord.fromMap(Map<String, dynamic> map) => LearningRecord(
        id: map['id'] as int?,
        articleId: map['article_id'] as int,
        sentence: map['sentence'] as String,
        overallScore: (map['overall_score'] as num).toDouble(),
        accuracyScore: (map['accuracy_score'] as num).toDouble(),
        fluencyScore: (map['fluency_score'] as num).toDouble(),
        completenessScore: (map['completeness_score'] as num).toDouble(),
        prosodyScore: (map['prosody_score'] as num).toDouble(),
        tokenScoresJson: map['token_scores_json'] as String?,
        evaluationMetaJson: map['evaluation_meta_json'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}
