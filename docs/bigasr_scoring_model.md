# BigASR 自建评分模型（Draft v1）

## 目标

- 用 BigASR 已公开可获得的数据，替代当前 Azure Pronunciation Assessment 的评分结构。
- 保留 `0-100` 分制，方便沿用现有排行榜、平均分、颜色区间和历史趋势展示。
- 不再伪装成“发音音素评测”，而是明确改为“识别驱动的跟读评估”。
- 让模型既能支持当前跟读 UI，又不会把未来实现绑死在 Azure 的字段语义上。

## 设计原则

- 只使用当前可实现的数据源：识别文本、词级时间戳、停顿时长、语速元数据、音量元数据。
- 不使用当前公开文档没有保证的数据：音素级评分、单词发音准确度、原生 prosody 分数。
- 总分可以保留，但子分项必须更名，避免沿用 Azure 特有语义。
- 逐词结果保留，但从“发音错误类型”改为“文本对齐状态”。

## 字段替换方案

| 当前 Azure 字段 | 新字段 | 新含义 | 数据来源 |
| ---- | ---- | ---- | ---- |
| `overallScore` | `overallScore` | BigASR 自建综合分，不再等同 Azure `PronScore` | 子分加权汇总 |
| `accuracyScore` | `textMatchScore` | 目标句与识别句的文本匹配质量 | 文本归一化 + 对齐 |
| `fluencyScore` | `pacingScore` | 整体语速是否落在合理区间、停顿是否顺畅 | 词级时间戳 + 语速 |
| `completenessScore` | `coverageScore` | 目标句中有多少内容被实际读到 | 对齐结果 |
| `prosodyScore` | `stabilityScore` | 节奏和音量是否稳定，不代表音高/重音评估 | 时间戳 + 音量元数据 |
| `words[].score` | `tokens[].matchScore` | 每个参考词的文本匹配得分 | 对齐结果 |
| `words[].errorType` | `tokens[].matchStatus` | `exact` / `nearMatch` / `missed` / `extra` | 对齐结果 |

## 新结果模型

### 建议类型名

- `PronunciationResult` -> `ReadingEvaluationResult`
- `WordScore` -> `ReadingTokenScore`

### 建议 Dart 结构

```dart
enum ReadingTokenStatus {
  exact,
  nearMatch,
  missed,
  extra,
}

class ReadingTokenScore {
  final String referenceToken;
  final String recognizedToken;
  final ReadingTokenStatus matchStatus;
  final double matchScore;
  final int? startMs;
  final int? endMs;
  final int? pauseAfterMs;

  const ReadingTokenScore({
    required this.referenceToken,
    required this.recognizedToken,
    required this.matchStatus,
    required this.matchScore,
    this.startMs,
    this.endMs,
    this.pauseAfterMs,
  });
}

class ReadingEvaluationResult {
  final double overallScore;
  final double textMatchScore;
  final double coverageScore;
  final double pacingScore;
  final double stabilityScore;
  final String referenceText;
  final String recognizedText;
  final int referenceTokenCount;
  final int exactMatchCount;
  final int nearMatchCount;
  final int missedCount;
  final int extraCount;
  final int durationMs;
  final double speechRateWpm;
  final int pauseCount;
  final int longPauseCount;
  final List<String> feedbackTags;
  final List<ReadingTokenScore> tokens;
  final bool isMock;

  const ReadingEvaluationResult({
    required this.overallScore,
    required this.textMatchScore,
    required this.coverageScore,
    required this.pacingScore,
    required this.stabilityScore,
    required this.referenceText,
    required this.recognizedText,
    required this.referenceTokenCount,
    required this.exactMatchCount,
    required this.nearMatchCount,
    required this.missedCount,
    required this.extraCount,
    required this.durationMs,
    required this.speechRateWpm,
    required this.pauseCount,
    required this.longPauseCount,
    required this.feedbackTags,
    required this.tokens,
    this.isMock = false,
  });
}
```

## 评分计算口径

### 1. 文本预处理

- `referenceText` 与 `recognizedText` 统一做归一化：
  - 转小写
  - 去除首尾空格
  - 去掉不影响朗读的标点
  - 连续空白折叠为单空格
- 按 token 切分，默认先按空格分词。
- 英文缩写和常见口语形式可以在后续通过归一化词典做增强，但不是 v1 必需项。

### 2. Token 对齐

- 以参考句 token 序列和识别结果 token 序列做动态规划对齐。
- v1 的 token 状态定义：
  - `exact`: 归一化后完全一致
  - `nearMatch`: 编辑距离较小，或允许的轻微词形变化
  - `missed`: 参考词未被读出
  - `extra`: 识别结果中多读出的词
- 建议的 token 分值：
  - `exact = 100`
  - `nearMatch = 70`
  - `missed = 0`
  - `extra = 0`

### 3. 子分项计算

#### `textMatchScore`

- 目标：衡量“读出来的内容和目标句有多像”。
- 建议公式：

```text
textMatchScore = clamp(
  (exactCount * 1.0 + nearMatchCount * 0.7 - extraCount * 0.15)
  / max(referenceTokenCount, 1)
  * 100,
  0,
  100,
)
```

- 特点：
  - 允许少量近似匹配得部分分
  - 对多读内容有轻微惩罚

#### `coverageScore`

- 目标：衡量“整句有多少被真正读到”。
- 建议公式：

```text
coverageScore = clamp(
  (exactCount + nearMatchCount) / max(referenceTokenCount, 1) * 100,
  0,
  100,
)
```

- 特点：
  - 如果只读了前半句但读得很准，`textMatchScore` 可以较高，`coverageScore` 会明显偏低

#### `pacingScore`

- 目标：衡量整体语速和停顿是否顺畅。
- v1 输入：
  - 总时长 `durationMs`
  - 识别 token 数
  - 词间停顿时长
  - BigASR 返回的语速元数据（若可取）
- 拆成两个中间量：
  - `tempoScore`: 语速是否落在目标区间
  - `pauseFlowScore`: 是否存在过多长停顿
- 建议权重：

```text
pacingScore = tempoScore * 0.6 + pauseFlowScore * 0.4
```

- v1 推荐区间：
  - `tempoScore` 的理想区间先按 `95-155 WPM` 设计
  - `longPause` 先按 `>= 900ms` 认定
- 注：阈值必须在真实录音样本上再校准，v1 先作为实现默认值。

#### `stabilityScore`

- 目标：替代 Azure `prosodyScore`，但只表达“节奏/音量稳定度”，不宣称能评估音高重音。
- v1 输入：
  - 每词时长波动
  - 词间停顿波动
  - BigASR 音量元数据（若可取）
- 建议中间量：
  - `rhythmStabilityScore`
  - `volumeStabilityScore`
- 建议权重：

```text
stabilityScore = rhythmStabilityScore * 0.7 + volumeStabilityScore * 0.3
```

- 如果当前接口拿不到稳定的音量元数据：

```text
stabilityScore = rhythmStabilityScore
```

### 4. 综合分

- 综合分保留 `overallScore`，方便和现有 UI、历史统计兼容。
- 但它的语义改为“识别驱动的跟读综合分”，不再宣称等同发音总分。
- v1 建议权重：

```text
overallScore =
  textMatchScore * 0.40 +
  coverageScore * 0.25 +
  pacingScore * 0.20 +
  stabilityScore * 0.15
```

- 设计理由：
  - 跟读任务最重要的是内容读对
  - 其次是整句有没有读完整
  - 节奏与稳定度重要，但权重不应高于内容正确性

## 反馈标签

除了分数，v1 建议生成面向 UI 的反馈标签：

- `missing_words`
- `extra_words`
- `too_fast`
- `too_slow`
- `long_pauses`
- `unstable_rhythm`
- `unstable_volume`

这些标签用于生成更诚实的提示文案，例如：

- “内容基本读对了，但后半句漏读较多”
- “语速偏快，停顿较少，建议放慢一点”
- “整体节奏可以，但音量波动较大”

## UI 替换建议

### 结果卡片

- 保留当前“大圆总分 + 4 条子分”的布局。
- 子分标签替换为：
  - `文本匹配`
  - `覆盖度`
  - `节奏`
  - `稳定度`

### 逐词展示

- 颜色逻辑从 `errorType` 改为 `matchStatus`：
  - `exact`: 绿色
  - `nearMatch`: 橙色
  - `missed`: 灰色 + 删除线
  - `extra`: 红色边框或红色标签

- 如有时间戳，可在后续扩展里展示：
  - 哪个词后停顿过长
  - 哪一段节奏不稳定

## 持久化模型替换建议

### 不建议继续沿用旧列名

- 不要把 BigASR 自建分数继续写进：
  - `accuracy_score`
  - `fluency_score`
  - `completeness_score`
  - `prosody_score`
- 这些名字会长期误导代码、报表和 UI。

### 建议的新 `LearningRecord` 字段

- 保留：
  - `overall_score`
  - `created_at`
  - `article_id`
  - `sentence`
- 替换为：
  - `text_match_score`
  - `coverage_score`
  - `pacing_score`
  - `stability_score`
- 新增建议字段：
  - `recognized_text`
  - `reference_token_count`
  - `exact_match_count`
  - `near_match_count`
  - `missed_count`
  - `extra_count`
  - `duration_ms`
  - `speech_rate_wpm`
  - `feedback_tags_json`
  - `token_details_json`

### 为什么建议保存 JSON 细节

- `token_details_json` 可以保存 token 级对齐结果、时间戳、停顿信息。
- 这样数据库主表保留核心统计列，同时避免为每个细节维度都建单独列。
- 对 v1 来说，这比引入新的明细表更轻量，也更适合当前本地 SQLite 结构。

## 与当前代码的直接映射

- `app/lib/services/scoring_service.dart`
  - `PronunciationResult` 应替换为 `ReadingEvaluationResult`
  - `WordScore` 应替换为 `ReadingTokenScore`
- `app/lib/shared/widgets/score_display_widget.dart`
  - 子分标签要从 Azure 语义切换到新四分模型
  - 逐词颜色要从 `errorType` 改为 `matchStatus`
- `app/lib/features/follow_read/providers/follow_read_provider.dart`
  - 存储学习记录时改写为新字段，不再保存 Azure 五分结构
- `app/lib/data/models/learning_record_model.dart`
  - 用新列名和 JSON 明细替换旧字段
- `app/lib/services/database_service.dart`
  - 数据库版本需要升级，并做 `learning_records` 表结构迁移

## 实施建议

### 第一阶段

- 先把 Dart 领域模型换成新命名和新字段。
- 保持 `overallScore` 这个顶层字段不变，减少 UI 结构震荡。

### 第二阶段

- 引入 BigASR 返回结果到“归一化 -> token 对齐 -> 指标计算”管线。
- 先实现 `textMatchScore`、`coverageScore`、`pacingScore`。
- `stabilityScore` 允许先做节奏稳定度版本，等音量元数据稳定后再增强。

### 第三阶段

- 升级 `LearningRecord` 和 SQLite schema。
- 更新结果卡片文案，避免继续使用“准确度/流利度/完整度/韵律”这些 Azure 风格命名。

## v1 明确不做的事

- 不做音素级发音准确率。
- 不做单词级 mispronunciation 判断。
- 不做真正意义上的 prosody / intonation 评分。
- 不宣称 BigASR 自建分数与 Azure Pronunciation Assessment 可直接对齐。

## 当前建议结论

- 这版模型适合作为 BigASR 替换 Azure 后的第一版可实现评分结构。
- 如果要尽快上线，推荐先实现：
  - `overallScore`
  - `textMatchScore`
  - `coverageScore`
  - `pacingScore`
  - `tokens[].matchStatus`
- `stabilityScore` 和音量相关诊断可以作为 v1.1 增强项。