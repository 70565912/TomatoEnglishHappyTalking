# 内容安全与文章导入专项规则

> 处理安全拒绝、文章解析、翻译、标题或导入续传时必读。

- 不要把标准中英对照故事整篇直接送给 AI 做英文提取/翻译；必须先本地解析并复用英文原文、中文对照和标题信息。
- 不要对已经有本地缓存或导入译文的数据重复调用 TTS、Realtime、BigASR、图片生成或翻译接口。

内容安全失败与敏感词规则：

- 统一使用 `app/lib/services/content_safety_service.dart` 处理平台安全拒绝、失败快照、用户修正后的规则学习和提交前替换。不要在各个 service 里各写一套临时敏感词替换。
- 正式运行中遇到疑似安全拒绝后，不做二分探测、不反复试探 API。记录 `content_safety_failures`，提示用户修改相关表达后重试。
- 用户修改后同一用途提交成功时，用失败文本和成功文本做词级 diff，只有像 `heads -> he-ads`、`beheaded -> be-headed` 这种短词/短语拆分才写入 `content_safety_rules`；整句改写只能作为样例，不要泛化成规则。
- 规则只应用到提交给云 API 的文本，不修改文章正文、字幕、跟读文本和数据库原文。TTS 请求文本也要先套用安全规则；如果替换后仍然 400，记录失败并把失败原因交给 UI，不再继续自动猜测。
- 替换优先使用连字符或空格，例如 `he-ads` / `he ads`；避免优先使用 `*`，因为语音引擎可能把星号读出来。
- 400 不一定是安全拒绝。明显的参数、尺寸、鉴权、额度、Resource/Speaker 配置错误不能记录为敏感词规则。
- 更重要：开发/测试里的 HTTP 400 经常是沙箱网络拦截或 `flutter_test` 默认 `HttpClient` override 造成的假 400，不是火山真实返回。任何 live API 结论前必须确认测试已 `HttpOverrides.global = null`、必要时在沙箱外/已授权网络环境重跑，并看到真实远程响应或缓存命中；不要把测试环境假 400 写进 `content_safety_failures` 或学习成敏感词规则。
- 2026-06-17 实测：`Alice Was Beginning To Get` 的万相 9 张组图在 `bookDescription` 含 `Caterpillar` 与 `smoking hookah` 时成功返回 9 张 `ready`，说明这两个词本身不能被当作本项目已确认的敏感词或失败原因。以后遇到类似失败，可以提出安全词猜测，但没有真实远程响应、二分证据或平台明确错误前，不得据此修改正式 prompt 机制、压缩/截断规则、替换规则或其它持久代码。
- 调试云 API 失败时，先定位真实原因，再做正式代码改动。实验性验证必须放在临时脚本、暂存改动或独立 git 分支里；若实验没有得到准确结论，必须撤销所有实验性正式改动，换方向继续排查。不要因为一次未定位失败就长期加入安全规避、prompt 扩写、过度限制、自动改写、回退路径或其它“也许有用”的机制。
- 安全失败、成功远程结果和 mock fallback 分开处理：失败快照进 `content_safety_failures`，成功远程结果才进 `api_cache_entries`，mock/fallback 不入成功缓存。

新增文章内容处理顺序：

1. 纯英文输入：本地规范化连字符、撇号、空白和标题行后直接使用，不调用 AI 提取或翻译。
2. 标准中英对照输入：优先本地解析英文原文和中文对照，不调用 AI 提取英文。典型格式是英文段落/中文翻译交替，前面有 `Chapter ...`、英文标题、中文标题，末尾可能有“注：”。英文原文应保留段落边界；中文对照应保存为可复用的字幕/翻译映射；译注不进入正文。
3. 中英混杂但不是标准对照：不要把本地启发式结果直接当最终正文；这类输入必须调用当前文本 provider 提取英文故事原文。
4. 纯中文故事：才调用 AI 转成英文练习文。
5. 标题：用户填写或本地标题候选优先；绘本开启且仍缺标题时，与首次章节规划同一次 AI（`includeTitle`）返回，不要再单独打 `suggest_article_title`；无绘本时才可回退独立标题调用或首句 fallback。
6. 保存顺序：先写入 `articles` 与分句（可用临时 `Untitled Chapter`），再 upsert 中文对照、关联章节，最后写首次绘本规划；通过 `article.save.progress` 推送进度。译文/规划失败不再删文，错误带回 `resumeArticleId`，前端再次 `article.create` 带该 id 只续传剩余步骤。

英文原文课程稿的特殊要求：

- `英文原文` / `英语原文` / `英文故事` / `原文` 区块优先本地提取，不调用 AI；正文边界以故事正文为准，不保留课程导读、拓展讲解、词汇表、音标、词条或例句。
- `【文化卡片】`、`生词好句`、`重点词汇` 等学习材料 heading 一律视为故事正文结束，即使此前处于 `【拓展】` / 背景 / 难句解析等 soft interruption 内。
- `【拓展】`、背景、难句解析等中途讲解只作为 soft interruption 跳过；只有后续英文行带明确故事叙事信号（如 `said` / `asked` / `replied` / `cried` / `thought` / `heard` / `caught` / `went` / `came` 等）或满足已有故事诗歌续行规则时，才恢复正文。不要仅因英文行以引号、撇号或右单引号开头就恢复，避免把原诗、词汇例句误收为故事正文。

标准中英对照故事的特殊要求：

- 不要把整篇标准中英对照内容直接送给方舟或 Realtime 做“提取英文原文”，这会浪费费用，还可能因为 prompt 截断导致只保存前半篇。
- 如果必须用 AI 处理长文本，必须分块且保证全量覆盖；不要只取前 `1600` 或 `2200` 字符后把结果当完整文章。
- 跟读/听力的中文对照应优先复用导入时解析出的中文翻译；不要再逐句调用 `translate_to_chinese` 生成一份可能风格不同的新译文。
- 绘本生成现在是一章一组 v4 审核分镜图；解析出的英文段落只用于构造整章故事内容、规划上下文和连续性提示，不再直接决定图片页数。

Alice 回归测试用例：

- 标准中英对照样例使用 `C:\Users\Ryan\.codex\attachments\4298cfa0-5ff2-4d43-a889-0f18288ec752\pasted-text.txt` 或等价的 Chapter Eight / The Queen's Croquet-Ground 中英对照文本。通过构建程序的 `article.create` 提交，标题留空、书籍选择 `Alice's Adventures in Wonderland`，期望本地标题为 `The Queen's Croquet-Ground`、正文只保留英文、句子数 75、`article_sentence_translations` 75 条；本地标题与导入译文不应再触发正文提取/翻译 AI；绘本开启时允许一次首次章节规划调用并写入 `summary_json`，随后走 v4 提示词审核与确认后的一组绘本图；`listening.open` 返回 75 项且没有空中文。
- 数据库中旧 Alice 文章要作为回归样本保留：`Alice's Adventures in Wonderland - Episod 56`、`爱丽丝梦游仙境（原著领读版）- E61` 以及新导入的 `The Queen's Croquet-Ground`。这些文章都必须挂到同一本书籍 `Alice's Adventures in Wonderland` 下。
- 对旧 Alice 混合正文不要重新整篇提交给 `article.create` 做 AI 提取；旧数据中已保存的英文句子/正文可以用于 `article.list`、`follow.open`、`pictureBook.state`、系列归属测试。若需要重新导入旧内容，优先使用已经提取出的纯英文内容，避免触发 mixed -> 方舟提取。
- 整理已有文章的书籍归属时使用 `series.attachArticle`，不要用 `pictureBook.generate` 代替；`series.attachArticle` 只创建或更新 `story_chapters` 关系，不触发图片生成和其它云 API。
- Alice 系列验证至少检查：`article.list` 中相关文章的 `seriesTitle` 均为 `Alice's Adventures in Wonderland`；`story_chapters` 中同系列包含这些文章；旧两篇若没有导入译文，使用 `pictureBook.state` / `article.list` 验证归属和程序状态，不要调用会补翻译的打开流程；标准中英对照样例的 `listening.open` 能直接使用导入译文。

相关实现入口：

- 文章保存入口：`app/lib/features/web_shell/web_shell_screen.dart` 的 `article.create` / `_resumeArticleCreate` / `_ensurePictureBookChapterPlanForCreate` / `_englishPracticeContent`。
- 续传协议：`ArticleCreateResumeException`（`web_bridge_protocol.dart`）经 bridge `error.data.resumeArticleId` / `failedPhase` 回传；Web UI 用 `NativeCommandError` 保存后续传 id。
- 本地输入解析：`app/lib/services/practice_input_parser.dart`，标准中英对照必须从这里本地解析直用。
- 文本生成处理：`app/lib/services/practice_text_service.dart` / `app/lib/services/text_generation_service.dart`，只用于非标准 mixed、纯中文；缺标题且绘本开启时优先并入章节规划 `includeTitle`，无绘本才单独 `suggest_article_title`。
- 译文 upsert：`DatabaseService.upsertArticleSentenceTranslations`，续传时合并已有行，不整表清删。
- 持久缓存：`app/lib/services/api_cache_service.dart`。
- 内容安全规则：`app/lib/services/content_safety_service.dart`，负责提交前替换、疑似安全失败记录和用户成功修正规则学习。
- 分句规则、V3.7 兼容行为、当前重构架构、迭代门槛与测试方法不在本文件重复维护。修改 `app/lib/services/read_aloud_splitter_v3*.dart` 前必须完整阅读唯一规范 [`read_aloud_sentence_split_spec.md`](../read_aloud_sentence_split_spec.md) 和工程迭代约束 [`read_aloud_sentence_split_engineering_rules.md`](../read_aloud_sentence_split_engineering_rules.md)；历史说明 [`read_aloud_sentence_split_readability_rules.md`](../read_aloud_sentence_split_readability_rules.md) 只作背景，不得覆盖当前规范。
- 绘本段落和提示词：`app/lib/services/picture_book_service.dart`（含 `generateChapterPlanForArticle` / `persistChapterPlanForArticle` / `resolveRelevantCharacters`）。
- Web UI 只能通过 `web_bridge_protocol.dart` / `bridge.ts` 协议提交原始内容，不要绕过 Flutter 直接访问云 API。
