# AI 调用流程与提示词生成逻辑审核稿

本文档描述当前 App 中所有会触发云端 AI/语音/图片能力的入口、调用前置条件、缓存策略和提示词生成逻辑。目标是方便审核“什么时候会花费 API 调用”“提示词是否符合产品目标”“是否存在可本地处理却误调用 AI 的情况”。

## 总原则

- Web UI 不直接调用云 API，只通过 `web_bridge_protocol.dart` / `bridge.ts` 把命令发给 Flutter。
- 所有可计费云调用都必须先查本地数据或持久缓存，只有本地无法确定且缓存未命中时才请求远程。
- 只缓存成功的真实远程结果；API Key、请求 Header、失败响应、异常文本、mock fallback 都不入缓存。
- 缓存 key 由规范化后的请求 JSON 或音频字节 SHA-256 生成，必须包含模型、资源 ID、声音、尺寸、输出格式、prompt policy version 等会影响结果的字段。
- 标准中英对照故事必须本地解析直用，不允许整篇送 AI 做英文提取。
- 新增文章页保存后先打开绘本提示词审核；用户确认后才用一次顺序组图请求让第 N 张图对应第 N 个分镜。
- 所有 AI 文本、语音和图片提交都必须对应用户可见的明确操作；打开弹窗、保存草稿、读取状态或后台加载不得隐藏触发远程 AI。

## 密钥与配置来源

| 能力 | 读取入口 | 文件/配置 |
| --- | --- | --- |
| OpenAI-compatible 文本生成 | `AppConfig.textProvider` / `AppConfig.openAiTextConfig` | secure storage：`text_provider`；缺失时兼容读取旧 `ai_provider` |
| 图片生成 | `PictureBookImageService` / `AppConfig.imageProvider` | secure storage：`image_provider`；缺失时兼容读取旧 `ai_provider` |
| 语音合成 | `TtsService` / `AppConfig.ttsProvider` | secure storage：`tts_provider`；支持阿里云 CosyVoice、火山 Doubao TTS、ElevenLabs TTS |
| ElevenLabs | `AppConfig.elevenLabs*` | secure storage：`elevenlabs_api_key` 等；启动时可从 `security/elevenlabs.txt` 读取纯 key 或 `ELEVENLABS_API_KEY=...` 并写入 secure storage |
| 阿里云百聆（Fun-Music） | `AppConfig.aliyunBailianApiKey` / `AppConfig.aliyunBailianMusicModel` | secure storage：百炼 key 与音乐模型 |
| 歌曲生成 | `AppConfig.songGenerationProvider` | secure storage：`song_provider`；支持 Suno、阿里云百聆、ElevenLabs Music |
| ASR | `AppConfig.aiProvider` | 阿里云 Qwen-ASR 或火山 BigASR，仍沿用旧全局 provider |
| 图片模型 | `AppConfig` / env | 阿里云默认 `wan2.7-image-pro`，火山默认 `doubao-seedream-5-0-260128` |
| 图片尺寸 | `AppConfig` / `VolcImageService` env | 阿里云默认 `2K`；火山远程默认 `2560x1440`，本地显示按 16:9 缩放 |

### 按能力拆分 provider

- `ai_provider` 保留为旧设置兼容字段；新设置页按能力写入 `text_provider`、`image_provider`、`tts_provider` 和 `song_provider`。
- 文本处理只允许 `aliyun_bailian` / `volcengine`，用于标题、翻译、单词释义、对话提纲和绘本章节规划。
- 图片生成只允许 `aliyun_bailian` / `volcengine`，分别走阿里云万相和火山 Seedream。
- 语音合成允许 `aliyun_bailian` / `volcengine` / `elevenlabs`。ElevenLabs 不参与文本生成或图片生成。
- 歌曲生成允许 `suno` / `bailian_fun_music` / `elevenlabs_music`。Suno 仍是默认；ElevenLabs Music 不影响 Suno 下载检测规则。
- `settings.load.cloud` 返回 `aiProvider`、`textProvider`、`imageProvider`、`ttsProvider` 和 `elevenLabs` 配置状态；UI 只显示 key mask，不回传明文 key。
- `voiceCatalog.elevenLabs` 来自 ElevenLabs 在线声音列表，失败时返回空列表和展示错误；不会暴露 key。TTS 保存和试听 payload 使用 `ttsProvider`，旧 `aiProvider` payload 仍作为兼容 fallback。

## 调用矩阵

| 场景 | 本地优先逻辑 | 远程服务 | cachePurpose / kind | 输出 |
| --- | --- | --- | --- | --- |
| 新增文章正文处理 | `PracticeInputParser` 判定纯英文/标准中英对照直接使用 | OpenAI-compatible 文本 | `translate_to_english_practice` / `openai_text` | 英文练习正文 |
| 自动标题 | 用户标题 > 本地英文标题候选 > 本地 fallback | OpenAI-compatible 文本 | `suggest_article_title` / `openai_text` | 2-5 词英文标题 |
| 中文对照 | 导入时保存的 `article_sentence_translations` > 内存 Future cache | OpenAI-compatible 文本 | `follow_translation` / `listening_translation` / `chat_translation` | 简体中文翻译 |
| 单词释义 | 规范化单词与句子，缓存命中直接返回 | OpenAI-compatible 文本 | `word_lookup` / `openai_text` | JSON: 拼写、音标、含义、句中义 |
| 对话提纲 | 同一章节教学提纲缓存命中直接返回 | OpenAI-compatible 文本 | `chapter_dialogue_guide_v2` / `openai_text` | 8 个以内章节覆盖点 |
| AI 对话 | 完整 turns 转 textQuery，但 turns 只包含提纲、进度和历史，不重复带全文 | Realtime V3 | `chat_start` / `chat_reply` / `realtime` | AI 英文回复 |
| 跟读/听力/对话朗读 | TTS 文件缓存命中直接播放 | 当前 TTS provider：阿里云 CosyVoice、火山 Doubao TTS 2.0 或 ElevenLabs TTS | `follow_tts` / `listening_tts` / `chat_tts` / `word_pronunciation` / `voice_preview` / `tts` | MP3 文件 |
| 跟读/聊天识别 | 音频 SHA-256 缓存命中直接返回 | 当前云平台 ASR：阿里云 Qwen-ASR 或火山 BigASR | `asr_recognize` / `asr` | 识别文本 |
| 跟读最近录音 | 读 `latest_sentence_recordings` | 无 | 独立表 + recordings 文件 | 最近录音、识别文本、评分 JSON |
| 绘本提示词审核 | 打开时只读取本地持久化章节计划/章节描述；缺失时显示空草稿 | OpenAI-compatible 文本仅在用户点击刷新时调用 | `picture_book_chapter_scene_plan_v2` / `openai_text` | `chapterDescription`、`scenes[].sceneDescription`、group prompt |
| 绘本组图 | 图片文件缓存命中直接返回；失败页可整体重试 | 当前云平台图片：阿里云万相异步连续组图或火山 Seedream 顺序组图 | `picture_book_image_group` / file | 与分镜一一对应的本地图片文件 |
| 绘本缩略图 | 原图存在时本地缩放并持久缓存；列表页不拉整章原图 | 无远程调用 | `picture_book_thumbnails` / file | 640x360 内的 PNG 缩略图 data URI |
| 歌曲生成 | 本地歌曲版本或 provider 缓存命中直接返回 | Suno 网页自动化、阿里云百聆（Fun-Music）或 ElevenLabs Music | `suno_song` / `bailian_fun_music_song` / `elevenlabs_music_song` / file | 本地歌曲音频、`submittedLyrics` 与版本 metadata |

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
   - 仍为空：调用当前文本 provider 生成短标题。
   - 文本 provider 失败：用首句前几个英文词本地 fallback。
7. 保存文章、句子和导入中文对照。
8. 如果正文处理或标题生成在保存前已经调用过远程，保存后调用 `attachExistingCache` 把全局缓存引用绑定到新文章。
9. 默认创建/复用“书籍”系列与章节关系；保存返回后 Web UI 调用 `pictureBook.promptReview` 打开提示词审核弹窗，用户确认后才提交顺序组图生成。

### 绘本提示词审核手动触发规则

- `pictureBook.promptReview` 只读取本地持久化数据：有效 `picture_book_chapter_scene_plan_v2`、已保存的 `chapterDescription`，或带真实 `chapterDescription` 的旧页面 prompt。
- 新建文章没有章节描述时，审核框的 `chapterDescription` 显示为空；已有文章没有本地持久化描述时同样显示为空。
- 打开审核框不会调用文本 AI、图片 API，也不会从正文、标题、scene 摘要或旧 `summary` 本地拼接章节描述。
- 用户可在审核框中手动填写章节描述和分镜描述，或点击“自动生成章节规划”显式调用文本 AI 刷新 `chapterDescription` 与 `scenes[]`。
- `pictureBook.savePromptReview` 只保存当前可见草稿，不调用图片 API、不删除旧图；`pictureBook.confirmPromptReview` 才提交可见审核内容并触发顺序组图。

### 英文原文区本地提取规则

入口仍是 `PracticeInputParser.parse(content)`。这些规则用于“课程导读 + 英文原文 + 拓展讲解 + 文化卡片/生词好句”这类课程稿，目标是在本地提取真正的英文故事正文，避免把词汇、音标、例句或中文讲解带入文章正文和绘本分镜输入。

- 起点只认正文区标题：`英文原文`、`英语原文`、`英文故事`、`原文`。标题、日期、作者、难度、课程导读不进入正文。
- 终端学习材料是 hard stop：`【文化卡片】`、`生词好句`、`词汇/单词/例句`、`参考译文/翻译`、`练习/答案`，以及对应英文 `Vocabulary`、`Useful phrases`、`Translation`、`Exercises` 等标题之后的内容都不进入正文。
- 标准中英对照也使用同一类 hard stop：正文/译文配对开始后，遇到词汇、例句、文化卡片或练习区，直接停止配对，避免把学习材料写入 `article_sentence_translations`。
- `【拓展】`、`背景知识`、`补充说明`、`难句解析`、`文化注释`、`Teacher's Note` 等属于 soft interruption：先跳过讲解内容，但不会立刻结束整篇正文。
- soft interruption 后只有出现可信故事续接才恢复正文。散文续接通常是引号对话，或包含 `said/asked/thought/looked/went/came/appeared` 等叙事动词的英文句；看起来像英文说明标题的行继续跳过。
- 诗歌正文按通用形态判断，不按文章标题特判：如果已提取的正文呈现为连续短行诗歌，拓展说明后再次出现 2-12 个英文词的短行，可恢复为同一首诗；冒号提示后的缩进/引号诗行也按诗歌续接处理。
- 如果正文过短，或 soft interruption 后只看到疑似英文讲解而没有可靠故事续接，本地解析会放弃并返回 mixed，让后续文本 provider 走“中英混杂提取英文原文”路径。
- 这些规则不得写入单篇文章名、人物名或课程编号条件；新增样本应优先落到 `app/test/fixtures/` 并通过 `practice_input_parser_test.dart` 固化边界。

## OpenAI-compatible 文本生成统一层

入口：`TextGenerationService.generate`。

请求：

- endpoint: `AppConfig.openAiTextConfig.chatCompletionsEndpoint`，默认 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`，可切换火山方舟 `/api/v3/chat/completions`
- body: `model`、`messages`、`max_tokens`、`stream:false`
- 鉴权：`Authorization: Bearer <provider key>`

缓存请求 JSON 包含：

- `service: openai_chat_completions`
- `provider`
- `baseUrl`
- `endpoint`
- `model`
- `purpose`
- `maxTokens`
- `stream:false`
- `messages`

命中 `ApiCacheService.getText` 后直接返回 `TextGenerationReplySource.cached`。无 key 返回 `mockNoKey`，异常返回 `mockOnError`，两者不写入持久缓存。

提交前安全规则：

- `TextGenerationService.generate` 会先调用 `ContentSafetyService.prepareTextForApi`，把已启用的本地规则应用到每条 `messages.content`，再计算缓存 key 和提交远程。
- 规则只改变提交给文本 provider 的 prompt/request 文本，不改变文章正文、字幕、跟读文本或数据库原文。
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
- 跟读/听力如果 `article_sentence_translations` 有导入译文，优先使用导入译文，不再调用文本 provider。
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

- `ChatChapterGuideService.prepareGuide`：把完整章节英文句子提交给当前文本 provider，生成可复用的紧凑教学提纲；结果通过 `TextGenerationService` / `ApiCacheService` 持久缓存。
- `RealtimeVoiceService`：使用火山 Realtime V3 文本 query 模式，后续只带分镜提纲、进度判断指令和对话历史，不再重复提交完整章节原文。

### 对话提纲生成

远程提纲：

- 文本 provider 输入使用完整章节编号句子。
- 远程模型输出最多 8 个有序覆盖点，用于对话练习，不作为绘本分镜来源。
- 每个覆盖点只保留一行简短教学要点，覆盖开头、关键事件、结尾和含义。
- 程序本地 fallback 也生成最多 8 个覆盖点，只作为无 key/远程失败兜底。
- 提交文本 provider 前，由 `ContentSafetyService` 按已验证/已学习规则做词级拆分，例如 `heads -> he-ads`。

文本生成 prompt：

```text
[SYSTEM] Create a compact English conversation guide for one chapter.
Return plain text only. No markdown table. No JSON.

[USER] Book title: <书名>
Chapter title: <文章标题>

Numbered chapter sentences:
0. <sentence>
1. <sentence>
...

Write at most 8 ordered coverage points for a friendly English speaking practice.
Cover the beginning, important events, ending, and meaning.
```

缓存请求包含 provider、base URL、endpoint、应用安全规则后的完整章节句子、模型、`maxTokens: 900` 和 `cachePurpose: chapter_dialogue_guide_v2`。同一章节命中缓存后，打开对话直接复用这份提纲，不重复提交完整章节。缺 key 或失败时使用本地 fallback 提纲，本地 fallback 不写入远程结果缓存；疑似安全失败另写入 `content_safety_failures`。

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

入口：保存文章后先打开 `pictureBook.promptReview`；用户确认审核弹窗后，`pictureBook.confirmPromptReview` 才提交图片生成。`pictureBook.generate` / `pictureBook.retryPage` 兼容入口也只打开审核流程，不直接调用图片 API。`pictureBook.savePromptReview` 只保存审核草稿，不生成图片。

当前策略：

- 页面策略版本为 `picture_book_group_prompt_scene_description_v2`，章节图片计划缓存为 `picture_book_chapter_scene_plan_v2`。
- `story_series` 只保留 `title` 和 `description` 作为书籍层上下文；不再维护 `style_guide_json`、`bible_json`、角色卡或参考图。
- 打开审核框只读取本地持久化章节描述/章节计划；文本规划 API 只在用户点击“自动生成章节规划”时调用，让 AI 基于 `bookDescription`、完整章节正文和规则约束生成 `chapterDescription` 和 `scenes[]`。完整原文作为可画细节来源；输出描述必须基于原文，但移除直接引语、对话内容、歌词/喊话文本、内心独白原句和对话语义摘要；不要新增本地对话剔除器，也不要为去对话额外增加一次文本 AI 调用。
- 场景切分规则保持精简：先忽略直接引语、对话语义、歌词、喊话和内心独白内容，再按原始句子顺序构造 scene，把同一连续故事场景内的内容归入同一个 scene。同一连续故事场景指地点/时间、主要人物组和正在发生的事件/活动保持连续。只有场景发生实质变化时才开新 scene，例如地点/时间变化、人物组变化，或明确的非对话动作把故事推进到新的事件/活动；不要因为句子边界、对话轮次、提问、回答、谜语、争论、评价、玩笑、反应或情绪变化单独切分。对话、歌词、喊话和内心独白句只作为覆盖锚点并入周围故事场景；`chapterDescription` / `sceneDescription` 保留原文里的可见动作、反应、物件和状态，移除 speech/thought content，且不能用 `exchange`、`conversation`、`discuss`、`debate`、`ask`、`answer`、`question`、`reply`、`remark`、`riddle`、`argue`、`claim`、`mean`、`say`、`said`、`offer` 等词把被移除的对话语义写回描述。每个 scene 对应一张图片并按顺序覆盖完整句子范围，最多 12 个 scene。
- promptReview 不调用图片 API，不删除旧 `picture_book_pages` 或图片缓存。
- 重新打开绘本提示词审核时优先读取 `story_chapters.summary_json` 中的 `picture_book_chapter_scene_plan_v2`。如果 summary 缺失或 hash 不匹配，但旧 `picture_book_pages` 仍有完整 prompt scene 信息，则从页面记录恢复章节计划并写回 summary。
- 如果本地 summary 和页面记录都无法恢复，promptReview 仍先打开审核框：章节描述和分镜描述保持为空，只提供句子范围和原文片段供用户可视化编辑；用户可以手工填写，或在弹窗里显式刷新章节规划。这个入口不得因为缺少本地计划而静默提交远程文本生成。
- 无章节计划时的分镜行只是审核框占位行，不是章节场景规划：正文有多个段落时按段落生成占位分镜并最多保留 12 行；正文只有一个段落时按句子数生成，占位行数为 `min(12, sentenceCount)`；单段超过 12 句时按句子范围均分成 12 行。占位行的 `sceneDescription` 必须为空，不能本地伪造章节描述或分镜描述。
- 审核弹窗可刷新书籍简介，或同次刷新章节规划（`chapterDescription` + `scenes[]`）。`pictureBook.refreshPromptReview` 只更新审核草稿，不调用图片 API，不删除旧图。
- savePromptReview 使用用户编辑后的书籍简介、章节描述、分镜描述和 groupPrompt 更新审核草稿并保存书籍简介，不调用图片 API，不删除旧图，适合用户分步保存提示词。
- confirmPromptReview 的确认按钮文案为“保存提示词并生成组图”；它使用用户编辑后的书籍简介、章节描述、分镜描述和 groupPrompt，先保存审核后的章节场景计划，确认后才删除旧页/旧图片引用并提交顺序组图。提交期间 Web UI 使用 App 级 `AiBlockingOverlay` 显示预计超时倒计时，估算规则为 `max(180, 分镜数 × 150)` 秒、上限 2700 秒。

### 单页重生成与参考图

- 创作中心单页「重新生成」走 `pictureBook.pagePromptReview` → `pictureBook.confirmPagePromptReview`，只替换目标页，不删除其它页。
- 若已有 `ready` 且本地图片文件存在（含当前重生成页），审核弹窗在「单张生成 Prompt」下方展示可选参考图缩略图；默认预选最近邻 1 张，用户可 toggle 多选（至少 1 张、最多 14 张）。
- 确认时 bridge 提交 `referencePageIndexes`（按 `pageIndex` 升序）；Flutter 解析为 `referenceImagePaths` 传给图片 API。整章 `confirmPromptReview` 仍使用 `referenceImagePaths: []`。
- 单页 prompt 固定写 “Use the reference images only for visual consistency.”；`prompt_json` 持久化 `referencePageIndexes` 与首项 `referencePageIndex`。
- 没有可用参考图时，单页审核回退为整章 `promptReview(regenerate: true)`。

调优记录：2026-07-08 起，旧版 `compact`、`smallest complete scene set`、弱边界合并和叙述微阶段合并规则不再作为正式章节规划策略。正式规则收敛为两步：先去掉 speech/thought 内容对边界判断的影响，再按“同一连续故事场景归入同一 scene、场景实质变化才切分”划分句子范围；`chapterDescription` / `sceneDescription` 基于原文保留可见内容并移除对话、歌词、喊话和内心独白内容，同时不能用对话语义摘要词把被移除内容写回描述。E22 茶桌段回归重点：同一茶桌场景里的酒、礼貌、个人评价、谜语、反驳和沉默不能被拆成多张语义 scene，也不能写成 `exchange` / `conversation` / `riddle` / `remark` 等描述。

### 计划中的书籍角色数组流程

为避免书籍简介过长，后续目标是把“书籍视觉世界”和“角色外貌锚点”拆开：

- `story_series.description` 只保存短书籍简介：整体世界观、时代/地点氛围、画风、色彩和长期视觉基调。
- 书籍增加 `characters[]`：挂在书籍上的结构化角色数组，每项最少包含 `name` 和 `description`。
- 角色数组不是旧版 series Bible、角色卡或参考图开关；它只保存用户可编辑的角色名称和稳定外貌描述，用于跨章节保持一致。
- 书籍编辑弹窗展示 `characters[]`，用户可以新增、删除、修改角色名称和描述；点击保存才写入书籍，取消则不保存。
- 自动生成书籍简介时，AI 返回短 `bookDescription` 和 `characters[]`。返回内容只填入编辑表单或审核草稿，不直接永久写库。
- `bookDescription` 不再堆叠角色外貌；角色外貌进入 `characters[]`。

建议角色结构：

```json
{
  "bookDescription": "Short visual-world description.",
  "characters": [
    {
      "name": "Alice",
      "description": "young girl with blonde bob, black ribbon, blue pinafore over white blouse, white socks, black shoes"
    },
    {
      "name": "White Rabbit",
      "description": "tall white rabbit with pink eyes, red waistcoat, pocket watch"
    }
  ]
}
```

角色合并规则：

- 只收录会影响画面一致性的主要人物、动物角色、拟人角色或重要 recurring group。
- 临时物品、场景元素、一次性动作和普通背景群体不进入角色数组。
- 新角色先进入审核草稿，用户确认后才合并进书籍 `characters[]`，避免 AI 误识别污染整本书。
- 合并时按角色名称做基础去重；后续如果命中不稳定，再考虑增加 `aliases` 字段。

### 章节规划输入与角色边界

`chapterDescription` 和 `scenes[]` 在同一次章节规划调用中生成。当前实现只提供 `bookDescription`、章节正文和规则约束。角色数组方案落地后，章节规划输入改为：

- `bookDescription`：短书籍视觉世界描述，不承担角色外貌列表职责。
- `relevantCharacters[]`：程序从书籍 `characters[]` 中筛选出本章相关角色后传入。筛选方式先用章节正文、章节描述草稿和分镜描述草稿中的角色名匹配；未命中的角色不传，避免 prompt 随全书变长。
- 章节正文：当前章节完整故事内容。它作为可见细节来源完整提交给同一次章节规划 AI；AI 输出 `chapterDescription` 和 `sceneDescription` 时必须基于原文保留可见动作、物体、地点、姿态、位置关系、场景状态、人物关系和情绪表现，同时移除直接引语、对话内容、歌词/喊话文本、内心独白原句和对话语义摘要。
- 规则约束：字段结构、段落切分、角色描述边界、新角色识别和安全表达要求。

生成输出为章节计划 JSON：

- `chapterDescription`：只描述本章整体剧情、地点、氛围和连续动作。它可以使用 `relevantCharacters[]` 里的角色名作为上下文，但不要重复角色外貌、服装、发色等描述，也不要复述或概括对话、歌词、喊话、问答、谜语、争论、评价或内心独白。
- `scenes[]`：只做分镜场景描述，写场景、动作、物件、位置、构图、情绪和画面变化，并保留该句子范围内的原文可见内容。可以使用角色名，但不要反复写 `Alice (blonde bob, blue pinafore)` 或 `White Rabbit (red waistcoat, pocket watch)` 这类已在 `relevantCharacters[]` 中出现的外貌锚点；不要把对话内容、字幕式文字、内心独白原句或对话语义摘要写进 `sceneDescription`。同一连续故事场景内容归入同一 scene；场景实质变化才开启新 scene。
- `newCharacters[]`：本章正文中出现、但书籍角色数组没有覆盖的新视觉角色。每项包含 `name` 和 `description`。

角色信息边界：

- 已在 `relevantCharacters[]` 出现的角色外貌，只保留在角色数组。
- 本章首次出现、且书籍 `characters[]` 没有覆盖的新角色，写入 `newCharacters[]`，不塞进 `chapterDescription` 或每个 `sceneDescription`。
- `sceneDescription` 不承担角色外貌补全职责，避免每张图重复角色描述。

最终 `groupPrompt` 增加本章相关角色区块：短书籍简介、本章相关角色、章节描述和每个 `Image N` 的 `sceneDescription` 完整提交。

### 章节计划 JSON

文本规划返回严格 JSON：

```json
{
  "planKind": "picture_book_chapter_scene_plan_v2",
  "chapterDescription": "Detail-preserving chapter description for image context.",
  "scenes": [
    {
      "pageIndex": 0,
      "sentenceStartIndex": 0,
      "sentenceEndIndex": 2,
      "sceneDescription": "Detail-preserving visual scene description."
    }
  ],
  "newCharacters": [
    {
      "name": "Caterpillar",
      "description": "large blue-green caterpillar with expressive eyes, calm posture, and a rounded storybook silhouette"
    }
  ]
}
```

规则：

- 只认 `planKind == picture_book_chapter_scene_plan_v2` 且字段为 `chapterDescription` / `scenes[].sceneDescription` / `newCharacters[]`。
- `chapterDescription` 描述当前章节作为一组连续图片的整体剧情、地点、氛围和关键可见变化。
- `scenes[]` 是唯一分镜来源，字段只包含 `pageIndex`、句子范围和 `sceneDescription`。
- `sceneDescription` 只描述场景、动作、物件、位置、构图、情绪和画面变化；必须基于原文保留句子范围内的可见内容并移除对话/内心独白内容和对话语义摘要；同一连续故事场景内容合入同一 scene，场景实质变化才开启新 scene；可以使用角色名，但不得重复 `relevantCharacters[]` 已有的角色外貌、服装、发色、年龄或括号式角色描述。
- `newCharacters[]` 只包含本章新增且会影响画面一致性的角色，不包含临时物品、地点、动作或普通背景元素。
- 不输出 `title`、`story`、`visual`、`audience`、`safety`、`negativePrompt`、字幕留白、UI overlay、Bible patch、角色卡或参考图字段。
- 角色数组方案落地后，最终 `groupPrompt` 按审核后的短书籍简介、本章相关角色、章节描述和每张图的分镜描述完整拼装；不按场景数量压缩，也不设置词数或字符数截断。

### 审核弹窗

Web UI 展示并允许编辑：

- 书籍简介：写入 `story_series.description`，只承载时代、整体画风、世界观和视觉基调。
- 书籍角色列表：展示并编辑书籍 `characters[]`，每个角色有名称和外貌/视觉描述。
- `chapterDescription`
- 每个 scene 的 `sceneDescription`
- 本章新增角色 `newCharacters[]`：展示章节规划识别到的新角色，用户可修改、删除或补充；确认生成组图时才合并进书籍角色列表。
- 最终组图 `groupPrompt`

不再展示系列 Bible、旧角色卡、参考图开关、参考图列表、`styleGuide` JSON 或 `negativePrompt`。

### 最终组图 prompt

`PictureBookService` 按计划拼装五部分：

```text
Book name: <bookTitle>

Book description: <description>

Relevant characters:
- <name>: <description>

Chapter description: <chapterDescription>

Image 1:
Scene description: <sceneDescription>
```

最终提交规则：

- `Book name` 使用书籍名称，放在最前面。
- `Book description` 使用短书籍简介。
- `Relevant characters` 只包含本章出现的已确认书籍角色，以及本次审核确认后合并的新角色。
- `Chapter description` 和 `Scene description` 不重复角色外貌。
- 用户取消审核或只关闭弹窗时，不把 `newCharacters[]` 合并到书籍角色数组。

提示词卫生规则：如果旧缓存或用户手动输入里混入了“字幕留白 / app-rendered subtitles / blank lower band”等不需要的正向提示，代码只在源头清掉这些正向提示，不再自动补对应的“不要字幕/不要留白”负面提示。

### 绘本图片载入与缩略图

`pictureBook.state` 可以只返回页面 metadata，不携带整章 `imageUri`。Web UI 需要图片时再调用：

```json
{
  "type": "pictureBook.pageImage",
  "payload": {
    "articleId": 1,
    "pageIndex": 0,
    "variant": "thumbnail"
  }
}
```

- `variant: "thumbnail"`：从原图本地生成并缓存到 `picture_book_thumbnails/`，最大 640x360，适合书籍封面和创作中心网格。
- `variant: "full"` 或省略：返回原图 data URI，适合听力播放、全屏和导出前确认。
- 缩略图生成失败只影响列表预览，不应触发重新调用图片生成 API。

### 组图生成与缓存

优先顺序：

1. 如果 `volcArkImageApiKey` 存在，调用方舟 `/api/v3/images/generations`，并传 `sequential_image_generation: "auto"`。
2. 如果没有方舟 Bearer key，标记 `skippedNoKey`，不写成功缓存，也不再尝试旧 Visual / AK-SK 图片接口。

方舟图片缓存请求包含：

- endpoint/model/size/response_format/output_format/watermark
- `sequential_image_generation: "auto"`
- `sequential_image_generation_options.max_images = scenes.length`
- prompt
- prompt_metadata
- series_id/page_index

`PictureBookService` 调用 `generatePictureBookImageGroup(..., useSequential: true, reusePartialCache: false)`，一次请求生成整章分镜图。第 1 张图写入第 1 个 scene 页，第 N 张图写入第 N 个 scene 页；不做候选图筛选。返回 URL 或 base64 后立即下载/保存到 `tomato_api_cache/picture_book/`，后续页面只读本地文件。

图片 prompt 提交前同样走 `ContentSafetyService.prepareTextForApi`。疑似安全拒绝记录失败快照；但图片尺寸、参数、鉴权、额度等 400 错误不能当作敏感词规则学习。

### 失败与重试

- 组图失败时不自动回退单图。
- 未完成页会标记为 `error` 并保存失败原因。
- Web UI 的重试按钮重新打开 promptReview 审核弹窗；用户确认后重建整章组图。
- 听力、跟读和聊天根据当前句子或对话进度选择对应绘本页；生成中显示等待占位，失败显示原因和重试按钮。

## 歌曲生成流程

入口：`listening.songGenerate` 根据 `source` 选择阿里云百聆（Fun-Music）或 Suno 网页自动化。Web UI 不直接访问任一歌曲 provider。

阿里云百聆（Fun-Music）：

- `BailianMusicService.prepareLyricsForGeneration` 会先规范化歌词；如果歌词为空、超过 1200 字符、超过 16 行、单行超过 110 字符，或看起来更像散文而非歌曲，则按章节标题压缩成 12 行歌曲格式再提交。
- 提交给百炼的真实文本记为 `submittedLyrics`，并参与 `lyricsHash`、缓存 key、metadata 和字幕时间轴。压缩过的版本设置 `lyricsCompressed=true`。
- 缓存 key 包含模型、`submittedLyrics`、标题、prompt、gender、format 和 watermark 开关；成功音频写入 `ApiCacheService` 的 `music/` 子目录。
- 同一路径音频版本会按 `audioPath` 去重；新百炼结果设为默认版本，旧版本取消默认标记。
- 百炼错误直接显示，不自动回退 Suno；`Lyrics content is illegal` 会映射为提示用户更换更温和英文内容的错误文案。

字幕时间轴：

- 歌曲字幕正文优先使用 `ArticleSongVersion.submittedLyrics`；没有该字段时才回退文章当前歌词。
- 只有 `submittedLyrics` 与文章歌词一致时，才复用 `article_sentence_translations` 的中文翻译。
- BigASR 结果只提供词级时间锚点，不写回文章正文、歌词或字幕正文。

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

章节英文 TTS 在产品语义上统一视为“听力材料”：

- `listening.audioStatus` 只检查本地听力材料缓存，不触发远程合成。检查范围包括当前 `listening_tts` 和旧 `follow_tts` 中与持久化句子文本完全一致的音频文件，用于兼容旧平台、旧音色和历史生成素材。
- 创作中心绘本面板显示“听力材料 X / Y 已生成”，并在“生成组图”后提供“生成听力”显式入口。
- `listening.audioGenerate { articleId, overwrite }` 是批量生成听力材料的唯一章节级显式入口。`overwrite=false` 只补齐缺失句子；`overwrite=true` 清理当前文章的 `listening_tts` 和旧 `follow_tts` 引用后重新生成全部英文句子。
- 已完整生成时，Web UI 必须先确认“覆盖原内容并重新提交远程语音合成”；缺失或部分缺失时，点击按钮会显示“正在生成听力材料”等待弹窗和进度。
- 听力打开、跟读打开、听力播放、全屏 readiness、视频导出 readiness 和跟读原音播放都只读本地缓存。缺失时返回“需要先在创作中心生成听力材料”，不得在后台自动提交 TTS。
- 听力状态、播放、全屏 readiness 和视频导出 readiness 必须按 `articleId` 一次性加载本地音频句柄索引，再按持久化句子文本查找；不要在每一句里重复扫描 `api_cache_article_refs` / `api_cache_entries`，否则旧文章会在“读取中”停留很久并拖慢播放。
- 听力页单句“重新合成语音”仍是显式远程操作；编辑句子只清理失效缓存并标记缺失，不自动重合成。

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

1. 标准中英对照是否所有路径都能本地解析，避免调用文本 provider 提取英文。
2. `pictureBookEnabled` 在正式 UI 中是否始终默认 true，内部测试才允许 false。
3. 绘本 prompt 是否足够强调书名和当前章节，但没有固化 Alice 或其它单本书。
4. 标题 prompt 是否满足短标题和所有格要求。
5. 单词释义 JSON 是否足够稳定，失败 fallback 是否可接受。
6. TTS cache key 是否覆盖 speaker/resourceId/text，避免换音色串缓存。
7. 图片 cache key 是否覆盖 model/size/prompt/policy，避免换模型或提示词后误命中旧图。
8. 失败、mock、缺 key 场景是否不会污染缓存。
9. 删除文章时是否只删除独占缓存，不破坏共享文件。
