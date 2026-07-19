# 歌曲字幕时间线设计

本文记录给本地歌曲版本生成字幕时间线的方案。最初落地对象是 Suno 下载歌曲；现在同一套 `SongSubtitleTimelineService` 也用于阿里云百聆、ElevenLabs Music 和外部导入音频。目标是在听力页播放歌曲时，按歌曲进度切换版本自己的歌词字幕（英文或中文）；后续也可导出同名 SRT/VTT，用于歌曲版绘本视频。

## 当前落地状态（2026-07）

- `SongSubtitleTimelineService` 已负责生成和缓存 `song-subtitle-timelines/*.json`，缓存 key 包含 `audioHash`、`lyricsHash` 和 ASR 请求参数（含 `language`）。
- ASR 语言由 `lyricsAsrLanguage` / `containsCjkText` 自动判定：歌词含 CJK 汉字时用 `zh-CN`，否则 `en-US`。中文歌词按字级 token（`[\u3400-\u9FFF\uF900-\uFAFF]`）与 ASR 字/词时间对齐；英文仍按词级与缩写展开规则。
- 含 CJK 的时间轴必须走火山 BigASR（`show_utterances` 词级时间）；当前 `ai_provider` 为阿里云时直接失败并提示切换火山，不调用百炼 ASR。
- 行级对齐使用**单次全局单调 DP（Needleman–Wunsch）**：把全部歌词 token 拍平成一条序列，与 ASR 词流做一次全局最优对齐，再折回每行。相比旧的贪心逐行游标，重复短语（如 "said the Caterpillar"）不会再跳到远处的重复出现导致“弱锚级联”（某行拉长几十秒、尾部若干行塌缩成零点几秒）。
- 已移除 `alignmentVersion` 版本位与“版本过旧”闸门。timeline 是否可用只看文件是否存在且含 cue（`timelineFileIsCurrent`）；算法升级后不再自动作废旧缓存，需要时由用户重新生成对应歌曲字幕。
- `StreamingAsrService.recognizeWithTimeline` 接受 `language`，火山路径开启 `show_utterances=true` 获取词级时间；ASR 结果只作为时间锚点，前端展示文本仍来自原歌词。
- 听力页歌曲弹窗中，每个本地歌曲版本可触发“生成歌曲字幕”；生成完成后版本 payload 会带 `timelinePath`、`timelineStatus`、`timelineConfidence`。
- 歌曲播放时 native 通过 `listening.song.position` 推送当前 cue，Web UI 用 cue 更新绘本字幕和当前句索引。
- 歌曲版视频通过 `listening.songRecordVideo` 导出，复用歌曲音频、字幕时间轴和绘本页，未生成 `timelinePath` 时录制按钮保持不可用。
- 歌曲版视频的字幕模式与听力视频一致：无内置字幕视频 + SRT、内置字幕视频、两版视频 + SRT。完成结果用 `videoVariants` 区分 `srt` 和 `subtitled` 两类产物。
- 歌曲版本可通过 `listening.songExportAudio` 单独复制音频到程序目录 `recording-export/`，不依赖 timeline。
- 诊断命令 `diagnostics.songAsrSnapshot` 会把一次真实 ASR 词级结果保存到程序目录 `diagnostics/`；`diagnostics.songTimelineFromAsrSnapshot` 可从该快照重建 timeline，用于复现和回归对齐问题。
- Suno 下载音频和 metadata 默认保存到程序目录 `suno-music/`；阿里云百聆和 ElevenLabs Music 也保存 provider metadata 并作为同一文章的本地歌曲版本参与播放、字幕和导出。旧 `.tmp` / 系统临时目录资产会迁移到持久目录，避免重新发布或系统清理后丢失。

## 目标

- 字幕文本必须使用该歌曲版本 metadata 中的 `submittedLyrics`，不使用 ASR 改写后的文本。
- 字幕时间来自实际下载歌曲，尽量贴合歌曲节奏。
- 允许歌曲中存在哼唱、前奏、间奏或拖长音。
- 字幕行之间可以首尾相接，不要求在哼唱处留空白。
- v1 追求逐行/逐句同步，不追求卡拉 OK 级逐词高亮。

## 前提

Suno 下载歌曲的强假设：

- Suno 不改词。
- Suno 不重复歌词行。
- Suno 不删句。
- Suno 可能在歌词之间加入哼唱、拖音、前奏或间奏。

这个前提很关键：我们可以把问题建模为“已知原歌词，对歌曲音频做强制时间对齐”，而不是“从歌曲重新生成字幕”。阿里云百聆和 ElevenLabs Music 也使用版本自己的 `submittedLyrics` 作为展示文本；如果供应商演唱内容与提交歌词不完全一致，ASR 仍只提供时间锚点，不会把识别文本写回歌词、文章或字幕正文。

## 核心原则

原歌词是唯一展示文本，ASR 只提供时间锚点。

```text
原歌词行 -> App 展示的字幕文本
ASR words -> 每个发音片段的大致时间
对齐算法 -> 把 ASR 时间投影到原歌词行
```

即使 ASR 把 `queen` 听成 `green`，前端也仍然显示原歌词里的 `queen`。ASR 识别文本不直接进入字幕 UI，也不覆盖文章句子和数据库正文。

## 输入与输出

输入：

- `articleId`
- 本地歌曲音频文件路径（Suno / 阿里云百聆 / ElevenLabs Music / 外部导入）
- 原歌词文本，优先使用版本 metadata 中的 `submittedLyrics`；如果版本元数据里暂未保存歌词，则可由当前听力句子按行重新构造
- 可选中文翻译，用于后续双语 SRT

输出：

- `song_lyrics_timeline.json`
- 可选 `song_lyrics.srt` / `song_lyrics.vtt`

建议 JSON 结构：

```json
{
  "version": 1,
  "articleId": 24,
  "audioHash": "sha256...",
  "lyricsHash": "sha256...",
  "durationMs": 128430,
  "source": "suno",
  "cues": [
    {
      "lineIndex": 0,
      "startMs": 1840,
      "endMs": 5420,
      "english": "Alice stood beside the Queen.",
      "chinese": "爱丽丝站在王后旁边。",
      "confidence": 0.91,
      "method": "matched"
    },
    {
      "lineIndex": 1,
      "startMs": 5420,
      "endMs": 8970,
      "english": "The garden waited in the sun.",
      "chinese": "",
      "confidence": 0.72,
      "method": "interpolated"
    }
  ],
  "warnings": []
}
```

`method` 建议值：

- `matched`：本行有足够 ASR 锚点，时间直接来自识别结果。
- `partial`：本行只有局部 ASR 锚点，但缺失的前后歌词可按匹配词位置和歌词长度补齐。
- `interpolated`：本行没有足够锚点，但前后行可匹配，按词数/音节权重在中间区间推断。
- `estimated`：只有单侧锚点，按附近平均歌唱速度推断。
- `fallback`：整体识别或对齐质量不足，只能按总时长和行权重平均分配。

## 生成流程

1. 下载 Suno 音频成功后保存版本元数据。
2. 计算 `audioHash` 和 `lyricsHash`，先查本地缓存；命中则直接复用时间线。
3. 用程序目录下的 `ffmpeg.exe` 将音频转为 BigASR 友好的 `wav pcm_s16le 16000Hz mono`。
4. 按歌词语言选择 ASR `language`（`en-US` / `zh-CN`）；中文歌词且当前平台非火山时直接报错。调用 ASR（火山 BigASR 开启 `show_utterances: true`），读取 `utterances[].words[].start_time/end_time`。
5. 对原歌词和 ASR 词流做归一化与模糊发音相似度评分（CJK 按字、拉丁按词）。
6. 把全部歌词 token 拍平成一条序列，与 ASR 词流做一次**全局单调 DP 对齐**（歌词 token gap 与 ASR 词 gap 分别计费），得到每个歌词 token 的时间锚点。
7. 把 token 锚点折回每行：按覆盖率与平均相似度算 `confidence`，达到阈值的行取首/尾匹配词时间为 `matched`（缺前后 token 时为 `partial`）；纯括注行只有被完整演唱时才接受，否则退回 boundary。
8. 对未匹配行按前后锚点和歌唱速度插值；如果推断行被前后锚点挤得过短，按歌词权重重新分配局部窗口，保证字幕可读。
9. 后处理所有 cue，让字幕时间单调递增、首尾相接、无负时长。
10. 保存 `song_lyrics_timeline.json`，并在播放歌曲时随 `just_audio` position 更新当前字幕。

## 诊断快照流程

诊断快照用于保存一次真实 ASR 调用的词级结果，方便在不重复调用云服务的情况下复现对齐算法：

1. Web UI 或 QA 工具调用 `diagnostics.songAsrSnapshot`，payload 包含 `articleId` 和歌曲 `versionId`。
2. Native 按当前 ASR provider 判断是否可直接提交原音频；不支持原格式时转换为 `wav 16kHz mono` 后调用 `StreamingAsrService.recognizeWithTimeline`。
3. 结果写入 `<program-dir>/diagnostics/song-asr-article-<id>-<version>-<timestamp>.json`，其中包含 `audioHash`、提交格式、词级时间、ASR 原始结构和估算时长。
4. 调用 `diagnostics.songTimelineFromAsrSnapshot` 并传入 `asrSnapshotPath` 后，程序读取快照的 `words` 或 `asr.utterances[].words`，用当前歌词重建 timeline。
5. 快照导入生成的 timeline 仍写入正式 `song-subtitle-timelines/` 缓存，并更新当前歌曲版本的 `timelinePath`、`timelineStatus` 和 `timelineConfidence`。

注意：诊断快照只提供时间锚点。即使快照里的 ASR 文本与歌词不一致，也不能把 ASR 文本写回文章、歌词、字幕正文或翻译。

## ASR 请求建议

现有文档中 BigASR 支持 `show_utterances`，返回分句和词级时间：

- `docs/大模型流式语音识别API.md`
- `show_utterances`
- `utterances[].start_time`
- `utterances[].end_time`
- `utterances[].words[].start_time`
- `utterances[].words[].end_time`

建议新增 `StreamingAsrService.recognizeWithTimeline`，不要改变现有 `recognize` 的纯文本行为。

请求建议：

```json
{
  "audio": {
    "format": "wav",
    "rate": 16000,
    "bits": 16,
    "channel": 1,
    "language": "en-US"
  },
  "request": {
    "model_name": "bigmodel",
    "enable_itn": true,
    "enable_punc": false,
    "show_utterances": true
  }
}
```

`language` 由歌词自动选择：纯英文为 `en-US`，含 CJK 为 `zh-CN`（中文时间轴强制火山 BigASR）。`enable_punc` 对歌词对齐价值不大，v1 可以关闭，减少标点对 token 归一化的干扰。若后续发现英文歌曲识别需要保留标点辅助分句，可以在缓存 key 中加入该选项，避免混用不同识别结果。

## 归一化规则

歌词和 ASR token 都做同一套归一化：

- 拉丁词转小写；CJK 字保持原形（比对时不依赖大小写）。
- 去掉首尾标点。
- 统一智能引号和普通撇号。
- 分词：拉丁匹配 `[A-Za-z0-9\-']+`，CJK 匹配汉字字符范围；同一行可中英混排，各自按规则产出 token。
- 拆常见英文缩写：`don't -> do not`、`I'm -> i am`、`we're -> we are`（CJK token 不做缩写展开）。
- 保留词内连字符的可比形式：`well-known` 同时产生 `wellknown`、`well`、`known` 候选。
- 去掉很弱的填充词候选，例如孤立的 `oh`、`ah`、`la` 可以低权重处理，但不要全局删除，因为歌词可能本来就包含这些词。

每个歌词行还应计算一个 `singingWeight`：

- 优先用英文音节估算。
- 没有音节估算时退回词数；CJK 行按字数计权。
- 长元音词、重复字母、破折号拉长词可稍微增权。

`singingWeight` 用于缺失行插值，比单纯按字符数稳定。

## 模糊匹配规则

对每个原歌词 token 和 ASR token 计算相似度：

- 完全相同：高分。
- 词干相近：中高分，例如 `waiting` / `wait`。
- 编辑距离较近：中分，例如 `beside` / `besides`。
- 发音近似：中分，例如 `queen` / `green`、`night` / `light`。
- 首尾辅音接近且元音弱化后接近：中低分。
- 常见弱读或连读：中低分，例如 `going to` / `gonna`、`want to` / `wanna`。

匹配必须满足顺序约束：第 N 行的匹配位置必须在第 N-1 行之后。全局 DP 对齐天然保证这一点——它对整条 token/词序列求单调最优，不需要靠逐行游标硬性前推。

## 行级对齐

采用**全局单调 DP（Needleman–Wunsch）+ 折回每行**：

### 阶段一：全局 token 对齐

把所有歌词行的 token 按顺序拍平成一条序列（纯括注行也进入序列，能唱到才会被接受），与 ASR 词流做一次全局最优对齐：

- 对角线：把一个歌词 token 与一个 ASR 词对齐，得分 = 相似度减去偏置（相似度高于偏置得正分、低于则负分）。
- 向下（歌词 token gap）：该歌词 token 没被唱到 / 没被识别，计一个较大的负惩罚。
- 向左（ASR 词 gap）：多出来的 ASR 词（前奏、拖音、即兴、重复），计一个很小的负惩罚。

因为是全局最优，一行想匹配到远处的重复短语，必须把中间所有 token 和词都 gap 掉，代价太高而被淘汰。这从根上避免了旧贪心游标的“弱锚级联”。

回溯对齐路径，记录每个歌词 token 对应的 ASR 词下标（相似度不足则视为未对齐）。

### 阶段二：折回每行并判定

按拍平顺序把 token 锚点归回各自的行：

- 覆盖率 = 该行被对齐的 token 数 / 该行 token 数；`confidence = 覆盖率*0.62 + 平均相似度*0.38`。
- 达到 `_lineConfidenceThresholdForCount` 阈值的行取首/尾匹配词的 `start_time`/`end_time`；缺失行首或行尾 token 时标 `partial`，其余为 `matched`。
- 纯括注行（舞台提示）需被从头到尾清晰唱出才接受，否则退回 boundary，避免偷走相邻行的锚点。
- 未达阈值的普通行留空，进入阶段三插值。

因为每个 ASR 词至多对齐一个歌词 token，行与行的匹配区间天然不重叠、单调递增。

### 阶段三：补齐缺失行

如果某行没有可靠锚点，但前后行都有锚点：

```text
gapStart = previousCue.endMs
gapEnd = nextCue.startMs
gapDuration = gapEnd - gapStart
```

把中间连续缺失行按 `singingWeight` 分配这个区间。

示例：

```text
第 10 行 matched: 00:30.000 - 00:34.000
第 11 行 missing, weight 6
第 12 行 missing, weight 4
第 13 行 matched: 00:44.000 - 00:48.000

中间区间 00:34.000 - 00:44.000 共 10 秒
第 11 行占 6 / (6 + 4) = 6 秒
第 12 行占 4 / (6 + 4) = 4 秒
```

如果只有前侧锚点，则用前后已知 matched 行的平均 `msPerWeight` 向后估算。如果只有后侧锚点，则向前估算。两侧都没有时，整首歌按总时长和行权重平均分配，标记为 `fallback`。

## 哼唱与空白处理

不为哼唱生成独立字幕 cue。

后处理阶段把字幕做成连续时间线：

- `cue[i].endMs = cue[i + 1].startMs`，或者保留 50-120ms 的极短过渡。
- 如果前奏较长，第一句可以从第一个 matched token 开始；也可以从 0 开始显示第一句，产品上建议默认从第一个 matched token 开始。
- 如果中间有哼唱，哼唱时间自然被分配到前一句尾部、下一句头部或中间插值区间。
- 如果尾奏较长，最后一句可延长到音频结束，也可以在最后匹配词后一小段停止。产品上建议默认延长到歌曲结束，避免末尾黑屏感。

这个策略符合当前要求：字幕之间不留空白，不要求字幕切换点精确等于哼唱开始或结束。

## 置信度

每行输出 `confidence`，用于 UI 和调试：

- `0.85 - 1.00`：本行匹配可靠。
- `0.60 - 0.85`：可自动展示，但调试面板可提示“推断时间”。
- `< 0.60`：低置信，需要允许手动微调或重新生成时间线。

整首歌也应输出总体质量：

- matched 行占比。
- interpolated 行占比。
- 平均置信度。
- ASR 识别文本与原歌词的整体相似度。
- 是否使用 fallback。

## 播放同步

Flutter 侧：

- `listening.songPlay` 开始播放歌曲。
- `_playSongFile` 监听 `AudioPlayer.positionStream`。
- 每 100-250ms 推送一次 `listening.song.position`，包含 `positionMs`、`durationMs` 和当前 cue。
- 播放结束时推送 `listening.song.state` 回到 `ready`。

Web UI 侧：

- 接收 `listening.song.position`。
- 根据 `positionMs` 或 native 传来的 `cue` 更新当前字幕。
- 歌曲播放时可以复用听力页的绘本画面，但字幕来源切换为 `songTimeline.cues`。

事件草案：

```ts
interface ListeningSongPositionPayload {
  articleId: number;
  versionId?: string | null;
  positionMs: number;
  durationMs?: number | null;
  cue?: {
    lineIndex: number;
    startMs: number;
    endMs: number;
    english: string;
    chinese?: string;
    confidence: number;
    method: 'matched' | 'interpolated' | 'estimated' | 'fallback' | string;
  } | null;
}
```

诊断命令草案：

```ts
interface SongAsrSnapshotRequest {
  articleId: number;
  versionId: string;
}

interface SongAsrSnapshotResult {
  outputPath: string;
  outputDirectory: string;
  payload: Record<string, unknown>;
}

interface SongTimelineFromAsrSnapshotRequest {
  articleId: number;
  versionId: string;
  asrSnapshotPath: string;
}
```

## 缓存与成本

BigASR 调用会产生费用，必须缓存成功结果。

建议缓存键包含：

- `service: bigasr`（或当前 ASR provider 对应命名）
- `purpose: suno_song_subtitle_timeline_v1`
- `audioHash`
- `lyricsHash`
- `audioFormat: wav`
- `sampleRate: 16000`
- `language: en-US` 或 `zh-CN`（与歌词语言一致，进入缓存 key）
- `showUtterances: true`（火山路径；百炼路径对中文歌词直接拒绝）

缓存 key 不再包含 `alignmentVersion`。这意味着**升级对齐算法不会自动作废旧缓存**：同一 `audioHash` + `lyricsHash` 会命中旧结果。需要让已生成的歌曲用上新算法时，删除该歌曲的 `song-subtitle-timelines/*.json`（`ApiCacheService.getEntry` 会在文件缺失时自动清理对应 DB 记录）或在 App 内重新生成字幕即可。

只缓存成功的 ASR 时间线和对齐结果。失败、空结果、mock fallback 不写成功缓存。

如果同一首 Suno 歌曲已经有 `songUrl` 和本地音频版本，再次进入听力页应直接复用已生成的 timeline，不重新识别。

## 数据挂载

建议扩展 `ArticleSongVersion`：

```dart
class ArticleSongVersion {
  final String id;
  final String audioPath;
  final String? songUrl;
  final String? stylePrompt;
  final String? styleKey;
  final String? lyricsHash;
  final String? timelinePath;
  final double? timelineConfidence;
}
```

Suno metadata 按当前歌词的 `lyricsHash` / `contentHash` 恢复缓存组；timeline 是版本级数据，因为不同版本的歌唱节奏和哼唱长度可能不同。

## 失败处理

- 没有 BigASR key：歌曲仍可播放，但不显示歌曲同步字幕；提示“未配置语音识别，无法生成歌曲字幕时间线”。
- 中文歌词但当前 AI 平台为阿里云：直接失败，提示切换到火山引擎后再生成；不调用百炼 ASR。
- ffmpeg 缺失或转码失败：歌曲仍可播放，timeline 生成失败，提示重新发布程序或补齐 `ffmpeg.exe`。
- ASR 空结果：不缓存成功结果，可允许用户重试。
- 对齐质量低：生成 fallback timeline，但 UI 应显示低置信提示；调试日志记录 ASR 文本、匹配率和低置信行号。
- 歌词 hash 改变：旧 timeline 不复用，重新生成。
- 音频 hash 改变：旧 timeline 不复用，重新生成。

## 实现入口

建议新增：

- `app/lib/services/song_subtitle_timeline_service.dart`
- `StreamingAsrService.recognizeWithTimeline`
- `ArticleSongTimeline` / `ArticleSongCue` 数据模型
- `listening.songTimeline` bridge command
- `listening.song.position` native event

建议修改：

- `app/lib/services/minimax_music_service.dart`
  - `ArticleSongVersion` 增加 `lyricsHash`、`timelinePath`、`timelineConfidence`
- `app/lib/features/web_shell/web_shell_screen.dart`
  - Suno 下载成功后异步触发 timeline 生成
  - `listening.songState` 返回 timeline 状态
  - `_playSongFile` 推送播放 position
- `web_ui/src/types.ts`
  - 增加 song timeline / position 类型
- `web_ui/src/App.tsx`
  - 歌曲播放时展示 song timeline cue
  - 低置信 timeline 显示温和提示

## v1 验收标准

- 已下载 Suno 歌曲首次播放前或播放后可生成 timeline。
- timeline 命中缓存后二次播放不再调用 BigASR。
- 歌曲播放时字幕使用原歌词，不使用 ASR 文本。
- 有哼唱段时字幕不断档。
- 局部匹配行可标记 `partial`，并按缺失歌词长度补齐可读时长。
- 首尾或中间插值行不能被相邻 ASR 锚点挤压到不可读时长。
- 前后行匹配、中间行未匹配时，中间行能按时间长度和行权重插值。
- 可导出 SRT，时间单调递增，无重叠、无负时长。
- 可用 `diagnostics.songAsrSnapshot` 保存真实 ASR 结果，并用 `diagnostics.songTimelineFromAsrSnapshot` 在本地复现同一首歌的字幕对齐。
- 低置信情况有日志和 UI 提示，不静默伪装为精确同步。
