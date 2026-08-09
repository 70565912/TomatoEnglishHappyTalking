import 'dart:convert';

import 'orthographic_sentence_boundary_v3.dart';
import 'read_aloud_splitter_v3.dart';

typedef UdpipeRawPipelineProviderV3 = Future<String> Function({
  required String text,
  required bool presegmented,
});

class UdpipeRawPipelineResultV3 {
  const UdpipeRawPipelineResultV3({
    required this.document,
    required this.rawSentenceCount,
    required this.orthographicBoundaryReparse,
  });

  final DependencyDocumentV3 document;
  final int rawSentenceCount;
  final bool orthographicBoundaryReparse;
}

/// Pure-Dart UDPipe decoding and orthographic-boundary verification pipeline.
///
/// Production, tests, and read-only corpus tools call this same implementation.
/// The caller supplies only the native parse transport, so this file has no
/// Flutter, platform-channel, asset, database, or logging dependency.
class UdpipeRawPipelineV3 {
  const UdpipeRawPipelineV3._();

  static const parserVersion = 'udpipe-1.4.0';

  static Future<UdpipeRawPipelineResultV3> parse({
    required String source,
    required String parserVersion,
    required String modelSha256,
    required UdpipeRawPipelineProviderV3 provider,
  }) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('UDPipe 句法分析正文不能为空');
    }
    final rawFirstPass = await provider(
      text: trimmed,
      presegmented: false,
    );
    final firstPassDocument = decodeDocument(
      trimmed,
      rawFirstPass,
      parserVersion: parserVersion,
      modelSha256: modelSha256,
    );
    final provisionalRanges = OrthographicSentenceBoundaryV3.resolve(
      source: trimmed,
      document: firstPassDocument,
    );
    final provisional = await _parsePresegmented(
      source: trimmed,
      ranges: provisionalRanges,
      parserVersion: parserVersion,
      modelSha256: modelSha256,
      provider: provider,
    );
    final verifiedRanges = OrthographicSentenceBoundaryV3.resolve(
      source: trimmed,
      document: provisional,
      requireVerifiedQuoteAttribution: true,
    );
    final didReparse = !_sameRanges(provisionalRanges, verifiedRanges);
    final document = didReparse
        ? await _parsePresegmented(
            source: trimmed,
            ranges: verifiedRanges,
            parserVersion: parserVersion,
            modelSha256: modelSha256,
            provider: provider,
          )
        : provisional;
    return UdpipeRawPipelineResultV3(
      document: document,
      rawSentenceCount: firstPassDocument.sentences.length,
      orthographicBoundaryReparse: didReparse,
    );
  }

  static Future<DependencyDocumentV3> _parsePresegmented({
    required String source,
    required List<OrthographicSentenceRangeV3> ranges,
    required String parserVersion,
    required String modelSha256,
    required UdpipeRawPipelineProviderV3 provider,
  }) async {
    if (ranges.isEmpty) {
      throw const FormatException('正字句边界解析未返回句子');
    }
    final synthetic = ranges
        .map((range) => range.textOf(source).replaceAll(RegExp(r'\s+'), ' '))
        .join('\n');
    final raw = await provider(text: synthetic, presegmented: true);
    final syntheticDocument = decodeDocument(
      synthetic,
      raw,
      parserVersion: parserVersion,
      modelSha256: modelSha256,
    );
    if (syntheticDocument.sentences.length != ranges.length) {
      throw FormatException(
        'UDPipe presegmented 句数不一致：expected=${ranges.length} '
        'actual=${syntheticDocument.sentences.length}',
      );
    }
    return remapDocumentToSource(
      source: source,
      document: syntheticDocument,
    );
  }

  static bool _sameRanges(
    List<OrthographicSentenceRangeV3> left,
    List<OrthographicSentenceRangeV3> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static DependencyDocumentV3 remapDocumentToSource({
    required String source,
    required DependencyDocumentV3 document,
  }) {
    var cursor = 0;
    final sentences = <DependencySentenceV3>[];
    for (var sentenceIndex = 0;
        sentenceIndex < document.sentences.length;
        sentenceIndex += 1) {
      final sentence = document.sentences[sentenceIndex];
      final tokens = <DependencyTokenV3>[];
      for (var tokenIndex = 0;
          tokenIndex < sentence.tokens.length;
          tokenIndex += 1) {
        final token = sentence.tokens[tokenIndex];
        final needle = token.sourceText ?? token.text;
        final start = source.indexOf(needle, cursor);
        if (start < 0) {
          throw FormatException(
            'UDPipe token 无法映射回原文：sentence=${sentenceIndex + 1} '
            'token=${tokenIndex + 1} text=$needle',
          );
        }
        final skipped = source.substring(cursor, start);
        if (skipped.isNotEmpty && skipped.trim().isNotEmpty) {
          throw FormatException(
            'UDPipe token 映射跳过了非空白原文：${jsonEncode(skipped)}',
          );
        }
        final end = start + needle.length;
        tokens.add(
          DependencyTokenV3(
            id: token.id,
            text: token.text,
            sourceText: source.substring(start, end),
            start: start,
            end: end,
            upos: token.upos,
            head: token.head,
            deprel: token.deprel,
          ),
        );
        cursor = end;
      }
      if (tokens.isEmpty) {
        throw FormatException('UDPipe 第 ${sentenceIndex + 1} 句没有可映射 token');
      }
      sentences.add(
        DependencySentenceV3(
          start: tokens.first.start,
          end: tokens.last.end,
          tokens: tokens,
          parseCost: sentence.parseCost,
          parseCostPerToken: sentence.parseCostPerToken,
        ),
      );
    }
    final trailing = source.substring(cursor);
    if (trailing.trim().isNotEmpty) {
      throw FormatException('UDPipe token 映射遗漏了原文尾部：${jsonEncode(trailing)}');
    }
    return DependencyDocumentV3(
      parserVersion: document.parserVersion,
      modelSha256: document.modelSha256,
      sentences: sentences,
      healthy: document.healthy,
      issues: document.issues,
    );
  }

  static DependencyDocumentV3 decodeDocument(
    String source,
    String raw, {
    required String parserVersion,
    required String modelSha256,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('UDPipe 原生插件未返回 JSON object');
    }
    final map = Map<String, dynamic>.from(decoded);
    final rawSentences = map['sentences'];
    if (rawSentences is! List || rawSentences.isEmpty) {
      throw const FormatException('UDPipe 原生插件未返回句子');
    }
    final sentences = <DependencySentenceV3>[];
    for (var sentenceIndex = 0;
        sentenceIndex < rawSentences.length;
        sentenceIndex += 1) {
      final rawSentence = rawSentences[sentenceIndex];
      if (rawSentence is! Map) {
        throw FormatException('UDPipe 第 ${sentenceIndex + 1} 个句子格式不正确');
      }
      final sentenceMap = Map<String, dynamic>.from(rawSentence);
      final rawTokens = sentenceMap['tokens'];
      if (rawTokens is! List || rawTokens.isEmpty) {
        throw FormatException('UDPipe 第 ${sentenceIndex + 1} 个句子没有 token');
      }
      sentences.add(
        DependencySentenceV3(
          start: _requiredInt(sentenceMap, 'start'),
          end: _requiredInt(sentenceMap, 'end'),
          parseCost: _optionalDouble(sentenceMap, 'parseCost'),
          parseCostPerToken: _optionalDouble(sentenceMap, 'parseCostPerToken'),
          tokens: [
            for (var tokenIndex = 0;
                tokenIndex < rawTokens.length;
                tokenIndex += 1)
              _decodeToken(
                rawTokens[tokenIndex],
                sentenceIndex: sentenceIndex,
                tokenIndex: tokenIndex,
              ),
          ],
        ),
      );
    }
    final issues = (map['issues'] as List?)
            ?.map((value) => value.toString())
            .where((value) => value.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    _validateDecodedOffsets(source, sentences);
    return DependencyDocumentV3(
      parserVersion: map['parserVersion']?.toString().trim().isNotEmpty == true
          ? map['parserVersion'].toString().trim()
          : parserVersion,
      modelSha256: modelSha256,
      sentences: sentences,
      healthy: map['healthy'] == true && issues.isEmpty,
      issues: issues,
    );
  }

  static void _validateDecodedOffsets(
    String source,
    List<DependencySentenceV3> sentences,
  ) {
    var previousSentenceEnd = 0;
    var previousTokenEnd = 0;
    for (var sentenceIndex = 0;
        sentenceIndex < sentences.length;
        sentenceIndex += 1) {
      final sentence = sentences[sentenceIndex];
      if (sentence.start < previousSentenceEnd ||
          sentence.start < 0 ||
          sentence.end <= sentence.start ||
          sentence.end > source.length) {
        throw FormatException(
          'UDPipe 第 ${sentenceIndex + 1} 句 offset 非法或与前句重叠：'
          '${sentence.start}-${sentence.end}',
        );
      }
      for (var tokenIndex = 0;
          tokenIndex < sentence.tokens.length;
          tokenIndex += 1) {
        final token = sentence.tokens[tokenIndex];
        if (token.start < previousTokenEnd ||
            token.start < sentence.start ||
            token.end <= token.start ||
            token.end > sentence.end) {
          throw FormatException(
            'UDPipe 第 ${sentenceIndex + 1} 句第 ${tokenIndex + 1} 个 token '
            'offset 非法或重叠：${token.start}-${token.end}',
          );
        }
        final sourceText = source.substring(token.start, token.end);
        if (sourceText != (token.sourceText ?? token.text)) {
          throw FormatException(
            'UDPipe 第 ${sentenceIndex + 1} 句第 ${tokenIndex + 1} 个 token '
            'offset 未对应原文',
          );
        }
        previousTokenEnd = token.end;
      }
      previousSentenceEnd = sentence.end;
    }
  }

  static DependencyTokenV3 _decodeToken(
    Object? raw, {
    required int sentenceIndex,
    required int tokenIndex,
  }) {
    if (raw is! Map) {
      throw FormatException(
        'UDPipe 第 ${sentenceIndex + 1} 句第 ${tokenIndex + 1} 个 token 格式不正确',
      );
    }
    final map = Map<String, dynamic>.from(raw);
    return DependencyTokenV3(
      id: _requiredInt(map, 'id'),
      text: _requiredString(map, 'text'),
      sourceText: _requiredString(map, 'sourceText'),
      start: _requiredInt(map, 'start'),
      end: _requiredInt(map, 'end'),
      upos: _requiredString(map, 'upos'),
      head: _requiredInt(map, 'head'),
      deprel: _requiredString(map, 'deprel'),
    );
  }

  static int _requiredInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw FormatException('UDPipe $key 必须是整数');
  }

  static double? _optionalDouble(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is num && value.isFinite) return value.toDouble();
    final parsed = double.tryParse(value.toString());
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  static String _requiredString(Map<String, dynamic> map, String key) {
    final value = map[key]?.toString() ?? '';
    if (value.isEmpty) {
      throw FormatException('UDPipe $key 不能为空');
    }
    return value;
  }
}
