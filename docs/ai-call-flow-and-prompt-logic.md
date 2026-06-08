# AI 调用流程与提示词生成逻辑审核稿

本文档描述当前 App 中所有会触发云端 AI/语音/图片能力的入口、调用前置条件、缓存策略和提示词生成逻辑。目标是方便审核“什么时候会花费 API 调用”“提示词是否符合产品目标”“是否存在可本地处理却误调用 AI 的情况”。

## 总原则

- Web UI 不直接调用云 API，只通过 `web_bridge_protocol.dart` / `bridge.ts` 把命令发给 Flutter。
- 所有可计费云调用都必须先查本地数据或持久缓存，只有本地无法确定且缓存未命中时才请求远程。
- 只缓存成功的真实远程结果；API Key、请求 Header、失败响应、异常文本、mock fallback 都不入缓存。
- 缓存 key 由规范化后的请求 JSON 或音频字节 SHA-256 生成，必须包含模型、资源 ID、声音、尺寸、输出格式、prompt policy version 等会影响结果的字段。
- 标准中英对照故事必须本地解析直用，不允许整篇送 AI 做英文提取。
- 新增文章页默认生成一张章节绘本图；绘本图是一篇文章/一章一图，不再按段落或句子生成多图。

## 密钥与配置来源

| 能力 | 读取入口 | 文件/配置 |
| --- | --- | --- |
| 方舟文本生成 | `AppConfig.volcArkTextApiKey` | `ark.txt` / `TOMATO_VOLC_ARK_API_KEY` / secure storage |
| 方舟图片生成 | `AppConfig.volcArkImageApiKey` | `ark.txt` / `TOMATO_VOLC_ARK_API_KEY` / secure storage |
| TTS / Realtime / BigASR | `AppConfig.volcSpeechApiKey` | `speech-api-key.txt` |
| 图片模型 | `AppConfig` / env | 默认 `doubao-seedream-5-0-260128` |
| 图片尺寸 | `VolcImageService` env | 远程默认 `2560x1440`，本地显示按 16:9 缩放 |

## 调用矩阵

| 场景 | 本地优先逻辑 | 远程服务 | cachePurpose / kind | 输出 |
| --- | --- | --- | --- | --- |
| 新增文章正文处理 | `PracticeInputParser` 判定纯英文/标准中英对照直接使用 | 方舟文本 | `translate_to_english_practice` / `ark_text` | 英文练习正文 |
| 自动标题 | 用户标题 > 本地英文标题候选 > 本地 fallback | 方舟文本 | `suggest_article_title` / `ark_text` | 2-5 词英文标题 |
| 中文对照 | 导入时保存的 `article_sentence_translations` > 内存 Future cache | 方舟文本 | `follow_translation` / `listening_translation` / `chat_translation` | 简体中文翻译 |
| 单词释义 | 规范化单词与句子，缓存命中直接返回 | 方舟文本 | `word_lookup` / `ark_text` | JSON: 拼写、音标、含义、句中义 |
| 章节对话提纲 | 同一章节提纲缓存命中直接返回 | 方舟文本 | `chat_chapter_guide_v1` / `ark_text` | 紧凑教学提纲 |
| AI 对话 | 完整 turns 转 textQuery，但 turns 只包含提纲、进度和历史，不重复带全文 | Realtime V3 | `chat_start` / `chat_reply` / `realtime` | AI 英文回复 |
| 跟读/听力/对话朗读 | TTS 文件缓存命中直接播放 | Doubao TTS 2.0 | `follow_tts` / `listening_tts` / `chat_tts` / `word_pronunciation` / `voice_preview` / `tts` | MP3 文件 |
| 跟读/聊天识别 | 音频 SHA-256 缓存命中直接返回 | BigASR | `asr_recognize` / `asr` | 识别文本 |
| 跟读最近录音 | 读 `latest_sentence_recordings` | 无 | 独立表 + recordings 文件 | 最近录音、识别文本、评分 JSON |
| 绘本提示词润色 | 默认本地模板；只有 env 开启才远程润色 | 方舟文本 | `picture_book_page_prompt` / `ark_text` | 图片 prompt JSON |
| 绘本图片 | 图片文件缓存命中直接返回 | 方舟图片 | `picture_book_image` / file | 本地图片文件 |

## 新增文章保存流程

入口：`web_ui/src/App.tsx` 发送 `article.create`，Flutter 由 `WebShellScreen._handleArticleCreate` 处理。

1. 前端提交原始 `title`、`content`、`seriesId` 或 `seriesTitle`，并默认带 `pictureBookEnabled: true`。
2. Flutter 调用 `PracticeInputParser.parse(content)` 判断输入类型。
3. `parsed.usesLocalEnglish == true` 时直接使用 `parsed.englishContent`：
   - 纯英文：本地规范化空白、撇号、词内连字符。
   - 标准中英对照：本地提取英文原文，保留英文段落边界；中文译文进入 `article_sentence_translations`。
4. 只有本地不能可靠确定英文正文时，才调用 `PracticeTextService.translateToEnglishForPractice`：
   - 非标准中英混杂：提取英文故事原文。
   - 纯中文：翻译成适合练习的英文故事。
   - 长文本按约 8000 字符目标分块，全量处理，不截断前 1600/2200 字符。
5. `NlpService.splitSentences` 生成适合跟读的短语块。
6. 标题解析顺序：
   - 用户填写标题：直接规范化后使用。
   - 标准中英对照/本地解析得到标题候选：直接使用。
   - 仍为空：调用方舟生成短标题。
   - 方舟失败：用首句前几个英文词本地 fallback。
7. 保存文章、句子和导入中文对照。
8. 如果正文处理或标题生成在保存前已经调用过远程，保存后调用 `attachExistingCache` 把全局缓存引用绑定到新文章。
9. 默认创建/复用“书籍”系列与章节关系，然后后台 `PictureBookService.generateForArticle` 生成一张绘本图，不阻塞文章保存返回。

## 方舟文本生成统一层

入口：`TextGenerationService.generate`。

请求：

- endpoint: `https://ark.cn-beijing.volces.com/api/v3/chat/completions`
- body: `model`、`messages`、`max_tokens`、`stream:false`
- 鉴权：`Authorization: Bearer <ark key>`

缓存请求 JSON 包含：

- `service: ark_chat_completions`
- `endpoint`
- `model`
- `purpose`
- `maxTokens`
- `stream:false`
- `messages`

命中 `ApiCacheService.getText` 后直接返回 `TextGenerationReplySource.cached`。无 key 返回 `mockNoKey`，异常返回 `mockOnError`，两者不写入持久缓存。

提交前安全规则：

- `TextGenerationService.generate` 会先调用 `ContentSafetyService.prepareTextForApi`，把已启用的本地规则应用到每条 `messages.content`，再计算缓存 key 和提交远程。
- 规则只改变提交给方舟的 prompt/request 文本，不改变文章正文、字幕、跟读文本或数据库原文。
- 规则优先使用连字符或空格拆分，例如 `heads -> he-ads`、`beheaded -> be-headed`；避免使用 `*`，因为语音链路可能把星号读出来。
- 远程返回疑似安全拒绝时，记录 `content_safety_failures`，但不缓存 fallback。
- 用户修改后同一用途提交成功时，程序比较失败文本和成功文本，只把明显的词级拆分学习到 `content_safety_rules`。整句改写不泛化成规则。
- 正式运行不做二分探测或反复试探敏感词；无法自动定位时提示用户修改后重试。
- 排查 live API 的 400 时，第一步先排除测试环境问题：`flutter_test` 会默认拦截 `HttpClient` 并可能让网络请求表现为空 body HTTP 400；沙箱网络限制也可能造成类似假象。只有确认 `HttpOverrides.global = null`、网络权限/沙箱授权正常、API Key 已真实读取后，才可以把 400 作为远程接口错误分析。
- 空 body 的 HTTP 400 不能直接写成“敏感词拒绝”。若它来自测试环境拦截，不得写入 `content_safety_failures`，也不得用后续成功结果反向学习敏感词规则。

## 文本类提示词

### 1. 英文到中文

用途：跟读字幕、听力字幕、聊天翻译。

系统约束：

```text
You are a precise English-to-Chinese translation engine.
Return only natural Simplified Chinese. Do not explain.
```

用户内容：

```text
Translate this English learning text into natural Simplified Chinese.
Keep names readable and return only the translation:

<英文文本>
```

前置节省逻辑：

- 如果传入已经是纯中文，直接返回。
- 跟读/听力如果 `article_sentence_translations` 有导入译文，优先使用导入译文，不再调用方舟。
- `TranslationService` 还有进程内 Future cache，避免同一轮 UI 中重复请求。

### 2. 中英混杂提取英文原文

触发：输入含英文且含中文，但不能被本地识别为标准中英对照。

系统约束：

```text
You extract original English story prose from mixed Chinese-English learning material.
Keep only the English story text in original order.
Remove Chinese translations, explanations, vocabulary notes, headings, page labels, metadata, and teacher instructions.
Do not translate Chinese into new story text.
Return only English prose.
```

用户内容：

```text
Extract the English story original from this mixed learning text.
Return only the English story prose, with normal spacing and punctuation:

<混杂文本>
```

注意：

- 标准中英对照不走这个 prompt。
- fallback 是本地启发式提取英文行。

### 3. 纯中文转英文练习文

触发：输入含中文且本地没有可用英文正文。

系统约束：

```text
You translate Chinese story text into clear natural English for children speaking practice.
Return only the English article. Use short, speakable sentences. Do not explain.
```

用户内容：

```text
Translate this Chinese learning story into English practice text.
Keep the meaning, use natural English, and return only English:

<中文故事>
```

### 4. 自动标题

触发：用户没有填写标题，且本地没有标题候选。

系统约束：

```text
You create short English titles for children English practice tasks.
Return only the title, 2 to 5 words, title case.
Keep necessary apostrophes such as Mother's.
Do not add trailing punctuation.
```

用户内容：

```text
Create one short English title for this article. Return only the title:

<正文前 1600 字符>
```

清洗逻辑：

- 去掉包裹引号和多余标点。
- 修正普通标题大小写。
- 保留必要撇号，避免 `Mothers` 这类所有格丢失问题。

### 5. 单词释义

触发：跟读/听力字幕中的英文单词被点击。

系统约束：

```text
You are a concise English vocabulary helper for Chinese-speaking children.
Return only valid compact JSON with keys word, phonetic, meaning, sentenceMeaning.
Use Simplified Chinese for meaning and sentenceMeaning.
Phonetic should be IPA when possible.
```

用户内容：

```text
Word: <word>
Sentence: <sentence>
Return JSON only.
meaning is the common Chinese meanings.
sentenceMeaning is the meaning of this word in this exact sentence.
```

返回 JSON 被解析为：

- `word`
- `phonetic`
- `meaning`
- `sentenceMeaning`

同时单词发音走 TTS，`cachePurpose: word_pronunciation`。

## AI 对话提示词

入口：

- `ChatChapterGuideService.prepareGuide`：把完整章节英文正文提交给方舟一次，让方舟按场景、事件、冲突、角色决定和结尾自然切分并生成可复用的紧凑教学提纲；结果通过 `TextGenerationService` / `ApiCacheService` 持久缓存。
- `RealtimeVoiceService`：使用火山 Realtime V3 文本 query 模式，后续只带教学提纲、进度判断指令和对话历史，不再重复提交完整章节原文。

### 章节提纲生成

远程语义切分：

- 方舟输入使用完整章节正文，不再使用固定 8 条本地均分提纲作为远程输入。
- 方舟自己根据故事内容决定 `Ordered coverage points` 数量：短章节可 3-5 条，普通章节常见 6-10 条，长章节最多可到 14 条。
- 切分依据应是自然场景、事件、冲突、角色决定和结尾变化，不是固定句数或固定段数。
- 程序本地 `buildLocalGuide` 仍保留“最多 8 条”均分覆盖点，但只作为无 key/远程失败 fallback，不能代表远程语义切分结果。
- 提交方舟前，由 `ContentSafetyService` 按已验证/已学习规则做词级拆分，例如 `heads -> he-ads`。

方舟文本生成 prompt：

```text
[SYSTEM] You analyze complete English story chapters and create compact teaching guides for speaking practice.
Return only a concise English guide, not JSON and not the full chapter.
Include these exact sections: Chapter summary, Ordered coverage points,
Character and setting facts, Completion rubric, Ability assessment cues.
Keep the guide short enough to reuse in every chat turn.
Choose the number of Ordered coverage points from the story structure itself.
Do not use a fixed count.

[USER] Chapter title: <文章标题>

Complete chapter text:
<完整章节英文正文>

Create a compact reusable conversation guide from this complete chapter.
Decide the Ordered coverage points by semantic story structure, not by a fixed sentence count.
Coverage points must follow the chapter order and cover the whole chapter, including the ending and meaning.
Prefer short phrases over long quotations.
```

缓存请求包含应用安全规则后的完整章节正文、模型、`maxTokens: 1400` 和 `cachePurpose: chat_chapter_guide_v1`。同一章节命中缓存后，打开对话不再调用方舟生成提纲，也不再重复提交完整章节。缺 key 或失败时使用本地 fallback 提纲，本地 fallback 不写入远程结果缓存；疑似安全失败另写入 `content_safety_failures`。

全局系统角色：

```text
You are a friendly and encouraging English teacher named Emma.
Use the cached compact chapter teaching guide as the source.
Ask one question at a time and keep each response concise.
Guide the learner through the chapter from beginning to end.
When the learner has discussed the main events, ending, and meaning of the chapter, stop asking new questions and give a short practice summary plus an English ability level.
Every assistant response must end with metadata lines:
[[TOMATO_CHAPTER_DONE: yes/no]]
[[TOMATO_ABILITY_LEVEL: Starter|Beginner|Elementary|Pre-Intermediate|Intermediate|Upper-Intermediate]]
[[TOMATO_SUMMARY: one short summary when done, otherwise empty]]
```

打开对话时构造 turns：

```text
[SYSTEM] <全局系统角色>
[USER] Chapter title: <文章标题>

Cached compact teaching guide:
<章节教学提纲>

Conversation goal: help the learner understand and retell the whole chapter...
[USER] Please greet me briefly and ask your first question about the beginning of this chapter.
```

后续回复：

- `_history` 保存全局系统角色、章节教学提纲、前面 AI/用户消息。
- 每次用户文本或 ASR 结果追加为 `[USER] <userMessage>`。
- 正常轮次追加结束判断指令：

```text
Decide whether the learner has now discussed the chapter beginning, key events, ending, and meaning.
If yes, finish with a practice summary and ability level.
If no, ask exactly one next question about an uncovered part.
```

- 8 个 AI 回合作为兜底上限。到上限时追加：

```text
This is the final turn. If any chapter part is still uncovered, briefly cover it now.
Then end the practice with a summary, an ability level, and TOMATO_CHAPTER_DONE: yes.
```

`_buildTextQuery` 把 turns 展开为：

```text
[ROLE] content
[ROLE] content
...
```

缓存请求包含 `service: realtime_dialogue`、endpoint、resourceId、model、purpose、完整 `textQuery`。同一篇文章同一上下文命中缓存时不再开 Realtime WebSocket。

Flutter Provider 会解析并移除 `[[TOMATO_*]]` 元数据标记：

- `TOMATO_CHAPTER_DONE: yes`：把 `ChatStep` 置为 `completed`，停止继续提问。
- `TOMATO_ABILITY_LEVEL`：写入 `ChatState.abilityLevel`。
- `TOMATO_SUMMARY`：写入 `ChatState.practiceSummary`。
- 聊天气泡只显示自然语言回复，不显示元数据标记。

## 绘本生成流程

入口：`PictureBookService.generateForArticle`。

当前策略：

- 正常只生成一个 `PictureBookPage`：
  - `pageIndex = 0`
  - `sentenceStartIndex = 0`
  - `sentenceEndIndex = 最后一句`
  - `paragraphText = 清理后的完整章节英文原文`
- 如果已有页面符合当前 `chapter_single_image_v1` 策略且状态是 ready/skipped/error，不重复生成。
- 如果发现旧的多页策略缓存，会删除旧页并按单图策略重建。

### 章节故事文本构造

1. 用空行拆英文段落。
2. 过滤中文译文、过短标题行、章节/episode 元信息。
3. 对每个英文段落只合并多余空白，保留段落顺序。
4. 不再按前 950 / 中间 700 / 结尾 750 字符抽样，不插入 `[middle of chapter]` / `[end of chapter]` 标记。
5. 如果段落过滤后为空，退回使用 `sentences.join(' ')` 的完整英文句子文本。

### 默认本地 prompt JSON

默认不开启方舟文本润色。`_buildPagePrompt` 生成本地 JSON：

- `scene`: 章节级绘本图说明。
- `characters`: 从当前章节文本中提取的通用英文专名，不再硬编码 Alice 角色。
- `prompt`: 青少年儿童英语绘本风格 + 书名 + 章节名 + 整章故事 + 自然文字策略 + 安全改写策略。
- `negativePrompt`: 安全底线。
- `continuityGuide`: 根据书名、系列 bible、前章摘要和当前章节推断角色/时代/服装/地点，不固化任何单本书。
- `chapterTitle`
- `chapterStoryText`
- `safeChapterStoryText`
- `promptPolicyVersion: chapter_single_image_v1`

### 可选 AI prompt 润色

只有显式启用：

```text
TOMATO_PICTURE_BOOK_AI_PAGE_PROMPTS=true
```

才调用方舟文本生成图片 prompt JSON。

系统约束：

```text
You write image prompts for single chapter-level English picture-book illustrations for teens and children.
Return only valid compact JSON with keys scene, characters, prompt, negativePrompt.
The image prompt must be visual, concrete, safe, and based on the whole chapter, not one sentence.
Visible text is allowed when it naturally belongs in the scene...
If the source is a classic story with severe royal threats or comic panic,
adapt it into harmless theatrical emotion and keep every character safe and whole.
```

用户内容包括：

- series title
- style guide JSON
- story bible JSON
- continuity guide
- natural text policy
- safe classic story adaptation rule
- chapter order/title
- safe chapter story content

末尾要求：

```text
Create one chapter-level 16:9 illustration prompt that summarizes this chapter
with the correct book, setting, characters, mood, and central action.
Prioritize the current chapter content over unrelated characters or locations from earlier chapters.
Prefer timeless storybook settings over modern classrooms unless the chapter explicitly requires a modern setting.
Return JSON only.
```

### 最终图片 prompt 拼装

`_imagePromptFrom` 把 prompt JSON 拼成最终给图片模型的文本，核心结构：

```text
Create one 16:9 English picture-book chapter illustration for an app.
This is a single image for the whole chapter, not a per-sentence panel.

BOOK TITLE / SERIES TITLE: <书名>.
Use this title to keep the story world, recurring characters, tone, and chapter continuity accurate.

STORY CONTEXT: This is one illustrated chapter image from the book or story series "<书名>"...

CONTINUITY GUIDE: Use the book title "<书名>", the saved series bible, previous chapter summaries,
and the current chapter story to infer recurring characters, era, costumes, props, locations...

SCENE GUARD: The setting must come from the current "<书名>" chapter title and story content first...

NATURAL TEXT POLICY: visible text is allowed when it naturally belongs...

SAFETY ADAPTATION FOR CLASSIC STORY NONSENSE: reinterpret severe royal threats...

<prompt JSON 中的 prompt>

Style: <styleGuide>
Audience: teens and children learning English.
Use the book title, chapter title, and current chapter story as the priority...
Do not import unrelated characters or locations from earlier chapters unless...
The app overlays subtitles separately...
```

审核重点：

- 模板不包含 Alice/Wonderland 特例。
- 书名会进入 prompt，但不会把任意书籍强行改写成某个固定 IP。
- 当前章节内容优先于历史章节，避免角色/场景串章。
- 自然文字允许出现，但不能成为理解画面的唯一方式。

### 图片生成与缓存

优先顺序：

1. 如果 `volcArkImageApiKey` 存在，调用方舟 `/api/v3/images/generations`。
2. 如果没有方舟 Bearer key，标记 `skippedNoKey`，不写成功缓存，也不再尝试旧 Visual / AK-SK 图片接口。

方舟图片缓存请求包含：

- endpoint/model/size/response_format/output_format/watermark
- sequential_image_generation 是否启用
- prompt
- prompt_metadata
- series_id/page_index
- reference_image_hashes

返回 URL 或 base64 后立即下载/保存到 `tomato_api_cache/picture_book/`，后续页面只读本地文件。

图片 prompt 提交前同样走 `ContentSafetyService.prepareTextForApi`。疑似安全拒绝记录失败快照；但图片尺寸、参数、鉴权、额度等 400 错误不能当作敏感词规则学习。

### 组图与参考图

默认关闭：

- `TOMATO_VOLC_IMAGE_GROUP_PAGES=false`
- `TOMATO_PICTURE_BOOK_REFERENCE_IMAGES=false`

开启组图时 `_groupPrompt` 会要求：

```text
Generate exactly N separate 16:9 English picture-book illustrations as a coherent visual sequence.
Keep the same book title, character appearances, costumes, color palette, and picture-book style across all images.
Use any reference images only for character and style consistency...
```

当前正式流程不依赖组图，因为产品已经改为每章一张图。

## TTS 调用逻辑

入口：`TtsService.synthesizeToCachedFile`。

用途：

- 跟读原音：`follow_tts`
- 听力播放：`listening_tts`
- 对话 AI 朗读：`chat_tts`
- 单词发音：`word_pronunciation`
- 声音预览：`voice_preview`

缓存请求包含：

- service: `doubao_tts_2`
- endpoint: `/api/v3/tts/unidirectional`
- resourceId
- speaker
- normalized text
- audio format: mp3
- sampleRate: 24000

文本规范化：

- 提交 TTS 前先调用 `ContentSafetyService.prepareTextForApi`，使用本地已验证/已学习规则拆分可能触发安全拒绝的词，例如 `heads -> he-ads`。这只影响送给语音引擎的文本，不修改文章原文或字幕。
- 合并空白。
- 修复词内连字符：`well - known` -> `well-known`。
- 去掉标点前多余空格。
- 如果中英混杂导致 TTS 返回空音频，可重试一个英文可读 fallback。
- 如果套用规则后仍然返回 400 或安全类失败，记录到 `content_safety_failures` 并提示失败原因，不再继续自动猜测。

缓存命中时直接返回本地 MP3 路径，不再请求 TTS。

## ASR 与跟读评分

入口：

- 文件式识别：`StreamingAsrService.recognize`
- 跟读实时识别：`StreamingAsrService.recognizeLive`
- 评分：`RecognitionBasedAssessmentEngine`

文件式识别缓存请求包含：

- service: `bigasr`
- endpoint: `bigmodel_nostream`
- audioFormat: wav
- sampleRate: 16000
- bits: 16
- channel: 1
- language: en-US
- audioHash: SHA-256(audioBytes)

跟读流程：

1. 录音时启动 PCM 16k mono stream。
2. 实时 ASR 尝试显示当前识别文本。
3. 停止录音后把 PCM 包成 WAV。
4. 如果实时识别已有结果，直接评分；否则调用文件式 BigASR。
5. 评分结果、最近一次录音和识别文本保存到 `latest_sentence_recordings`。
6. 重启后同一句可恢复“播放录音”和上次评分。

## 听力/跟读/单词弹窗交互中的暂停恢复

- 单词弹窗打开前，前端会请求暂停当前听力或跟读播放。
- 弹窗打开后：
  - `word.lookup` 获取词义。
  - `word.play` 播放单词 TTS。
- 弹窗关闭后恢复被暂停的背景音频。
- 单词 TTS 也走同一套 TTS 持久缓存。

## 数据清理与文章删除

删除文章时应清理：

- 文章行、学习记录。
- `article_sentence_translations`。
- `picture_book_pages` 中该文章独占图片页。
- `latest_sentence_recordings` 行及录音文件。
- `api_cache_article_refs` 中该文章引用。
- 只有没有其它文章引用的缓存文件才删除，避免误删共享 TTS/图片/文本结果。

不会跟随文章删除的全局缓存：

- 声音预览。
- 多文章共享的 TTS。
- 多文章共享的文本/图片结果。

## 审核关注点

建议重点审核以下问题：

1. 标准中英对照是否所有路径都能本地解析，避免调用方舟提取英文。
2. `pictureBookEnabled` 在正式 UI 中是否始终默认 true，内部测试才允许 false。
3. 绘本 prompt 是否足够强调书名和当前章节，但没有固化 Alice 或其它单本书。
4. 标题 prompt 是否满足短标题和所有格要求。
5. 单词释义 JSON 是否足够稳定，失败 fallback 是否可接受。
6. TTS cache key 是否覆盖 speaker/resourceId/text，避免换音色串缓存。
7. 图片 cache key 是否覆盖 model/size/prompt/policy/reference hash，避免换模型或提示词后误命中旧图。
8. 失败、mock、缺 key 场景是否不会污染缓存。
9. 删除文章时是否只删除独占缓存，不破坏共享文件。
