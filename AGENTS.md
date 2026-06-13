# Tomato English Happy Talking Agent Guide

本文件由 `.github` 下的 Copilot 指令、agent、instructions 和 prompts 转写而来，作为本仓库 AI 代理的统一工作说明。

## 项目概述

「Tomato English Happy Talking」是一个 Flutter 独立 App，无后端服务器，支持 Windows EXE 和 Android APK 双平台。

App 直接调用云 API（REST / WebSocket），不依赖本地后端：

- 火山引擎 Doubao TTS 2.0：英文语音合成
- 火山引擎 Realtime V3：AI 对话文本 query / 会话协议
- 火山引擎 BigASR：聊天语音识别与跟读识别
- 本地 BigASR 识别驱动评分：替代 Azure Pronunciation Assessment

## 当前项目标识

- Flutter 包名：`tomato_english_happy_talking`
- 应用显示名：`Tomato English Happy Talking`
- Android package / namespace：`com.example.tomato_english_happy_talking`
- Windows 可执行文件名：`tomato_english_happy_talking.exe`

## 技术栈

- 框架：Flutter 3.41.9 stable，SDK 位于 `D:\DevTools\flutter`
- 语言：Dart，严格空安全
- 状态管理：`flutter_riverpod` + `riverpod_annotation` 代码生成风格
- 路由：`go_router`
- WebView 壳：`flutter_inappwebview`
- Web UI：React + Vite + TypeScript，源码在 `web_ui/`
- HTTP：`dio`
- 本地数据库：`sqflite` + `path`
- 安全存储：`flutter_secure_storage`
- 音频播放：`just_audio`
- 录音：`record`
- 波形可视化：`audio_waveforms`
- 动画/虚拟形象：Web UI CSS 状态动画为主，`rive` / `lottie` 原生依赖保留
- UI 动效：`flutter_animate`
- 字体：`google_fonts`，统一使用 Nunito

## 本地工具链与环境

- Flutter SDK：`D:\DevTools\flutter`
- Android SDK：`D:\Android\SDK`
- Android 用户目录：`D:\Android\.android`
- AVD 目录：`D:\Android\.android\avd`
- 默认模拟器：`EnglishRead_API_35`
- Windows WebView：需要 Microsoft Edge WebView2 Runtime

默认网络环境需要设置：

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

每个新终端如需直接调用 Flutter，可先设置：

```powershell
$env:PATH = "D:\DevTools\flutter\bin;" + $env:PATH
```

## 项目结构

```text
app/lib/
├── main.dart
├── core/
│   ├── config/app_config.dart
│   ├── theme/app_theme.dart
│   └── router/app_router.dart
├── services/
│   ├── tts_service.dart
│   ├── realtime_voice_service.dart
│   ├── streaming_asr_service.dart
│   ├── recognition_based_assessment_service.dart
│   ├── scoring_service.dart  # deprecated compatibility model/stub
│   └── nlp_service.dart
├── data/models/
├── features/
│   ├── home/
│   ├── article/
│   ├── follow_read/
│   ├── chat/
│   ├── profile/
│   └── web_shell/
└── shared/widgets/

web_ui/
├── src/
│   ├── App.tsx
│   ├── bridge.ts
│   └── types.ts
└── package.json
```

## 架构约定

- Services 层只做 API 调用或数据处理，不持有 UI 状态，不调用 `showDialog`。
- Providers 层使用 `@riverpod` 注解，持有 UI 状态，调用 services。
- Screens/Widgets 层只做 UI，通过 `ref.watch` / `ref.read` 读取状态。
- Widget 不直接 `await` API 调用，必须通过 Provider / AsyncValue 桥接。
- API 响应原始 JSON 不直接传给 Widget，先在 Service 层解析为 Dart 模型。
- Services 必须提供 mock fallback，方便无 API Key 时本地开发调试。
- 诊断日志统一使用 `app/lib/core/logging/tomato_logger.dart` 的 `TomatoLogger`；新增链路不要再散落裸 `debugPrint`。日志默认写入运行数据根 `logs/`，并通过 QA `/logs/recent`、`/logs/stream`、`/logs/export` 调试。
- 当前主 UI 是 `web_ui` 打包后的本地 WebView 页面；Flutter 的 `WebShellScreen` 负责桥接数据库、录音、播放、TTS、ASR、AI 对话和安全配置。
- `app/lib/features/home|article|follow_read|chat|profile` 下的原生 Screen 仍可作为参考/兼容层，但默认路由进入 `WebShellScreen`。
- Web UI 与 Flutter 交互时必须通过 `web_bridge_protocol.dart` / `bridge.ts` 的 typed command/event 协议，不要从 Web UI 直接访问云 API 或本地文件系统。
- Suno 网页自动化在 `WebShellScreen` 内执行：同一篇文章如果已经保存过上一次 Suno 自动生成的风格，再次进入时直接填入旧风格；没有旧风格时才点击 `Styles` 工具栏里的蓝色 `Personalize style prompt to match your taste` 魔法棒，等待 Suno 根据歌词写入真实 `Styles` value。不要把默认 placeholder、`Refresh recommended styles` 或 `Add style:` 推荐标签当成自动风格结果。
- Suno 填表只能在 `https://suno.com/create` 执行；字段定位应排除 Search / Current page / Song Title / Enhance lyrics 等工具输入框，但不要用 textarea 正文参与工具框判断，避免歌词里的普通单词 `search` 误伤真正的 Lyrics / Styles。
- Suno 下载阶段必须要求当前歌曲详情页、Library 行或已打开菜单与本篇文章的歌词/风格达到高匹配；不要仅凭旧 `songUrl`、页面级 `Audio` 文本或低匹配详情页下载。缓存状态恢复时，如果只有 `metadataPath` 且文件已不存在、也没有本地音频版本，应视为空状态。
- Suno 歌曲缓存必须按 `styleKey` 分组：`versions` 要带 `stylePrompt` / `styleKey`，`detectedSongUrls` 记录当前风格已检测到的完整歌曲链接，`downloadComplete=true` 只表示这些链接都有本地音频版本。重新检测下载时只下载缺失链接，不要重复下载已存在的同一 `songUrl`；同一风格已完整下载时只能进入已完成待命/播放状态，不能自动再次点击 Create 消耗 credits。
- Suno 歌曲字幕时间轴使用 App 提交给 Suno 的原歌词作为展示文本，BigASR `show_utterances` 只提供词级时间锚点；不要把 ASR 识别文本写回文章、歌词或字幕正文。歌曲播放通过 `listening.song.position` 推送当前 cue；歌曲版视频录制必须先有 `timelinePath`。
- Suno 下载的音频和 metadata 必须保存在持久目录 `suno-music/`。如果旧缓存或设置指向 `.tmp` / 系统临时目录，应通过 `AssetPathService` 迁移或忽略该设置，不要继续把可复用歌曲资产写到临时目录。
- 听力播放、全屏播放和普通录制只播放英文 TTS；中文翻译只作为字幕/对照文本显示，不再触发听力中文 TTS 预加载或播放。`listening.fullscreenReady` 只检查当前和下一句英文音频，绘本图片只预取当前和下一张；文章保存时应优先保存导入译文，缺失时可用 `PracticeTextService.translateToChinese` 生成逐句字幕，后续听力/跟读只读库中译文，不在打开页面时批量翻译。

## Flutter / Dart 规范

- 必须使用 null safety。
- 禁止随意使用 `!` 强制解包；只有逻辑上确实不可为 null 时才可使用，并加简短说明。
- 优先用 `??`、`?.`、`if (x != null)` 守卫。
- 函数参数能用 named + required 就用，避免位置参数歧义。
- 异步函数使用 `async` / `await`，避免裸 `.then()` / `.catchError()`。
- 错误处理使用 `try` / `catch`，在 catch 块中记录日志或返回 fallback。
- 类名和 Widget 使用 `UpperCamelCase`。
- 文件名使用 `snake_case`。
- Screen 文件命名为 `xxx_screen.dart`。
- 变量、函数和常量使用 `lowerCamelCase`。
- 优先使用 `StatelessWidget`；需要读取 Riverpod 状态时使用 `ConsumerWidget`。
- 只有需要本地 UI 状态时使用 `ConsumerStatefulWidget`。

## UI 主题

- 主色：`AppTheme.primary`，橙色 `#FF6B35`
- 背景蓝：`AppTheme.darkBlue`，深蓝 `#1A237E`
- 强调黄：`AppTheme.accent`，黄色 `#FFD54F`
- 字体始终使用 `GoogleFonts.nunito()`
- 间距优先使用 `8` 的倍数，例如 8、16、24、32
- 不要在 UI 中硬编码项目主题色，统一从 `AppTheme` 读取。
- Web UI 中使用 `web_ui/src/styles.css` 的 CSS 变量维护主题色，并与 `AppTheme` 语义保持一致。
- 新页面需要同时适配 Windows 和 Android，避免硬编码固定宽度。
- 图标优先使用 Material Icons，除非已有局部约定要求其他图标体系。

## Riverpod 规范

本项目使用 `riverpod_annotation` 代码生成风格，统一用 `@riverpod` / `@Riverpod` 注解，不使用老式手写 Provider 风格。

```dart
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'article_provider.g.dart';

@riverpod
class ArticleNotifier extends _$ArticleNotifier {
  @override
  Future<List<Article>> build() async {
    return ref.read(databaseServiceProvider).getArticles();
  }

  Future<void> addArticle(Article article) async {
    await ref.read(databaseServiceProvider).saveArticle(article);
    ref.invalidateSelf();
  }
}
```

UI 中处理 `AsyncValue` 时必须覆盖三种状态：

- `data`
- `loading`
- `error`

Provider 类型选择：

- 只读列表或详情：`@riverpod Future<T> build()`
- 有增删改操作：`@riverpod class XxxNotifier extends _$XxxNotifier`
- 全局 service 实例：`@Riverpod(keepAlive: true)`
- 页面级临时状态：默认 AutoDispose

使用约定：

- `ref.watch()` 用于 `build` 方法中监听状态。
- `ref.read()` 用于点击、提交等事件处理。
- 避免在 Provider 的 `build()` 外做副作用。
- 跨页面共享状态才使用 `keepAlive: true`。
- Service 通过 Provider 注入，不要在 Notifier 内直接 `new`。

## Services 层规范

适用文件：`app/lib/services/**/*.dart`

核心原则：

- Service 只做 API 调用、数据解析或本地数据处理。
- 返回 Dart 模型、业务值或 fallback；不要把原始 `Map<String, dynamic>` 直接暴露给 Widget。
- 每个 public 方法应在 API Key 缺失时走 mock fallback，不让应用崩溃。
- 错误时使用 `debugPrint` 记录，返回 `null` 或 fallback；不要把异常直接抛给 Widget 层。
- 只使用 `dio`，不要引入 `http`、`http_dio` 等其他 HTTP 库。
- API Key 必须通过 `AppConfig` 读取，绝不硬编码。

推荐 dio 超时配置：

```dart
final _dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 30),
));
```

Service Provider 推荐写法：

```dart
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'example_service.g.dart';

@Riverpod(keepAlive: true)
ExampleService exampleService(ExampleServiceRef ref) {
  return ExampleService();
}
```

## API 成本、缓存与内容解析优先级

火山语音、Realtime、BigASR、图片生成等云 API 都会产生费用。新增或修改任何会触发云调用的功能时，必须优先考虑“本地解析、本地缓存、复用已有结果”，不要把 AI 请求作为第一选择。

总体原则：

- 所有云 API 调用必须先查本地持久缓存或已有业务数据；只有缓存未命中且本地无法确定结果时，才请求远程。
- 只缓存成功的真实远程结果；不要缓存 API Key、请求 Header、失败响应、异常文本或 mock fallback。
- 同一输入、同一模型/声音/资源 ID/尺寸/参考图/提示词版本应生成稳定缓存 key，避免同内容重复计费。
- 删除文章时只清理文章独占缓存和引用；全局声音预览、共享 TTS、共享图片参考等不要误删。
- 新增测试时要覆盖二次调用命中缓存、不重复远程请求、删除文章不误删共享缓存。
- “省 API”约束主要针对正式运行流程和重复调用：正式功能必须最大化复用本地解析、数据库、文件缓存和成功远程结果。
- 开发验证不能为了省一次测试调用而跳过关键链路；涉及新增文章、方舟提取/翻译、标题、绘本生成、TTS/听力、跟读录音/识别等端到端改动时，必须做足够完整的回归测试。绘本验证要跑全量文章流程，不能只测第一页或只测 prompt 预览。
- 绘本生成策略为“每篇文章/每章一组连续分镜图”：先生成并缓存 `chapter_story_outline_v1`，再按分镜创建多条 `picture_book_pages`；第 1 张对应第 1 个分镜，第 N 张对应第 N 个分镜，不做候选图筛选。
- 正常分镜数最多 14 段，`picture_book_pages` 必须覆盖完整句子范围；超长章节在分镜阶段合并相邻场景，不拆成多组图片请求。
- 章节组图 prompt 必须基于书籍名、章节标题、当前章节故事内容和结构化分镜，适配任意书籍；不要把 Alice、Wonderland 或其它单本书的角色/场景/时代风格固化到通用模板。当前章节内容优先于旧章节历史，避免把上一章角色或场景误带入本章。
- Web UI 中“书籍”就是 `story_series`；新增文章页不再展示绘本开关，保存时默认异步生成连续绘本组图。只有内部测试或显式 payload 才可以传 `pictureBookEnabled=false` 跳过生成。
- 取消“图片中不能出现文字”的旧限制。自然文字可以出现，例如书名、标牌、扑克牌数字/花色、地图标注、标签、手写便条或装饰字样；但不要让文字成为理解画面的唯一方式，因为 App 会另行显示字幕。
- 绘本 prompt 默认使用本地安全模板和系列设定，不要每章都调用方舟文本模型润色；AI prompt 润色只在显式打开 `TOMATO_PICTURE_BOOK_AI_PAGE_PROMPTS=true` 时启用。
- 系列设定集默认本地合并章节摘要；AI 更新系列 bible 只在显式打开 `TOMATO_PICTURE_BOOK_AI_SERIES_BIBLE=true` 时启用。
- 自动生成风格/角色参考图默认关闭以节省费用；只有显式打开 `TOMATO_PICTURE_BOOK_REFERENCE_IMAGES=true` 时才创建或使用自动参考图。正式冷缓存流程应尽量保持每章一次结构化分镜调用和一次顺序组图调用。
- Seedream 组图 `sequential_image_generation` 是正式绘本链路：`PictureBookService` 直接调用 `generatePictureBookImageGroup(..., useSequential: true)`，`max_images` 等于分镜页数。组图失败不自动回退单图；失败页保存错误原因，重试按钮重新提交整章组图。
- 整章组图 HTTP 返回可能按每张图耗时数分钟，不能再用固定 120 秒判定失败。`VolcImageService` 按请求图片数动态设置接收超时，默认每张 150 秒、最小 180 秒、最大 2700 秒；可通过 `TOMATO_VOLC_IMAGE_SECONDS_PER_IMAGE`、`TOMATO_VOLC_IMAGE_MIN_RECEIVE_TIMEOUT_SECONDS`、`TOMATO_VOLC_IMAGE_MAX_RECEIVE_TIMEOUT_SECONDS` 调整。
- 绘本保存/生成/听力模式的最终联调必须跑真实 Windows App UI。外部窗口截图不可用时，开启 `TOMATO_QA_REMOTE=true`，用 `npm run qa:picture-book-live` 通过本机 QA 控制接口填表保存、打开听力、轮询异步绘本状态、检查 loading/error/ready UI、字幕和播放；不要只用 service/test harness 作为最终结论。
- 对话练习提纲复用 `chapter_story_outline_v1` 的结构化分镜，不再单独重复生成聊天提纲。程序内部 fallback 只在无 key/远程失败时本地生成最多 14 段分镜覆盖点，后续聊天轮次只复用提纲，不重复提交完整章节。

内容安全失败与敏感词规则：

- 统一使用 `app/lib/services/content_safety_service.dart` 处理平台安全拒绝、失败快照、用户修正后的规则学习和提交前替换。不要在各个 service 里各写一套临时敏感词替换。
- 正式运行中遇到疑似安全拒绝后，不做二分探测、不反复试探 API。记录 `content_safety_failures`，提示用户修改相关表达后重试。
- 用户修改后同一用途提交成功时，用失败文本和成功文本做词级 diff，只有像 `heads -> he-ads`、`beheaded -> be-headed` 这种短词/短语拆分才写入 `content_safety_rules`；整句改写只能作为样例，不要泛化成规则。
- 规则只应用到提交给云 API 的文本，不修改文章正文、字幕、跟读文本和数据库原文。TTS 请求文本也要先套用安全规则；如果替换后仍然 400，记录失败并把失败原因交给 UI，不再继续自动猜测。
- 替换优先使用连字符或空格，例如 `he-ads` / `he ads`；避免优先使用 `*`，因为语音引擎可能把星号读出来。
- 400 不一定是安全拒绝。明显的参数、尺寸、鉴权、额度、Resource/Speaker 配置错误不能记录为敏感词规则。
- 更重要：开发/测试里的 HTTP 400 经常是沙箱网络拦截或 `flutter_test` 默认 `HttpClient` override 造成的假 400，不是火山真实返回。任何 live API 结论前必须确认测试已 `HttpOverrides.global = null`、必要时在沙箱外/已授权网络环境重跑，并看到真实远程响应或缓存命中；不要把测试环境假 400 写进 `content_safety_failures` 或学习成敏感词规则。
- 安全失败、成功远程结果和 mock fallback 分开处理：失败快照进 `content_safety_failures`，成功远程结果才进 `api_cache_entries`，mock/fallback 不入成功缓存。

新增文章内容处理顺序：

1. 纯英文输入：本地规范化连字符、撇号、空白和标题行后直接使用，不调用 AI 提取或翻译。
2. 标准中英对照输入：优先本地解析英文原文和中文对照，不调用 AI 提取英文。典型格式是英文段落/中文翻译交替，前面有 `Chapter ...`、英文标题、中文标题，末尾可能有“注：”。英文原文应保留段落边界；中文对照应保存为可复用的字幕/翻译映射；译注不进入正文。
3. 中英混杂但不是标准对照：不要把本地启发式结果直接当最终正文；这类输入必须调用方舟提取英文故事原文。
4. 纯中文故事：才调用 AI 转成英文练习文。
5. 用户未输入标题：优先从导入文本的英文标题行、章节标题或系列信息本地生成；无法确定时再调用 AI 生成短标题。

标准中英对照故事的特殊要求：

- 不要把整篇标准中英对照内容直接送给方舟或 Realtime 做“提取英文原文”，这会浪费费用，还可能因为 prompt 截断导致只保存前半篇。
- 如果必须用 AI 处理长文本，必须分块且保证全量覆盖；不要只取前 `1600` 或 `2200` 字符后把结果当完整文章。
- 跟读/听力的中文对照应优先复用导入时解析出的中文翻译；不要再逐句调用 `translate_to_chinese` 生成一份可能风格不同的新译文。
- 绘本生成现在是一章一组结构化分镜图；解析出的英文段落只用于构造整章故事内容、分镜摘要和连续性提示，不再直接决定图片页数。

Alice 回归测试用例：

- 标准中英对照样例使用 `C:\Users\Ryan\.codex\attachments\4298cfa0-5ff2-4d43-a889-0f18288ec752\pasted-text.txt` 或等价的 Chapter Eight / The Queen's Croquet-Ground 中英对照文本。通过构建程序的 `article.create` 提交，标题留空、书籍选择 `Alice's Adventures in Wonderland`，期望本地标题为 `The Queen's Croquet-Ground`、正文只保留英文、句子数 75、`article_sentence_translations` 75 条；除默认结构化分镜和一组绘本图外，不应因正文提取/中文对照再产生无谓 AI 调用，`listening.open` 返回 75 项且没有空中文。
- 数据库中旧 Alice 文章要作为回归样本保留：`Alice's Adventures in Wonderland - Episod 56`、`爱丽丝梦游仙境（原著领读版）- E61` 以及新导入的 `The Queen's Croquet-Ground`。这些文章都必须挂到同一本书籍 `Alice's Adventures in Wonderland` 下。
- 对旧 Alice 混合正文不要重新整篇提交给 `article.create` 做 AI 提取；旧数据中已保存的英文句子/正文可以用于 `article.list`、`follow.open`、`pictureBook.state`、系列归属测试。若需要重新导入旧内容，优先使用已经提取出的纯英文内容，避免触发 mixed -> 方舟提取。
- 整理已有文章的书籍归属时使用 `series.attachArticle`，不要用 `pictureBook.generate` 代替；`series.attachArticle` 只创建或更新 `story_chapters` 关系，不触发图片生成和其它云 API。
- Alice 系列验证至少检查：`article.list` 中相关文章的 `seriesTitle` 均为 `Alice's Adventures in Wonderland`；`story_chapters` 中同系列包含这些文章；旧两篇若没有导入译文，使用 `pictureBook.state` / `article.list` 验证归属和程序状态，不要调用会补翻译的打开流程；标准中英对照样例的 `listening.open` 能直接使用导入译文。

相关实现入口：

- 文章保存入口：`app/lib/features/web_shell/web_shell_screen.dart` 的 `article.create` / `_englishPracticeContent` / `_resolveArticleTitle`。
- 本地输入解析：`app/lib/services/practice_input_parser.dart`，标准中英对照必须从这里本地解析直用。
- 方舟文本处理：`app/lib/services/practice_text_service.dart` / `app/lib/services/text_generation_service.dart`，只用于非标准 mixed、纯中文和必要标题生成。
- 持久缓存：`app/lib/services/api_cache_service.dart`。
- 内容安全规则：`app/lib/services/content_safety_service.dart`，负责提交前替换、疑似安全失败记录和用户成功修正规则学习。
- 分句：`app/lib/services/nlp_service.dart` 与 `web_ui/src/sentenceSplitter.ts`。
- 绘本段落和提示词：`app/lib/services/picture_book_service.dart`。
- Web UI 只能通过 `web_bridge_protocol.dart` / `bridge.ts` 协议提交原始内容，不要绕过 Flutter 直接访问云 API。

### 云服务端点

Doubao TTS 2.0：

- 端点：`https://openspeech.bytedance.com/api/v3/tts/unidirectional`
- 鉴权：Header `X-Api-Key`、`X-Api-Resource-Id`、可选 `X-Api-Request-Id`
- 默认 Resource ID：`seed-tts-2.0`
- 返回 HTTP chunked JSON 行，`data` 字段为 Base64 MP3 分片，按顺序解码合并后交给 `just_audio`

Realtime V3 AI 对话：

- 端点：`wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- 推荐鉴权：`X-Api-Key`、`X-Api-Resource-Id: volc.speech.dialog`、`X-Api-Connect-Id`
- 不再回退旧鉴权头；语音链路只使用新版 `X-Api-Key`
- 当前客户端使用文本 query 模式：`StartConnection` -> `StartSession` -> `ChatTextQuery` -> `FinishSession` -> `FinishConnection`
- AI 回复文本交给本地 TTS 2.0 播放

BigASR：

- 端点：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`
- 鉴权：`X-Api-Key`、`X-Api-Resource-Id`、`X-Api-Request-Id`、`X-Api-Sequence`
- 音频格式：WAV PCM 16kHz 16bit mono
- 聊天语音识别与跟读评分识别都通过 `StreamingAsrService`
- 跟读评分由 `RecognitionBasedAssessmentEngine` 基于识别文本和参考句做 LCS / 覆盖率 / 长度比例启发式计算

数据库服务：

- `DatabaseService` 单例通过 `getInstance()` 获取。
- 表名、列名用常量定义，避免散落字符串。
- 所有写操作返回 `Future<void>` 或 `Future<int>`。

配置与密钥：

- 语音密钥字段：`volc_speech_api_key` / `TOMATO_VOLC_SPEECH_API_KEY`
- 推荐本机注入：`security/speech-api-key.txt`
- 方舟密钥文件：`security/ark.txt`，保存火山方舟 Bearer API Key，可写成裸 key、`Bearer ...` 或 `ARK_API_KEY=...`；这是方舟文本处理和方舟图片生成的唯一本地 key 文件。
- 绘本图片只使用方舟 `/api/v3/images/generations`；不要恢复旧 Visual / AK-SK 图片备用链路。
- 方舟组图、参考图、Seedream 图片能力只在成功读取到 `ark.txt` / `TOMATO_VOLC_ARK_API_KEY` 时启用；没有方舟 Bearer key 时应跳过图片生成，不调用其它图片模型。
- 绘本图片默认使用方舟 `doubao-seedream-5-0-260128`。用户侧展示按产品需求使用 16:9 `1280x720` 体验，但真实方舟网络探针已确认远程 `1280x720` 会返回 `InvalidParameter: image size must be at least 3686400 pixels`；因此远程请求使用最小满足限制的 16:9 `2560x1440`。下载后保存远程原图，UI 负责缩小显示；不要为了缩放再调用一次图片生成 API。
- 注意 `flutter_test` 默认会拦截 `HttpClient` 并让 HTTP 请求本地返回 400；任何 live API 测试都必须先清除测试框架的 HTTP override，否则 400 不能当作火山接口真实错误。
- 如果 live probe 在普通测试环境里返回空 body 的 HTTP 400，先按“测试环境拦截”处理：检查 `HttpOverrides.global = null`、网络权限/沙箱授权、API Key 是否真实读取，再讨论内容安全。不要先猜敏感词。
- Seedream 图片 API 笔记放在 `docs/volc_ark_seedream_image_api_notes.md`；涉及模型、endpoint、鉴权、组图、参考图、尺寸、缓存 key 的改动时先看这份文档。
- 调试兼容注入：`--dart-define TOMATO_VOLC_SPEECH_API_KEY=...`
- 旧的统一语音 key 和分服务语音 key 字段不再作为兜底
- 设置页只展示运行时读取状态，不提供手动录入 API Key 的表单

## Android 原生目录规范

适用范围：`app/android/**`

当前事实：

- Android package / namespace 固定为 `com.example.tomato_english_happy_talking`
- `MainActivity` 路径固定为 `app/android/app/src/main/kotlin/com/example/tomato_english_happy_talking/MainActivity.kt`
- `MainActivity` 包声明必须是 `package com.example.tomato_english_happy_talking`
- Android 启动器显示名固定为 `Tomato English Happy Talking`

Gradle 约束：

- `app/android/app/build.gradle.kts` 中的 `namespace` 与 `defaultConfig.applicationId` 必须保持一致。
- Gradle 插件顺序保持现状：
  - `com.android.application`
  - `kotlin-android`
  - `dev.flutter.flutter-gradle-plugin`
- 保持 Java 17 配置：
  - `sourceCompatibility = JavaVersion.VERSION_17`
  - `targetCompatibility = JavaVersion.VERSION_17`
  - `kotlinOptions.jvmTarget = JavaVersion.VERSION_17.toString()`
- 当前 `release` 构建保留 `signingConfig = signingConfigs.getByName("debug")`，除非任务明确要求切换正式签名。

`gradle.properties` 约束：

- 保留 `android.useAndroidX=true`
- 保留 `android.overridePathCheck=true`
- 保留 `kotlin.compiler.execution.strategy=in-process`

Manifest 与入口约束：

- `AndroidManifest.xml` 中的 `<application android:label>` 保持为 `Tomato English Happy Talking`。
- 主 Activity 保持为 `.MainActivity`。
- 保留当前 `android:exported="true"`、`launchMode="singleTop"`、`hardwareAccelerated="true"` 和 `windowSoftInputMode="adjustResize"`。
- 保留当前 `PROCESS_TEXT` queries 配置，除非明确确认不再需要。

修改 package 名时必须同步更新：

- `app/android/app/build.gradle.kts`
- `app/android/app/src/main/AndroidManifest.xml`，若涉及组件全名或包关联
- `app/android/app/src/main/kotlin/.../MainActivity.kt`
- Kotlin 目录结构本身

不要把旧包名 `com.example.english_love_reading` 重新引入源码。

## PowerShell Tooling 规范

适用范围：

- `tools/build_windows.ps1`
- `tools/build_android.ps1`
- `tools/run_android_debug.ps1`
- `tools/setup_android_emulator.ps1`

脚本风格：

- 保持 `Set-StrictMode -Version Latest`。
- 保持 `$ErrorActionPreference = "Stop"`。
- 需要检查外部命令退出码时，优先封装或复用 `Assert-LastExitCode`。
- 输出信息保持当前中文风格。
- 阶段标题统一用 `=== 标题 ===`。
- 优先让脚本自行设置 `PATH`、`ANDROID_HOME`、`ANDROID_SDK_ROOT` 等环境变量，不依赖用户当前终端状态。

当前产物命名：

- Windows 可执行文件：`tomato_english_happy_talking.exe`
- Windows 发布目录：`release\windows\tomato_english_happy_talking`
- Android 发布 APK：`release\android\tomato_english_happy_talking-android-release.apk`
- Web UI 打包产物：`app\assets\web\`

修改约束：

- 修改产物名时，同时更新脚本中的发布目录和旧产物清理逻辑。
- 修改 Android 启动或模拟器脚本时，始终同时设置：
  - `ANDROID_HOME`
  - `ANDROID_SDK_ROOT`
  - `ANDROID_USER_HOME`
  - `ANDROID_AVD_HOME`
- 涉及 Windows 构建名变更时，注意清理旧的 `app\build\windows` CMake 缓存，避免继续引用旧 target 名。
- 涉及 Android 调试脚本时，优先复用 `build_android.ps1 -Run`，不要复制一套新的 Flutter 启动逻辑。
- 修改 Web UI 后，保持 `tools/build_windows.ps1`、`tools/build_android.ps1` 自动执行 `npm ci` / `npm install` 与 `npm run build`，确保 `app\assets\web\` 随 EXE/APK 更新。
- 新增 Web UI 依赖时同步更新 `web_ui\package.json` 与 `web_ui\package-lock.json`，不要提交 `node_modules`。
- Windows Debug 和 Release 可以是两套可执行程序，但桌面运行目录和数据必须共用 `release\windows\tomato_english_happy_talking`；Debug 构建/运行也要先把程序文件发布到该目录，确保 `ffmpeg.exe`、依赖 DLL、数据库和 API 缓存都从同一处读取，不要直接运行 `app\build\windows\...\Debug` 旁边的 EXE。

## 构建、运行与发布

处理构建、发布、模拟器任务时，优先复用根目录 PowerShell 脚本，不要只给一次性裸终端命令。

Codex / 自动化会话执行 Flutter 相关命令时，必须直接走已授权的沙箱外 PowerShell，不要先在受限沙箱内试跑。当前环境已验证受限沙箱会卡在 Flutter SDK cache lockfile 访问上；`flutter --version`、`flutter pub get`、`flutter analyze`、`flutter test`、`tools/build_windows.ps1`、`tools/build_android.ps1`、`tools/run_android_debug.ps1`、`tools/setup_android_emulator.ps1` 等只要会触碰 `D:\DevTools\flutter`，都应直接用类似下面的外部 PowerShell 形式执行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1'
```

纯 Web UI 的 `npm` / `tsc` / `vite` 命令可以按普通仓库命令执行；只有需要 Flutter SDK、Android SDK 或启动桌面/模拟器时才直接走沙箱外。

常用命令：

```powershell
# 安装依赖
cd f:\TomatoEnglishHappyTalking\app
flutter pub get

# Windows Debug 运行
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run

# Windows Release 构建
.\tools\build_windows.ps1 -Release

# Windows Release 构建并运行
.\tools\build_windows.ps1 -Release -Run

# Android Release 构建并发布
.\tools\build_android.ps1

# Android 已连接设备 Debug
.\tools\build_android.ps1 -Run -DeviceId <device-id>

# Android 模拟器 Debug
.\tools\run_android_debug.ps1

# 初始化或重建 Android 模拟器环境
.\tools\setup_android_emulator.ps1 -Start

# Web UI 本地调试
cd f:\TomatoEnglishHappyTalking\web_ui
npm run dev
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_WEB_UI_DEV_URL=http://127.0.0.1:5173"
```

构建产物：

- Windows Release 构建输出：`app\build\windows\x64\runner\Release\tomato_english_happy_talking.exe`
- Windows Debug 构建中间输出：`app\build\windows\x64\runner\Debug\tomato_english_happy_talking.exe`，但调试运行也应使用脚本同步后的发布目录 EXE。
- Windows 发布目录：`release\windows\tomato_english_happy_talking\`
- Android 构建输出：`app\build\app\outputs\flutter-apk\app-release.apk`
- Android 发布 APK：`release\android\tomato_english_happy_talking-android-release.apk`
- Web UI 构建输出 / App 内置资源：`app\assets\web\`（由 `web_ui/vite.config.ts` 的 `outDir` 指定）

- 桌面运行目录和数据固定跟随发布目录：Windows Debug 和 Release 可以是两套构建产物，但脚本会把最终运行的程序文件同步到 `release\windows\tomato_english_happy_talking\`；数据库、`tomato_api_cache/`、绘本图片、TTS、录音、`ffmpeg.exe` 和依赖 DLL 都应从这里读取，不要让 Debug 从 `app\build\windows\...\Debug` 直接启动或写入第二套数据。
- `tools/build_windows.ps1` 不得清空用户运行数据；如果需要清理发布目录，只能清理程序构建产物，必须保留数据库、`tomato_api_cache/`、录音、绘本图片和配置密钥文件。
- `D:\DevTools\flutter\bin\flutter.bat analyze`、`flutter.bat --version`、`flutter test` 以及项目 Flutter 构建脚本在当前 Codex 沙箱内已确认会卡住 SDK cache lockfile；代理会话不要先试沙箱内命令，直接用已授权沙箱外 PowerShell 执行，并设置明确超时。

只有在怀疑脚本本身有问题时，才退回到底层 `flutter build`、`flutter run`、`gradlew`、`adb` 或 `emulator` 命令定位。

## 新建功能页面工作流

新建页面前先搜索现有 `web_ui` 路由、bridge command、Flutter feature、provider 和 widget 结构。

当前默认产品 UI 在 `web_ui/src/App.tsx` 中维护，路由使用 hash path：

- `/`
- `/article/new`
- `/follow/<articleId>`
- `/chat/<articleId>`
- `/settings`

Flutter 外层 `app_router.dart` 只负责让这些入口进入 `WebShellScreen`，并保留 `/follow-read/<articleId>`、`/profile` 等旧别名。

新增面向用户的主流程时，通常需要同步：

- `web_ui/src/App.tsx`：页面、状态与交互
- `web_ui/src/types.ts`：bridge payload 类型
- `web_ui/src/bridge.ts`：本地 mock payload
- `app/lib/features/web_shell/web_shell_screen.dart`：native command handler 和事件推送
- `app/lib/features/web_shell/web_bridge_protocol.dart`：协议解析规则

只有确实需要原生 Flutter 页面或兼容旧 UI 时，才在 `app/lib/features/<feature_name>/` 下创建，结构如下：

```text
features/<feature_name>/
├── <feature_name>_screen.dart
├── providers/
│   └── <feature_name>_provider.dart
└── widgets/
```

Screen 基本要求：

- 使用 `ConsumerWidget` 或必要时 `ConsumerStatefulWidget`。
- 背景、按钮、强调色从 `AppTheme` 获取。
- 字体用 `GoogleFonts.nunito()`。
- UI 不直接调用 cloud API。
- 支持 Windows 与 Android 布局。

Provider 基本要求：

- 使用 `riverpod_annotation`。
- 文件包含 `part '<feature_name>_provider.g.dart';`。
- 状态更新集中在 Notifier 或函数式 provider 中。

路由注册：

- 路由统一维护在 `app/lib/core/router/app_router.dart`。
- 新路由使用 `GoRoute` 加入现有路由表，并确认 `web_ui` 的 hash route 与 bridge session 生命周期一致。

如果新增或修改了 `@riverpod` 代码，需要运行项目已有代码生成流程或等效命令，并优先沿用仓库已有脚本/约定。

## 新建或重构云 API Service 工作流

新建 service 时：

- 文件放在 `app/lib/services/<service_name>_service.dart`。
- 配置存取入口在 `app/lib/core/config/app_config.dart`。
- 如新增非密钥运行参数，通常同步更新 `app/lib/features/profile/profile_screen.dart` 和 Web UI `settings.load` 展示。
- 不要新增手动输入 API Key 的设置页表单；密钥通过本机加密文件或 `--dart-define` 注入。
- 不要为了验证服务逻辑去改构建链。

Service 必须满足：

- 只用 `dio`。
- API Key 通过 `AppConfig` 读取。
- mock fallback 返回结构合理的假数据。
- 返回 Dart 模型类。
- 错误时用 `TomatoLogger` 记录摘要并返回 `null` 或 fallback。
- 不修改 `pubspec.yaml` 既有依赖版本，除非任务明确要求。

## 诊断日志规范

- 统一入口：`TomatoLogger`。
- 固定字段：`ts, level, category, event, message, flowId, articleId, route, stage, status, durationMs, data, error, stack`。
- 级别：`trace/debug/info/warn/error/fatal`；默认 `info`，可用 `TOMATO_LOG_LEVEL` 调整。
- 分类：`startup, bridge, qa, webview, article, pictureBook, tts, asr, chat, follow, listening, recording, suno, music, cache, config, safety`。
- 日志目录解析顺序：`TOMATO_LOG_DIR`、`TOMATO_DESKTOP_DATA_ROOT\logs`、桌面程序目录 `logs`。Windows Debug/Release 都应复用 `release\windows\tomato_english_happy_talking\logs`。
- 日志文件为 NDJSON，内存保留最近 2000 条，文件默认 5 MB 轮转，最多 10 个文件或 7 天。
- 永远不要记录完整 API key、Authorization、Cookie、完整文章正文、完整歌词、完整云响应或绝对路径明文；需要定位内容时记录 hash、长度、业务 ID 和短摘要。
- Web UI 通过 `diagnostics.clientLog` 上报 `window.onerror`、`unhandledrejection` 和关键 `console.warn/error`；bridge 请求只记录 payload 摘要。
- QA 实时接口：`GET /logs/recent?limit=200&level=&category=&since=`、`GET /logs/stream?level=&category=`、`GET /logs/files`、`GET /logs/export`。

## 跟读功能排查工作流

跟读流程：

```text
1. NlpService.splitSentences(text)          -> List<String>
2. TtsService.synthesize(sentence)          -> List<int> MP3 bytes
3. just_audio AudioPlayer.play(bytes)       -> play audio
4. record AudioRecorder.start(path)         -> start recording WAV
5. record AudioRecorder.stop()              -> WAV file path
6. RecognitionBasedAssessmentEngine.assess -> BigASR recognize + heuristic score
7. ScoreDisplayWidget.show(result)          -> render score
```

排查关键文件：

- `app/lib/services/tts_service.dart`
- `app/lib/services/streaming_asr_service.dart`
- `app/lib/services/recognition_based_assessment_service.dart`
- `app/lib/services/scoring_service.dart`（仅保留兼容数据结构 / mock stub）
- `app/lib/features/follow_read/providers/follow_read_provider.dart`
- `app/lib/features/follow_read/follow_read_screen.dart`
- `app/lib/features/web_shell/web_shell_screen.dart`
- `app/android/app/src/main/AndroidManifest.xml`
- `app/android/app/build.gradle.kts`

常见检查项：

- WAV 是否为 16kHz 16bit mono PCM。
- BigASR WebSocket 是否拿到非空识别文本。
- `RecognitionBasedAssessmentEngine` 是否正确处理空识别、错词、漏读和 mock fallback。
- `just_audio` 播放完毕事件是否正确触发下一步。
- Provider 的 `isRecording` 状态是否被 UI 正确监听。
- WebView bridge 是否把 `follow.state` / `avatar.state` 推给 Web UI。
- Android 是否声明并实际申请 `RECORD_AUDIO` 权限。
- 模拟器问题优先用 `.\tools\run_android_debug.ps1` 复现。

## 重要禁止项

- 不要引入 `dio` 以外的 HTTP 库。
- 不要硬编码 API Key。
- 不要硬编码项目主题色。
- 不要在 Widget 中直接 `await` API 调用。
- 不要把 API 原始 JSON 直接传给 Widget。
- 不要随意修改 `pubspec.yaml` 中已有依赖版本。
- 不要把 Ark 文本补全重新作为聊天主链路。
- 不要重新引入 Azure Speech 配置、依赖或 Pronunciation Assessment 调用。
- 不要把标准中英对照故事整篇直接送给 AI 做英文提取/翻译；必须先本地解析并复用英文原文、中文对照和标题信息。
- 不要对已经有本地缓存或导入译文的数据重复调用 TTS、Realtime、BigASR、图片生成或翻译接口。
- 不要移除 Android 构建稳定性相关配置：
  - `android.overridePathCheck=true`
  - `kotlin.compiler.execution.strategy=in-process`
  - `hooks.user_defines.sqlite3.source: system`
  - `hooks.user_defines.sqlite3.name_windows: winsqlite3`
- 不要把旧包名 `com.example.english_love_reading` 重新引入源码。
- 不要只给裸 `flutter` 命令来处理构建、发布或模拟器任务，优先复用根目录脚本。

## 工作方式

- 修改前先搜索并阅读相关代码，确认现有结构。
- 每次修改聚焦一个明确关注点。
- 修改后检查 null safety、import 路径、Provider 生成文件引用和主题使用是否正确。
- 涉及构建、发布或运行时，优先执行根目录脚本进行验证。
- 如果失败，先定位脚本层或配置层原因，再给出结论。
