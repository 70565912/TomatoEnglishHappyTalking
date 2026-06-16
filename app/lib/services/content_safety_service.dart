import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite/sqflite.dart';

import 'api_cache_service.dart';
import 'database_service.dart';

class ContentSafetyClassification {
  const ContentSafetyClassification({
    required this.suspectedSafetyBlock,
    required this.errorCode,
    required this.message,
    this.statusCode,
  });

  final bool suspectedSafetyBlock;
  final String errorCode;
  final String message;
  final int? statusCode;
}

class ContentSafetyAppliedRule {
  const ContentSafetyAppliedRule({
    required this.id,
    required this.sourceTerm,
    required this.replacement,
    required this.serviceKind,
    required this.purposeScope,
    required this.matchType,
    required this.confidence,
  });

  final int id;
  final String sourceTerm;
  final String replacement;
  final String serviceKind;
  final String purposeScope;
  final String matchType;
  final double confidence;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceTerm': sourceTerm,
        'replacement': replacement,
        'serviceKind': serviceKind,
        'purposeScope': purposeScope,
        'matchType': matchType,
        'confidence': confidence,
      };
}

class ContentSafetyPreparedText {
  const ContentSafetyPreparedText({
    required this.text,
    required this.appliedRules,
  });

  final String text;
  final List<ContentSafetyAppliedRule> appliedRules;

  bool get changed => appliedRules.isNotEmpty;
}

class ContentSafetyService {
  static const serviceAny = '*';
  static const serviceOpenAiText = 'openai_text';
  static const serviceArkText = 'ark_text';
  static const serviceBailianFunMusic = 'bailian_fun_music';
  static const servicePictureBookImage = 'picture_book_image';
  static const serviceTts = 'tts';
  static const purposeAny = '*';

  static ContentSafetyClassification classifyFailure(Object error) {
    final summary = _errorSummary(error);
    final lower = summary.toLowerCase();
    final statusCode = _statusCode(error, summary);
    final code = _extractErrorCode(error, summary);
    const safetyKeywords = [
      'sensitivecontentdetected',
      'inputtextriskdetection',
      'audit_content_risky',
      'content_risk',
      'content risk',
      'green net',
      'greennet',
      'green net check',
      'risk detection',
      'riskdetection',
      'sensitive',
      'safety',
      'unsafe',
      'forbidden',
      'blocked',
      '违规',
      '敏感',
      '安全',
      '风险',
      '绿网',
    ];
    final hasSafetyKeyword =
        safetyKeywords.any((keyword) => lower.contains(keyword));
    final emptyBadRequest = statusCode == 400 &&
        ((error is DioException && _responseBodyText(error).trim().isEmpty) ||
            (error is! DioException && !_looksLikeParameterOrAuthError(lower)));
    return ContentSafetyClassification(
      suspectedSafetyBlock: hasSafetyKeyword || emptyBadRequest,
      statusCode: statusCode,
      errorCode: code.isNotEmpty
          ? code
          : statusCode == 400
              ? 'http_400'
              : 'unknown',
      message: summary,
    );
  }

  static Future<String> prepareTextForApi(
    String text, {
    required String serviceKind,
    required String purpose,
  }) async {
    final prepared = await prepareTextWithRulesForApi(
      text,
      serviceKind: serviceKind,
      purpose: purpose,
    );
    return prepared.text;
  }

  static Future<ContentSafetyPreparedText> prepareTextWithRulesForApi(
    String text, {
    required String serviceKind,
    required String purpose,
  }) async {
    final rules = await enabledRules(
      serviceKind: serviceKind,
      purpose: purpose,
    );
    var prepared = text;
    final applied = <ContentSafetyAppliedRule>[];
    for (final rule in rules) {
      final before = prepared;
      prepared = _applyRule(prepared, rule);
      if (prepared != before) {
        applied.add(rule);
      }
    }
    return ContentSafetyPreparedText(
      text: prepared,
      appliedRules: applied,
    );
  }

  static Future<List<ContentSafetyAppliedRule>> enabledRules({
    required String serviceKind,
    required String purpose,
  }) async {
    final db = await DatabaseService.database;
    final rows = await db.rawQuery(
      '''
      SELECT * FROM content_safety_rules
      WHERE enabled = 1
        AND service_kind IN (?, ?)
        AND purpose_scope IN (?, ?)
      ORDER BY confidence DESC, LENGTH(source_term) DESC, id ASC
      ''',
      [serviceKind, serviceAny, purpose, purposeAny],
    );
    return rows.map(_ruleFromMap).toList(growable: false);
  }

  static Future<int> recordFailure({
    required String serviceKind,
    required String purpose,
    int? articleId,
    required String failedText,
    required String errorCode,
    required String errorMessage,
  }) async {
    final trimmed = failedText.trim();
    if (trimmed.isEmpty) {
      return 0;
    }
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    return db.insert('content_safety_failures', {
      'service_kind': serviceKind,
      'purpose': purpose,
      'article_id': articleId,
      'failed_text': trimmed,
      'failed_hash': await ApiCacheService.hashUtf8(trimmed),
      'error_code': errorCode,
      'error_message': _shorten(errorMessage, 1600),
      'created_at': now,
      'resolved_at': null,
    });
  }

  static Future<List<ContentSafetyAppliedRule>> learnRulesFromSuccessfulRetry({
    required int failureId,
    required String successfulText,
    String? serviceKind,
    String purposeScope = purposeAny,
  }) async {
    if (failureId <= 0 || successfulText.trim().isEmpty) {
      return const [];
    }
    final db = await DatabaseService.database;
    final rows = await db.query(
      'content_safety_failures',
      where: 'id = ?',
      whereArgs: [failureId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const [];
    }
    final failure = rows.first;
    final failedText = failure['failed_text']?.toString() ?? '';
    final learned = _inferReplacementPairs(failedText, successfulText);
    final now = DateTime.now().toIso8601String();
    final saved = <ContentSafetyAppliedRule>[];
    for (final pair in learned) {
      await db.insert(
        'content_safety_rules',
        {
          'source_term': pair.sourceTerm,
          'replacement': pair.replacement,
          'service_kind': serviceKind ??
              failure['service_kind']?.toString() ??
              serviceArkText,
          'purpose_scope': purposeScope,
          'match_type': 'word',
          'confidence': 0.9,
          'enabled': 1,
          'source_failure_id': failureId,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final ruleRows = await db.query(
        'content_safety_rules',
        where:
            'source_term = ? AND replacement = ? AND service_kind = ? AND purpose_scope = ?',
        whereArgs: [
          pair.sourceTerm,
          pair.replacement,
          serviceKind ?? failure['service_kind']?.toString() ?? serviceArkText,
          purposeScope,
        ],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (ruleRows.isNotEmpty) {
        saved.add(_ruleFromMap(ruleRows.first));
      }
    }
    await db.update(
      'content_safety_failures',
      {'resolved_at': now},
      where: 'id = ?',
      whereArgs: [failureId],
    );
    return saved;
  }

  static Future<List<ContentSafetyAppliedRule>>
      learnRulesFromLatestSuccessfulRetry({
    required String serviceKind,
    required String purpose,
    int? articleId,
    required String successfulText,
    String purposeScope = purposeAny,
  }) async {
    final db = await DatabaseService.database;
    final where = <String>[
      'service_kind = ?',
      'purpose = ?',
      'resolved_at IS NULL',
    ];
    final args = <Object?>[serviceKind, purpose];
    if (articleId != null) {
      where.add('(article_id = ? OR article_id IS NULL)');
      args.add(articleId);
    }
    final rows = await db.query(
      'content_safety_failures',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return const [];
    }
    final id = (rows.first['id'] as num?)?.toInt() ?? 0;
    return learnRulesFromSuccessfulRetry(
      failureId: id,
      successfulText: successfulText,
      serviceKind: serviceKind,
      purposeScope: purposeScope,
    );
  }

  static Future<String> exportSafetyReport({
    String? outputDirectory,
    int limit = 100,
  }) async {
    final db = await DatabaseService.database;
    final failures = await db.query(
      'content_safety_failures',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    final rules = await db.query(
      'content_safety_rules',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    final dir = Directory(outputDirectory ?? await _defaultReportDirectory());
    await dir.create(recursive: true);
    final filePath = path_lib.join(
      dir.path,
      'content_safety_report_${_timestampForFile()}.json',
    );
    const encoder = JsonEncoder.withIndent('  ');
    await File(filePath).writeAsString(
      encoder.convert({
        'generatedAt': DateTime.now().toIso8601String(),
        'failures': failures,
        'rules': rules,
      }),
    );
    return filePath;
  }

  static Future<void> setRuleEnabled(int id, bool enabled) async {
    final db = await DatabaseService.database;
    await db.update(
      'content_safety_rules',
      {
        'enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteRule(int id) async {
    final db = await DatabaseService.database;
    await db.delete(
      'content_safety_rules',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<Map<String, dynamic>>> listRules({
    bool includeDisabled = true,
  }) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'content_safety_rules',
      where: includeDisabled ? null : 'enabled = 1',
      orderBy: 'enabled DESC, confidence DESC, updated_at DESC, id ASC',
    );
    return rows
        .map(
          (row) => {
            'id': (row['id'] as num?)?.toInt() ?? 0,
            'sourceTerm': row['source_term']?.toString() ?? '',
            'replacement': row['replacement']?.toString() ?? '',
            'serviceKind': row['service_kind']?.toString() ?? serviceAny,
            'purposeScope': row['purpose_scope']?.toString() ?? purposeAny,
            'matchType': row['match_type']?.toString() ?? 'word',
            'confidence': (row['confidence'] as num?)?.toDouble() ?? 0,
            'enabled': ((row['enabled'] as num?)?.toInt() ?? 0) == 1,
            'sourceFailureId': (row['source_failure_id'] as num?)?.toInt(),
            'createdAt': row['created_at']?.toString() ?? '',
            'updatedAt': row['updated_at']?.toString() ?? '',
          },
        )
        .toList(growable: false);
  }

  static String _applyRule(String text, ContentSafetyAppliedRule rule) {
    final source = rule.sourceTerm.trim();
    if (source.isEmpty || rule.replacement.trim().isEmpty) {
      return text;
    }
    if (rule.matchType == 'phrase') {
      return text.replaceAllMapped(
        RegExp(RegExp.escape(source), caseSensitive: false),
        (match) => _matchCase(match.group(0) ?? source, rule.replacement),
      );
    }
    return text.replaceAllMapped(
      RegExp(
        '(^|[^A-Za-z])(${RegExp.escape(source)})(?![A-Za-z])',
        caseSensitive: false,
      ),
      (match) {
        final prefix = match.group(1) ?? '';
        final word = match.group(2) ?? source;
        return '$prefix${_matchCase(word, rule.replacement)}';
      },
    );
  }

  static ContentSafetyAppliedRule _ruleFromMap(Map<String, Object?> row) =>
      ContentSafetyAppliedRule(
        id: (row['id'] as num?)?.toInt() ?? 0,
        sourceTerm: row['source_term']?.toString() ?? '',
        replacement: row['replacement']?.toString() ?? '',
        serviceKind: row['service_kind']?.toString() ?? serviceAny,
        purposeScope: row['purpose_scope']?.toString() ?? purposeAny,
        matchType: row['match_type']?.toString() ?? 'word',
        confidence: (row['confidence'] as num?)?.toDouble() ?? 0,
      );

  static List<_ReplacementPair> _inferReplacementPairs(
    String failedText,
    String successfulText,
  ) {
    final candidates = <String>{};
    for (final match
        in RegExp(r"[A-Za-z][A-Za-z']{2,39}").allMatches(failedText)) {
      final source = match.group(0) ?? '';
      final canonical = _lettersOnly(source);
      if (canonical.length >= 3) {
        candidates.add(source);
      }
    }
    final pairs = <_ReplacementPair>[];
    for (final source in candidates) {
      final canonical = _lettersOnly(source);
      final separated =
          canonical.split('').map(RegExp.escape).join(r'[\s\-\*]*');
      final pattern = RegExp(
        '(^|[^A-Za-z])($separated)(?![A-Za-z])',
        caseSensitive: false,
      );
      for (final match in pattern.allMatches(successfulText)) {
        final replacement = (match.group(2) ?? '').trim();
        if (replacement.isEmpty ||
            replacement.toLowerCase() == source.toLowerCase() ||
            _lettersOnly(replacement) != canonical ||
            !RegExp(r'[\s\-\*]').hasMatch(replacement)) {
          continue;
        }
        pairs.add(
          _ReplacementPair(
            sourceTerm: source.toLowerCase(),
            replacement: _preferPronounceableReplacement(replacement),
          ),
        );
        break;
      }
      if (pairs.length >= 8) {
        break;
      }
    }
    return pairs;
  }

  static String _preferPronounceableReplacement(String replacement) {
    return replacement.replaceAll('*', '-').replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _matchCase(String original, String replacement) {
    if (original.toUpperCase() == original) {
      return replacement.toUpperCase();
    }
    if (original.isNotEmpty &&
        original[0].toUpperCase() == original[0] &&
        original.substring(1).toLowerCase() == original.substring(1)) {
      return '${replacement[0].toUpperCase()}${replacement.substring(1)}';
    }
    return replacement;
  }

  static String _lettersOnly(String text) =>
      text.replaceAll(RegExp(r'[^A-Za-z]'), '').toLowerCase();

  static String _errorSummary(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final body = _responseBodyText(error);
      return 'DioException status=$status message=${error.message} body=$body';
    }
    return error.toString();
  }

  static int? _statusCode(Object error, String summary) {
    if (error is DioException) {
      return error.response?.statusCode;
    }
    final match =
        RegExp(r'\b(?:HTTP|status=)\s*(\d{3})\b', caseSensitive: false)
            .firstMatch(summary);
    return match == null ? null : int.tryParse(match.group(1) ?? '');
  }

  static String _extractErrorCode(Object error, String summary) {
    final data = error is DioException ? error.response?.data : null;
    if (data is Map) {
      final code = data['code'] ??
          data['error_code'] ??
          data['errorCode'] ??
          (data['error'] is Map ? (data['error'] as Map)['code'] : null);
      if (code != null) {
        return code.toString();
      }
    }
    final lower = summary.toLowerCase();
    if (lower.contains('green net') || summary.contains('绿网')) {
      return 'green_net';
    }
    final match = RegExp(
      r'\b(SensitiveContentDetected|InputTextRiskDetection|audit_content_risky|content_risk)\b',
      caseSensitive: false,
    ).firstMatch(summary);
    return match?.group(1) ?? '';
  }

  static String _responseBodyText(Object error) {
    if (error is! DioException) {
      return '';
    }
    final data = error.response?.data;
    if (data == null) {
      return '';
    }
    if (data is String) {
      return data;
    }
    return data.toString();
  }

  static bool _looksLikeParameterOrAuthError(String lower) {
    const parameterKeywords = [
      'invalidparameter',
      'invalid parameter',
      'parameter',
      'image size',
      'resource',
      'speaker',
      'api key',
      'apikey',
      'unauthorized',
      'auth',
      'permission',
      'quota',
      'rate limit',
    ];
    return parameterKeywords.any((keyword) => lower.contains(keyword));
  }

  static String _shorten(String text, int maxLength) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength).trim()}...';
  }

  static Future<String> _defaultReportDirectory() async {
    final dbDir = path_lib.normalize(await DatabaseService.databaseDirectory);
    final parts = path_lib.split(dbDir);
    final dartToolIndex = parts.lastIndexOf('.dart_tool');
    final root = dartToolIndex > 0
        ? path_lib.joinAll(parts.sublist(0, dartToolIndex))
        : Directory.current.path;
    return path_lib.join(root, 'data', 'content_safety');
  }

  static String _timestampForFile() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

class _ReplacementPair {
  const _ReplacementPair({
    required this.sourceTerm,
    required this.replacement,
  });

  final String sourceTerm;
  final String replacement;
}
