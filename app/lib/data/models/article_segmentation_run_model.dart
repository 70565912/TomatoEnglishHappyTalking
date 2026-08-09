import 'dart:convert';

class ArticleSegmentationRunRecord {
  const ArticleSegmentationRunRecord({
    required this.sourceHash,
    required this.sentenceSplitVersion,
    required this.solverVersion,
    required this.parserVersion,
    required this.modelSha256,
    required this.parserHealthy,
    required this.parserIssues,
    required this.candidatePaths,
    required this.selectedPaths,
    required this.aiSource,
    required this.aiRemoteAttempts,
    required this.usedLocalFallback,
    required this.createdAt,
    this.aiProvider,
    this.aiModel,
    this.fallbackReason,
    this.translationSource,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.totalTokens = 0,
    this.estimatedCostCny,
    this.selectionTrace = const [],
  });

  final String sourceHash;
  final String sentenceSplitVersion;
  final String solverVersion;
  final String parserVersion;
  final String modelSha256;
  final bool parserHealthy;
  final List<String> parserIssues;
  final List<Map<String, dynamic>> candidatePaths;
  final Map<int, String> selectedPaths;
  final List<Map<String, dynamic>> selectionTrace;
  final String aiSource;
  final String? aiProvider;
  final String? aiModel;
  final int aiRemoteAttempts;
  final bool usedLocalFallback;
  final String? fallbackReason;
  final String? translationSource;
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final double? estimatedCostCny;
  final DateTime createdAt;

  ArticleSegmentationRunRecord copyWith({
    String? translationSource,
    int? inputTokens,
    int? outputTokens,
    int? totalTokens,
    double? estimatedCostCny,
  }) {
    return ArticleSegmentationRunRecord(
      sourceHash: sourceHash,
      sentenceSplitVersion: sentenceSplitVersion,
      solverVersion: solverVersion,
      parserVersion: parserVersion,
      modelSha256: modelSha256,
      parserHealthy: parserHealthy,
      parserIssues: parserIssues,
      candidatePaths: candidatePaths,
      selectedPaths: selectedPaths,
      selectionTrace: selectionTrace,
      aiSource: aiSource,
      aiProvider: aiProvider,
      aiModel: aiModel,
      aiRemoteAttempts: aiRemoteAttempts,
      usedLocalFallback: usedLocalFallback,
      fallbackReason: fallbackReason,
      translationSource: translationSource ?? this.translationSource,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      estimatedCostCny: estimatedCostCny ?? this.estimatedCostCny,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toDatabaseMap({required int articleId}) => {
        'article_id': articleId,
        'source_hash': sourceHash,
        'sentence_split_version': sentenceSplitVersion,
        'solver_version': solverVersion,
        'parser_version': parserVersion,
        'model_sha256': modelSha256,
        'parser_healthy': parserHealthy ? 1 : 0,
        'parser_issues_json': jsonEncode(parserIssues),
        'candidate_paths_json': jsonEncode({
          'schemaVersion': 'article_segmentation_candidate_audit_v3_3',
          'originals': candidatePaths,
          'selectionTrace': selectionTrace,
        }),
        'selected_paths_json': jsonEncode(
          selectedPaths.map((key, value) => MapEntry(key.toString(), value)),
        ),
        'ai_source': aiSource,
        'ai_provider': aiProvider,
        'ai_model': aiModel,
        'ai_remote_attempts': aiRemoteAttempts,
        'used_local_fallback': usedLocalFallback ? 1 : 0,
        'fallback_reason': fallbackReason,
        'translation_source': translationSource,
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'total_tokens': totalTokens,
        'estimated_cost_cny': estimatedCostCny,
        'created_at': createdAt.toIso8601String(),
      };
}
