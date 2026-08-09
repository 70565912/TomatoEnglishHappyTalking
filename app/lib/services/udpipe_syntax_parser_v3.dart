import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path_lib;
import 'package:udpipe_parser_v3/udpipe_parser_v3.dart';

import '../core/logging/tomato_logger.dart';
import 'database_service.dart';
import 'read_aloud_splitter_v3.dart';
import 'udpipe_raw_pipeline_v3.dart';

typedef UdpipeParseOverrideV3 = Future<String> Function({
  required String text,
  required String modelPath,
  required bool presegmented,
});

typedef UdpipeRawParseProviderV3 = Future<String> Function({
  required String text,
  required bool presegmented,
});

class UdpipeSyntaxParserV3 implements ReadAloudSyntaxParserV3 {
  static const parserVersion = UdpipeRawPipelineV3.parserVersion;
  static const modelAssetPath =
      'assets/models/english-ewt-r2.18-udpipe-v1.4.0.model';
  static const modelFileName = 'english-ewt-r2.18-udpipe-v1.4.0.model';

  // Filled from the reproducibly trained project model. Keeping the expected
  // digest in code prevents an invisible model replacement under the same V3
  // cache identity.
  static const expectedModelSha256 =
      'b71fb73473bedbca575bfc927fceb0f6dd53f74493bb9c58a9e77bd28d24a71f';

  static final _modelInitialization = <String, Future<_ModelFileV3>>{};
  static UdpipeParseOverrideV3? _parseOverrideForTest;

  @visibleForTesting
  static void setParseOverrideForTest(UdpipeParseOverrideV3? override) {
    _parseOverrideForTest = override;
  }

  @visibleForTesting
  static DependencyDocumentV3 decodeDocumentForTest({
    required String source,
    required String raw,
    String modelSha256 = 'test-model-sha256',
  }) =>
      UdpipeRawPipelineV3.decodeDocument(
        source,
        raw,
        parserVersion: parserVersion,
        modelSha256: modelSha256,
      );

  @visibleForTesting
  static DependencyDocumentV3 remapDocumentToSourceForTest({
    required String source,
    required DependencyDocumentV3 document,
  }) =>
      UdpipeRawPipelineV3.remapDocumentToSource(
        source: source,
        document: document,
      );

  /// Runs the same multi-pass boundary pipeline without loading Flutter assets.
  ///
  /// Read-only corpus evaluators inject the checked-in native probe here. The
  /// App production path continues to use [parse], which verifies and loads the
  /// bundled model through the native plugin.
  static Future<DependencyDocumentV3> parseRawPipelineForEvaluation({
    required String source,
    required String modelSha256,
    required UdpipeRawParseProviderV3 provider,
  }) async {
    final result = await UdpipeRawPipelineV3.parse(
      source: source,
      parserVersion: parserVersion,
      modelSha256: modelSha256,
      provider: provider,
    );
    return result.document;
  }

  @visibleForTesting
  static Future<DependencyDocumentV3> parseRawPipelineForTest({
    required String source,
    required String modelSha256,
    required UdpipeRawParseProviderV3 provider,
  }) =>
      parseRawPipelineForEvaluation(
        source: source,
        modelSha256: modelSha256,
        provider: provider,
      );

  @override
  Future<DependencyDocumentV3> parse(String text) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const FormatException('UDPipe 句法分析正文不能为空');
    }
    final model = await _ensureModelFile();
    final override = _parseOverrideForTest;
    final stopwatch = Stopwatch()..start();
    try {
      final pipeline = await UdpipeRawPipelineV3.parse(
        source: source,
        parserVersion: parserVersion,
        modelSha256: model.sha256,
        provider: ({required text, required presegmented}) => _invokeParser(
          text: text,
          modelPath: model.path,
          presegmented: presegmented,
          override: override,
        ),
      );
      final document = pipeline.document;
      TomatoLogger.info(
        category: 'sentence_split',
        event: 'udpipe.parse_completed',
        data: {
          'parserVersion': document.parserVersion,
          'modelSha256': document.modelSha256,
          'sentenceCount': document.sentences.length,
          'rawSentenceCount': pipeline.rawSentenceCount,
          'orthographicBoundaryReparse': pipeline.orthographicBoundaryReparse,
          'tokenCount': document.sentences
              .fold<int>(0, (sum, sentence) => sum + sentence.tokens.length),
          'healthy': document.healthy,
          'issues': document.issues,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      return document;
    } catch (error, stackTrace) {
      TomatoLogger.error(
        category: 'sentence_split',
        event: 'udpipe.parse_failed',
        error: error,
        stackTrace: stackTrace,
        data: {
          'parserVersion': parserVersion,
          'modelSha256': model.sha256,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      rethrow;
    }
  }

  static Future<String> _invokeParser({
    required String text,
    required String modelPath,
    required bool presegmented,
    required UdpipeParseOverrideV3? override,
  }) async {
    if (override != null) {
      return override(
        text: text,
        modelPath: modelPath,
        presegmented: presegmented,
      );
    }
    final rootToken = RootIsolateToken.instance;
    if (rootToken == null) {
      return const UdpipeParserV3().parse(
        text: text,
        modelPath: modelPath,
        presegmented: presegmented,
      );
    }
    return Isolate.run(
      () => _parseOnBackgroundIsolate(
        rootToken: rootToken,
        text: text,
        modelPath: modelPath,
        presegmented: presegmented,
      ),
    );
  }

  static Future<String> _parseOnBackgroundIsolate({
    required RootIsolateToken rootToken,
    required String text,
    required String modelPath,
    required bool presegmented,
  }) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
    return const UdpipeParserV3().parse(
      text: text,
      modelPath: modelPath,
      presegmented: presegmented,
    );
  }

  static Future<_ModelFileV3> _ensureModelFile() async {
    final runtimeRoot = await DatabaseService.runtimeDataRoot;
    return _modelInitialization.putIfAbsent(
      runtimeRoot,
      () => _copyAndVerifyModel(runtimeRoot),
    );
  }

  static Future<_ModelFileV3> _copyAndVerifyModel(String runtimeRoot) async {
    final asset = await rootBundle.load(modelAssetPath);
    final bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    if (bytes.isEmpty) {
      throw const FormatException('随 App 打包的 UDPipe 模型为空');
    }
    final sha256 = await _sha256(bytes);
    if (sha256 != expectedModelSha256) {
      throw FormatException(
        'UDPipe 模型 SHA-256 校验失败：expected=$expectedModelSha256 actual=$sha256',
      );
    }
    final directory = Directory(
      path_lib.join(runtimeRoot, 'syntax-models'),
    );
    await directory.create(recursive: true);
    final modelFile = File(path_lib.join(directory.path, modelFileName));
    if (!await modelFile.exists() || await modelFile.length() != bytes.length) {
      await modelFile.writeAsBytes(bytes, flush: true);
    } else {
      final existing = await _sha256(await modelFile.readAsBytes());
      if (existing != sha256) {
        await modelFile.writeAsBytes(bytes, flush: true);
      }
    }
    return _ModelFileV3(path: modelFile.path, sha256: sha256);
  }

  static Future<String> _sha256(Uint8List bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class _ModelFileV3 {
  const _ModelFileV3({required this.path, required this.sha256});

  final String path;
  final String sha256;
}
