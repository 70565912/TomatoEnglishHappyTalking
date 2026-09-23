# Gemini 接入任务计划

日期：2026-09-23。状态：计划已写，产品代码未改，本机 key 未在 Cloud Agent 中实测。

本文件给本地 Agent 执行。密钥只存在本机 `security/gemini.txt`（已由 `.gitignore` 排除）。不要把 key 贴进对话、提交、日志、测试 fixture、Bridge 或缓存。

## 1. 本地 Agent 怎么开工

在本机打开本仓库，新建本地 Agent（不要用 Cloud Agent 做带 key 的探测）。把下面这段作为第一条任务：

```text
按 docs/gemini_integration_task_plan.md 执行。先只做 T0：用本机 security/gemini.txt 做文本探测，不要打印 key，不要改产品代码。T0 结论写回该文档的「T0 记录」一节。T0 通过前不要开始 T1。
```

实施时必读：

- `AGENTS.md`
- `docs/agent_guides/cloud_service_configuration_rules.md`
- `docs/agent_guides/cloud_service_development_rules.md`
- `docs/agent_guides/feature_development_rules.md`
- `docs/ai-call-flow-and-prompt-logic.md`

官方能力以当前文档为准，不以旧注释为准：

- [Getting started](https://aistudio.google.com/docs/get-started)
- [OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)
- [Models](https://ai.google.dev/gemini-api/docs/models)

## 2. 已核对的现状

文本生成已经统一走 `TextGenerationService`：`POST {baseUrl}/chat/completions`，Bearer key，body 含 `model`、`messages`、`max_tokens`、`stream: false`，需要 JSON 时加 `response_format: {type: json_object}`。`AppConfig.openAiTextConfig` 只在 `aliyun_bailian` 与 `volcengine` 之间选择。`_normalizeAiProvider` 会把任何其他值折回百炼。

Gemini 文本可以用同一形态接入：

- Base URL：`https://generativelanguage.googleapis.com/v1beta/openai`
- 模型：`gemini-3.8-flash`
- 鉴权：`Authorization: Bearer <gemini api key>`

分句 AI 不是“当前文本 provider 都能上”。`PracticeTextService._validatedCandidateReviewModels` 只接受：

- `aliyun_bailian/qwen3.7-max`（P7）
- `volcengine/deepseek-v4-flash-ga-260731`（P8）

未验收的 provider/model 必须继续走本地确定性路径。

图片、TTS、ASR、歌曲各自有独立 provider 和协议，不能把 Chat Completions 响应当成图片、音频或识别结果。

## 3. 产品边界

后续实现保持这些边界：

- 单一 provider 失败后不静默改打另一家。
- 跟读评分继续用所选 ASR 的识别文本和 `RecognitionBasedAssessmentEngine`。
- 文章保存后的 `articles.sentences` 仍是听力、跟读、字幕、翻译、绘本、歌曲和导出的文本边界。
- 歌曲识别结果只做时间锚点，不写回文章、歌词或字幕正文。
- 设置页和 Bridge 只回传 key 的有无和 mask。
- 生产 Base URL 不交给 Web UI 编辑。
- 成功缓存只保存真实远程成功结果，cache key 带上 provider、模型、用途和影响输出的参数。
- Web UI 不直接调用 Gemini。

## 4. 能力分期

| 阶段 | 能力 | 判断 | 原因 |
|---|---|---|---|
| T0–T1 | 文本：练习英文、标题、翻译、单词释义、对话提纲、绘本简介与章节规划、AI 对话的文本回复 | 先做 | 已有 OpenAI 兼容文本层 |
| 不做进 T1 | 分句候选路径选择 | 保持本地路径 | 该模型对尚未进入验收名单 |
| T2 以后单独立项 | 绘本组图 | 新协议 | `gemini-3.1-flash-image` 能按文生图和 16:9 / 2K，没有万相/Seedream 那种最多 12 张的连续组图 |
| T2 以后单独立项 | 朗读 TTS | 新协议 | `gemini-3.1-flash-tts-preview` 输出音频，要单独确认 `just_audio` 能播的容器和固定声音 |
| T2 以后单独立项 | 跟读识别、字幕时间轴 | 新协议 | `gemini-3.5-transcribe` 有词级时间；实时要用 `gemini-3.5-transcribe-live`，不是现有 SAUC / DashScope socket |
| T2 以后单独立项 | 歌曲 | 新协议 | `lyria-3.5` 输出 MP3，同时可能生成歌词；必须能锁定已保存句子，不能改写正文 |
| 不接入 | Live 全双工、托管 Agent、Deep Research、代码执行、生视频、Embeddings | 无当前产品入口 | 文本对话继续“文本回复 + 现有 TTS” |

## 5. 任务

### T0 本机文本探测

只在有 `security/gemini.txt` 的本机执行。探测脚本放在 `tools/`，读 key 文件，支持纯 key 或 `GEMINI_API_KEY=` 前缀。标准输出只含 HTTP 状态、模型 id、耗时、输出长度和短摘要。不写成功缓存，不把响应正文里的密钥样例留下来。

探测三项：

1. `gemini-3.8-flash` 的 chat completions 能返回短文本。
2. `response_format: {type: json_object}` 时，`message.content` 是可解析 JSON。用单词释义同形字段：`word`、`phonetic`、`meaning`、`sentenceMeaning`。
3. 不发送百炼 `enable_thinking` 或方舟 `thinking: {type: disabled}`。记录 `message.content` 是否混入思考文本。Gemini 3 不能关闭 thinking；若内容不可解析，把原始结构摘要（字段名、长度，不含正文全文）写入 T0 记录，供 T1 决定解析规则。

T0 通过前不调用图片、TTS、转写或 Lyria。

验收：文档「T0 记录」写明日期、模型、三项是否通过、失败时的状态码和错误类型。未跑的项标为未验证。

### T1 文本 provider

T0 的 JSON 路径可用后再改产品代码。新增独立 provider id：`gemini`。

配置：

- secure storage：`gemini_api_key`，可选 `gemini_text_model`，默认 `gemini-3.8-flash`。
- Base URL 固定为 `https://generativelanguage.googleapis.com/v1beta/openai`，不进设置页。
- 启动时按 `AppConfig._seedElevenLabsKeyFromFile` 的祖先目录搜索方式读取 `security/gemini.txt`，写入 secure storage。文件不存在则保持已有配置，不报启动失败。
- `text_provider=gemini` 时，`openAiTextConfig` 使用上述 key、URL 和模型。
- `_normalizeAiProvider` 继续只接受百炼和方舟。文本、图片、TTS、ASR、歌曲分别归一化，避免把 `gemini` 误存成百炼，也避免图片或 ASR 因为不认识 `gemini` 被静默改道。
- 缺 key 时保留现有“未配置 API Key”错误，不返回假成功。

调用：

- 继续走 `TextGenerationService` 和现有 dio。
- `disableThinking` 对 Gemini 不附加百炼/方舟字段。按 T0 结论解析 `message.content`。
- 缓存 request JSON 带上 provider、base URL、model、purpose。

设置与协议：

- `web_ui/src/types.ts` 的文本 provider 联合类型增加 `gemini`。图片和 ASR 的联合类型先不增加。
- `web_bridge_protocol.dart`、`bridge.ts`、`web_shell_screen.dart` 同步保存/读取文本 provider 和 Gemini key。Bridge 只回 mask 和是否已配置。
- 设置页云服务区沿用“凭据 / 平台地址 / 模型与语音”分区。Gemini 只增加凭据行和文本模型候选，不展示 Base URL。
- 文本模型候选至少包含 `gemini-3.8-flash`。未经验证的模型名不要写进生产默认值。

明确不在 T1 修改：

- `_validatedCandidateReviewModels` 不加入 Gemini。`text_provider=gemini` 时，分句候选复核仍走本地路径。
- 不改图片、TTS、ASR、歌曲的正式请求。
- 不改 `articles.sentences` 的生成规则。

验收：

- 相关 Dart 测试覆盖：归一化不会把 `gemini` 折成百炼；`openAiTextConfig` 指向固定 URL 和默认模型；缺 key 抛出配置错误；有测试 override 时请求 body 含 `json_object` 且不含百炼/方舟 thinking 字段。
- Web UI `npm test` 覆盖 settings payload 的 provider 与 mask。
- `flutter analyze` 与相关 `flutter test`、`npm test`、`npm run build` 按改动范围执行。
- 本机再跑一次 T0 同形请求，确认设置保存后的正式链路。Cloud 环境没有 key 时，这一步标为未验证。

### T2 其余模态

T1 合并并在本机文本链路可用后，再为每一项单独开计划。每一项都要先有本机探针，确认响应容器和计费，再接入正式 service。

- 绘本：按分镜逐张调用 `gemini-3.1-flash-image`，保持第 N 张对应第 N 镜；不把一次请求伪装成万相连续组图。超过现有 12 张产品上限时仍拒绝 AI 出图。
- TTS：确认 `gemini-3.1-flash-tts-preview` 的音频容器和 voice 参数后，再在 `TtsService` 增加分支。
- ASR：词级时间接到现有 timeline 结果；实时识别单独评估 `gemini-3.5-transcribe-live`。评分引擎不改成远程评分。
- 歌曲：只有确认可以锁定已保存歌词时，才增加 `song_provider`。模型改写的歌词不写回文章。

## 6. T0 记录

未执行。Cloud Agent 工作区没有 `security/gemini.txt`。
