---
description: "Use when writing or modifying service classes (TtsService, ScoringService, AiService, NlpService, DatabaseService). Covers API call patterns, error handling, mock fallback, and security requirements for Volcano Engine TTS/AI and Azure Speech APIs."
applyTo: "app/lib/services/**/*.dart"
---

# Services 层编码规范

## 核心原则

- Services **只做 API 调用 / 数据处理**，不持有 UI 状态
- 返回值或抛出异常——不在 service 内 `showDialog`
- 每个 service **必须提供 mock fallback**，当 API Key 未配置时返回虚假数据而不是崩溃

## API Key 读取

所有 Key 通过 `AppConfig` 获取，**绝不**硬编码：

```dart
// ✅ 好
final apiKey = await AppConfig.instance.volcTtsToken;
if (apiKey == null) return _mockResult();   // fallback

// ❌ 禁止
const apiKey = 'Bearer sk-xxxxx';
```

## HTTP 调用（dio）

- 只用 `dio`，**不引入** `http`、`http_dio` 等其他库
- 超时设置：`connectTimeout: 10s`，`receiveTimeout: 30s`
- 在 `DioException` 里区分网络错误 vs 业务错误

```dart
final _dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 30),
));

Future<List<int>?> synthesize(String text) async {
  final token = await AppConfig.instance.volcTtsToken;
  if (token == null) return null;          // mock fallback

  try {
    final response = await _dio.post(
      'https://openspeech.bytedance.com/api/v1/tts',
      options: Options(headers: {'Authorization': 'Bearer $token'}),
      data: { /* ... */ },
    );
    return (response.data['data']['audio'] as String).toAudioBytes();
  } on DioException catch (e) {
    debugPrint('[TtsService] request failed: ${e.message}');
    return null;
  }
}
```

## 火山引擎 TTS API

- 端点：`https://openspeech.bytedance.com/api/v1/tts`
- 鉴权：Header `Authorization: Bearer <token>`，Body 携带 `appid`
- 返回 Base64 编码的 MP3，解码为 `List<int>` 后交给 `just_audio`

## 火山方舟 Doubao API

- 端点：`https://ark.cn-beijing.volces.com/api/v3/chat/completions`
- 格式兼容 OpenAI：`{"model": "doubao-pro-32k", "messages": [...]}`
- Header：`Authorization: Bearer <ark_api_key>`

## Azure Speech 发音评分 API

- 端点：`https://{region}.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1`
- 必须携带 Header：`Ocp-Apim-Subscription-Key`、`Pronunciation-Assessment`（Base64 JSON）
- 音频格式：WAV PCM 16kHz 16bit mono
- 返回 JSON 包含 `NBest[0].PronunciationAssessment` 对象

## Mock Fallback 模式

```dart
// 每个 public 方法顶部检查 Key，缺失时走 mock
Future<PronunciationResult> assess(Uint8List wav, String refText) async {
  final key = await AppConfig.instance.azureSpeechKey;
  if (key == null) return _mockResult(refText);

  // ... 真实 API 调用 ...
}

PronunciationResult _mockResult(String text) => PronunciationResult(
  overallScore: 85.0,
  words: text.split(' ').map((w) => WordResult(word: w, score: 85.0)).toList(),
);
```

## 数据库服务（sqflite）

- `DatabaseService` 单例，通过 `getInstance()` 获取
- 表名、列名用常量定义，避免散落字符串
- 所有写操作返回 `Future<void>` 或 `Future<int>` (rowId)
