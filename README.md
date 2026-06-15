# Tomato English Happy Talking

Tomato English Happy Talking 是一个基于 Flutter 的独立英语学习 App，支持 Windows EXE 和 Android APK 双平台运行。

应用直接调用云 REST API，不依赖本地后端或中间服务。当前项目重点覆盖书籍/章节管理、章节连续听力、绘本、百炼 fun-music / Suno 歌曲创作、逐句跟读、发音评分、AI 对话练习，以及本地学习记录管理。

## 核心功能

- 文章导入与本地分句处理，保存为书籍下的章节
- 书库、书籍详情与章节播放器：按书籍组织章节，支持听力/歌曲模式
- 创作中心：集中管理绘本组图、百炼 fun-music / Suno 歌曲、字幕时间轴和视频导出
- 跟读模式：TTS 播放、录音、基于识别的评分反馈
- AI 聊天模式：基于文章内容的英文对话练习
- 本地学习记录与 API 配置管理
- Web UI 虚拟伙伴与音频交互状态反馈
- 本地 WebView 独立 UI：React/Vite 页面随 App 打包，Flutter 负责原生能力与云服务调用

## 近期实现状态（2026-06）

- UI 已独立为本地 WebView 页面：Flutter 保留数据库、录音、播放、TTS、ASR、AI 对话和安全存储，React/Vite Web UI 负责全页面展示与游戏化交互。
- 产品 UI 已从游戏大厅切换为书库、创作中心、练习中心和设置主导航；`docs/product_ui_refactor_plan.md` 记录后续拆分、迁移和验收计划。
- 首页已改为书库工作台，书籍详情展示章节目录、连续听力、歌曲模式和练习入口；章节封面图和章节名称可进入章节相关流程。
- 跟读页和听力页的顶部标题改为书籍名、章节名两行展示，章节名字号略小，避免长书名和章节名挤在同一行。
- 聊天主链路已切到 Realtime V3 二进制 WebSocket 协议，结合 BigASR 负责语音识别，不再把 Ark 文本聊天作为主路径。
- 一次性文本生成任务已拆到 OpenAI-compatible Chat Completions HTTP 通道，默认使用阿里云百炼，也可切换火山方舟；英文练习文章、标题、翻译和单词解释由 `PracticeTextService` 统一处理。
- 聊天与跟读共用逐句播放状态 UI：等待播放时先显示动态省略号；真正开始播放后显示文本并尾随省略号；失败时显示错误图标；每句都支持重播。
- 绘本链路使用 `ChapterStoryOutlineService` 复用章节结构化分镜提纲（`chapter_story_outline_v1`）作为对话提纲和规划上下文；组图生成由 v4 审核计划驱动，默认最多 14 段覆盖完整章节。
- 绘本图片生成切换为顺序组图模式：`PictureBookService` 优先通过 `VolcImageService.generatePictureBookImageGroup(..., useSequential: true)` 一次请求整章；重试入口会重新打开提示词审核并在确认后重建整章组图。
- 绘本 prompt policy 升级为 `picture_book_prompt_v4` / `picture_book_chapter_plan_v4`：保存章节后先打开提示词审核，用户确认 `groupPrompt` 后才提交 Seedream 顺序组图；旧 series Bible、角色卡、参考图、`negativePrompt` 和字幕留白字段已下线。
- 书籍模型简化为标题 + `description`；书籍简介作为跨章节视觉一致性的人工维护上下文，SQLite schema v7 移除了 `story_series.style_guide_json`、`story_series.bible_json` 和 `story_reference_assets`。
- 绘本状态与重试链路补强：新增 page image payload 和缺失缓存文件判定（“绘本缓存文件丢失，请重试生成”），并在 Flutter/Web 双侧增加 in-flight 去重，避免重复点击触发并发重试；创作中心列表使用 `pictureBook.pageImage` 的 `thumbnail` variant 生成持久缩略图，避免一次性加载整章原图。
- `VolcImageService` 的组图接收超时改为按图片数动态计算，支持通过 `TOMATO_VOLC_IMAGE_SECONDS_PER_IMAGE`、`TOMATO_VOLC_IMAGE_MIN_RECEIVE_TIMEOUT_SECONDS`、`TOMATO_VOLC_IMAGE_MAX_RECEIVE_TIMEOUT_SECONDS` 调整。
- 跟读翻译缓存修复：当句子翻译返回“中文翻译暂不可用”时不再长期污染内存缓存，后续重试可命中真实翻译结果。
- 听力模式主按钮文案改为“开始播放”，并从当前选中句开始播放（默认第 1 句，用户切换后按所选句起播）。
- Windows 构建脚本增强了 `-DartDefine` 兼容性：支持数组输入和逗号分隔键值，避免联调时 define 参数被整体吞并。
- 新增统一诊断日志系统：启动、bridge、QA、WebView、Suno、TTS、ASR、聊天、跟读、听力、录制和绘本链路会写入发布运行目录 `logs/`，QA 接口支持 recent / SSE stream / export。
- 听力页新增全屏播放录制导出：支持 H.264 / H.265、2560x1440 / 1920x1080 / 1280x720、绘本页转场、进度回传、取消录制和同名 SRT 字幕，音频直接复用已缓存 MP3。
- 歌曲生成入口支持百炼 fun-music、Suno 网页自动化和本地歌曲版本库，MiniMax API、mock 和测试入口已清理。
- 听力歌曲弹窗拆为“播放 / 生成”页签：已下载歌曲按本地版本播放；百炼 fun-music 可直接按当前英文歌词生成音频，Suno 仍按当前歌词记录检测到的完整歌曲链接并只下载缺失 `songUrl`。
- 本地歌曲版本新增默认播放标记，Web UI 可把指定歌曲版本设为默认，Native 播放时优先选择默认版本。
- 歌曲字幕时间轴使用 BigASR 词级时间对齐 App 提交给歌曲 provider 的原歌词，播放歌曲时按进度切换英文字幕，并可先生成字幕再导出歌曲版绘本视频。
- Suno 下载音频和 metadata 会迁移到程序运行目录 `suno-music/`；百炼 fun-music 成功音频写入 `ApiCacheService` 的 `music/` 缓存目录。Windows 发布脚本会保留运行数据，避免重新发布丢失歌曲资产。
- 听力播放和录制统一为英文音频：中文翻译在文章保存时生成或复用导入译文，用作字幕显示，不再为听力播放临时合成中文 TTS；全屏 readiness 只预热当前和下一句英文音频、当前和下一张绘本图。
- TTS 新增内存热缓存与预加载状态：听力、跟读和聊天播放可复用同一套缓存，听力全屏和录制前会检查英文音频准备度，避免播放中临时合成或读盘等待。
- 跟读录音新增实时识别自动停止：当识别文本覆盖参考句并匹配句尾时，自动结束录音并进入评分，减少手动停止操作。
- 标准中英对照和混合英文原文解析增强：可跳过拓展、背景、难句解析、Teacher's Note、词汇和答案等插入段落，并在故事正文恢复时继续保留完整英文。
- Windows Debug 构建运行现在会同步 Debug 程序、`ffmpeg.exe` 和依赖 DLL 到 `release\windows\tomato_english_happy_talking\` 后再启动，避免录制/导出误读 Debug 中间目录。
- 章节列表分页控件已统一按钮与页码信息的字号、字重和行高，避免“上一页/下一页”与“第 x / y 页”视觉不协调。
- 绘本场景中“正在播放”字幕高亮改为白色；“绘本缓存文件丢失，请重试生成”等占位提示已上移到图标下方，减少与字幕重叠。
- Windows 端播放完成判定已改为基于实际播放进度，而不是仅依赖 `just_audio_windows` 的状态回调，降低“状态已完成但实际无声”的误判。

## 当前项目标识

- Flutter 包名：`tomato_english_happy_talking`
- 应用显示名：`Tomato English Happy Talking`
- Android package / namespace：`com.example.tomato_english_happy_talking`
- Windows 可执行文件名：`tomato_english_happy_talking.exe`

## 技术栈

- Flutter 3.41.9
- Dart（sound null safety）
- `flutter_riverpod` + `riverpod_annotation`
- `go_router`
- `flutter_inappwebview`
- React + Vite + TypeScript（本地 Web UI）
- `dio`
- `sqflite` + `path`
- `flutter_secure_storage`
- `just_audio`
- `record`
- `audio_waveforms`
- `rive` / `lottie`（原生动画依赖保留）
- `flutter_animate`
- `google_fonts`（Nunito）


## 架构概览

```text
Flutter App
├── WebShellScreen / Bridge Protocol
├── Riverpod Providers
├── Services
│   ├── TtsService (Doubao TTS 2.0 for playback)
│   ├── RealtimeVoiceService (V3 binary websocket dialogue)
│   ├── TextGenerationService (OpenAI-compatible chat completions)
│   ├── BailianMusicService (Aliyun Bailian fun-music generation)
│   ├── PracticeTextService (practice article/title/translation/word lookup)
│   ├── StreamingAsrService (BigASR recognition)
│   ├── ScoringService (legacy, deprecated)
│   └── NlpService (local sentence splitting)
├── Local Storage
│   ├── sqflite
│   └── flutter_secure_storage
└── Cloud APIs
    ├── Volcengine TTS 2.0
    ├── Volcengine Realtime Voice
    ├── Volcengine BigASR
    ├── Aliyun Bailian Chat Completions / fun-music
    └── Volcengine Ark Chat / Image Completions

React/Vite Web UI
├── hash route pages
├── bridge.ts native commands
└── avatar / game state rendering
```

## 项目结构

```text
TomatoEnglishHappyTalking/
├── app/
│   ├── lib/
│   │   ├── core/
│   │   ├── data/
│   │   ├── features/
│   │   ├── services/
│   │   └── shared/
│   ├── assets/web/          # React/Vite 构建后的本地 Web UI
│   ├── android/
│   ├── windows/
│   └── pubspec.yaml
├── web_ui/                  # React + Vite + TypeScript UI 工程
├── tools/
│   ├── build_windows.ps1
│   ├── build_android.ps1
│   ├── run_android_debug.ps1
│   └── setup_android_emulator.ps1
├── release/
└── README.md
```

## 本地环境

- Flutter SDK：`D:\DevTools\flutter`
- Android SDK：`D:\Android\SDK`
- Android 用户目录：`D:\Android\.android`
- AVD 目录：`D:\Android\.android\avd`
- 当前默认模拟器：`EnglishRead_API_35`
- Windows WebView：需要安装 Microsoft Edge WebView2 Runtime

建议在新终端设置国内镜像环境：

```powershell
$env:PATH = "D:\DevTools\flutter\bin;" + $env:PATH
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

## 快速开始

安装依赖：

```powershell
cd f:\TomatoEnglishHappyTalking\app
flutter pub get
```

Codex / 自动化会话中，Flutter 相关命令请直接在已授权的沙箱外 PowerShell 执行；当前环境已验证受限沙箱会卡在 Flutter SDK cache lockfile。示例：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1'
```

Windows 调试运行：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run
```

Debug 会先构建到 `app\build\windows\x64\runner\Debug\`，再同步到 `release\windows\tomato_english_happy_talking\` 并从该目录启动，确保 `ffmpeg.exe`、依赖 DLL 和桌面运行数据都在同一个程序目录下。

Windows Release 构建：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Release
```

Android Release 构建并同步到 `release/`：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_android.ps1
```

启动模拟器并运行 Android Debug：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\run_android_debug.ps1
```

初始化或重建 Android 模拟器环境：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\setup_android_emulator.ps1 -Start
```

Web UI 静态预览（只打开 `index.html` 构建产物，不启动 Flutter）：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\preview_web_ui.ps1
```

Web UI 本地联调：

```powershell
cd f:\TomatoEnglishHappyTalking\web_ui
npm run dev

cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_WEB_UI_DEV_URL=http://127.0.0.1:5173"
```

常规 Windows / Android 构建脚本会自动执行 `npm ci` 或 `npm install`，再执行 `npm run build`，并把最新 Web UI 产物写入 `app/assets/web/` 后打包进 EXE/APK。

## 构建脚本说明

### `tools/build_windows.ps1`

- `-Run`：构建 Windows Debug，同步到 `release\windows\tomato_english_happy_talking\` 并从该目录启动
- `-Release`：构建 Windows Release
- `-Release -Run`：构建并运行 Windows Release
- 自动清理旧的 Windows CMake 缓存，避免改名后仍引用旧目标名
- Debug 和 Release 最终运行目录都使用 `release\windows\tomato_english_happy_talking\`；不要直接运行 `app\build\windows\x64\runner\Debug\` 下的 EXE 验证录屏或视频导出。

### `tools/build_android.ps1`

- 默认：构建 Android Release APK 并复制到 `release/android/`
- `-Run`：在已连接设备或模拟器上运行 Debug
- `-Release -Run`：以 Release 模式运行

### `tools/run_android_debug.ps1`

- 优先复用当前已在线模拟器
- 如无在线模拟器，则启动 `EnglishRead_API_35`
- 等待系统启动完成后调用 `tools/build_android.ps1 -Run`

### `tools/setup_android_emulator.ps1`

- 安装 Android SDK / emulator / system image
- 创建或复用 `EnglishRead_API_35`
- 可直接启动模拟器

## 构建产物

- Windows 构建输出：`app/build/windows/x64/runner/Release/tomato_english_happy_talking.exe`
- Windows 发布目录：`release/windows/tomato_english_happy_talking/`
- Android 构建输出：`app/build/app/outputs/flutter-apk/app-release.apk`
- Android 发布目录：`release/android/tomato_english_happy_talking-android-release.apk`

## 云服务

| 服务 | 用途 | 端点 |
| ---- | ---- | ---- |
| Doubao TTS 2.0 | 英文语音合成 | `https://openspeech.bytedance.com/api/v3/tts/unidirectional` |
| 端到端实时语音大模型 | 实时英语对话 | WebSocket 会话接口（事件协议） |
| BigASR | 聊天与跟读语音识别 | WebSocket ASR 接口 |
| 阿里云百炼 Chat Completions | 默认一次性文本生成、翻译、标题、单词解释 | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` |
| 阿里云百炼 fun-music | 歌曲音频生成 | `https://dashscope.aliyuncs.com/api/v1/services/audio/music/generation` |
| Ark Chat / Image Completions | 可选文本 provider、Seedream 绘本组图 | `https://ark.cn-beijing.volces.com/api/v3/...` |

所有 API Key 都通过 `AppConfig` 读取，不应硬编码在源码或文档中。设置页可保存/清除百炼、方舟和语音 key；bridge payload 只返回是否已配置和脱敏 mask，不返回明文。

当前代码不再从工作目录或发布目录自动读取 `security/speech-api-key.txt`、`security/ark.txt` 等 legacy 明文 key 文件。运行期配置存入 `flutter_secure_storage`，测试可用 `AppConfig.setRuntimeConfigForTest` 注入。

当前关键配置字段：

- 豆包语音新版 API Key：`volc_speech_api_key`，供 TTS、Realtime、BigASR 共用。
- Doubao TTS 2.0：`X-Api-Key` 使用语音 API Key，`X-Api-Resource-Id` 默认 `seed-tts-2.0`。
- Realtime 语音对话：仅使用新版 `X-Api-Key`。
- BigASR 识别：`X-Api-Key` 使用语音 API Key。
- 文本生成 provider：`ai_provider`，默认 `aliyun_bailian`，可切换 `volcengine`。
- 阿里云百炼：`aliyun_bailian_api_key`、`aliyun_bailian_base_url`、`aliyun_bailian_text_model`、`aliyun_bailian_music_model`；默认 base URL `https://dashscope.aliyuncs.com/compatible-mode/v1`，文本模型 `qwen3.7-max`，音乐模型 `fun-music-v1`。
- 火山方舟：`volc_ark_api_key`、`volc_ark_base_url`、`volc_ark_text_model`、`volc_ark_image_model`；图片模型默认 `doubao-seedream-5-0-260128`。

当前程序内已内置 `docs/豆包语音合成模型2.0 音色列表.md` 中 “豆包语音合成模型2.0” 表的官方音色预置。设置页只保留声音选择，不展示或填写 API Key、BigASR、Realtime 等密钥/服务配置。英文学习场景默认使用 `en_female_dacey_uranus_bigtts`。

### 本机 API Key 配置方案

- 推荐在设置页保存/清除百炼、方舟和语音 key；设置页只显示脱敏状态。
- `--dart-define` 目前保留给非密钥的 TTS 资源和音色调试参数。
- 当前支持的调试 define：
  - `TOMATO_VOLC_TTS_RESOURCE_ID`
  - `TOMATO_VOLC_TTS_SPEAKER_ID`
- 推荐最小调试示例：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine `
  "TOMATO_VOLC_TTS_RESOURCE_ID=seed-tts-2.0", `
  "TOMATO_VOLC_TTS_SPEAKER_ID=en_female_dacey_uranus_bigtts"
```

- Android 调试可直接使用：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\run_android_debug.ps1 -DartDefine `
  "TOMATO_VOLC_TTS_RESOURCE_ID=seed-tts-2.0", `
  "TOMATO_VOLC_TTS_SPEAKER_ID=en_female_dacey_uranus_bigtts"
```

### 诊断日志

App 使用统一结构化日志 `TomatoLogger`，日志字段固定为 `ts, level, category, event, message, flowId, articleId, route, stage, status, durationMs, data, error, stack`。默认级别为 `info`，可通过 `TOMATO_LOG_LEVEL=trace|debug|info|warn|error|fatal` 调整，也可用 `TOMATO_LOG_CATEGORIES=bridge,suno,webview` 限定分类。

日志目录解析顺序：

1. `TOMATO_LOG_DIR`
2. `TOMATO_DESKTOP_DATA_ROOT\logs`
3. 桌面程序目录 `logs`

日志使用内存环形缓冲和 NDJSON 文件轮转，默认保留最近 2000 条内存日志，单文件 5 MB，最多 10 个文件或 7 天。日志会脱敏 API key、Bearer、Authorization、cookie、长正文/歌词和绝对路径摘要。

Windows 调试示例：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine `
  "TOMATO_LOG_LEVEL=debug"
```

音频细节 trace 仍由 `TOMATO_AUDIO_TRACE=true` 控制；开启后 `TtsTrace`、`ChatTrace`、`FollowReadTrace` 会进入统一日志。开启 `TOMATO_QA_REMOTE=true` 后，可用 `/logs/recent`、`/logs/stream` 和 `/logs/export` 实时查看或导出诊断包，设置页也提供“导出诊断日志”入口。

### Realtime V3 二进制协议（已接入）

- 聊天 WebSocket 端点：`wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- 推荐握手头：`X-Api-Key`、`X-Api-Resource-Id: volc.speech.dialog`、`X-Api-Connect-Id`
- Realtime 仅使用新版 `X-Api-Key` 鉴权，不再回退旧鉴权头。
- `RealtimeVoiceService` 只负责实时英语对话会话；文章生成、标题、翻译、单词解释等一次性文本任务走 OpenAI-compatible 文本通道。
- 聊天主流程事件固定为：
  - 客户端：`StartConnection(1)` → `StartSession(100)` → `ChatTextQuery(501)` → `FinishSession(102)` → `FinishConnection(2)`
  - 服务端：`ConnectionStarted(50)`、`SessionStarted(150)`、`ChatResponse(550)`、`ChatEnded(559)`、`DialogCommonError(599)`
- `StartSession` 当前会携带 `dialog.extra.model=1.2.1.1`，避免服务端以缺省模型拒绝会话。
- 当前客户端使用文本 query 模式（`dialog.extra.input_mod=text`），AI 回复文本再交由本地 TTS 2.0 播放。

- `tools/build_windows.ps1`、`tools/build_android.ps1`、`tools/run_android_debug.ps1` 已支持透传这些 `-DartDefine` 参数。
- 该方案只解决“仓库中不明文保存密钥”和“本机加密存储”问题，不能真正隐藏公开分发客户端里的平台方统一密钥；如果应用将来面向外部用户发布，仍应改为后端代调或短时令牌方案。

## 当前迁移计划

- 火山引擎 TTS 2.0、实时语音聊天、BigASR 跟读评估的统一评估文档见 `docs/volcengine_migration_plan.md`
- 当前目标产品方向：聊天模式保持端到端实时语音模型主链路；跟读评分已改用 BigASR 识别驱动的自建评分，不再按 Azure 等价评测建模

## 当前改造重点

- Phase 1：完成 Doubao TTS 2.0 的配置、服务解析和设置页迁移（已完成）
- Phase 2：把聊天 STT 从 `ScoringService` 中拆出来，避免和跟读评分耦合（已完成）
- Phase 3：按 WebSocket 会话架构重写聊天语音链路（已完成）
- Phase 4：Follow Read scoring 迁移到识别驱动的自建评分，完全移除 Azure 依赖（已完成）

## 当前实施进度（2026-05）

- 已完成：移除 Ark 作为聊天主链路，聊天主路径切到 Realtime + BigASR。
- 已完成：Follow Read provider 从直连 `ScoringService` 迁到评分接口注入（UI 行为不变）。
- 已完成：学习记录新增可空扩展字段（`token_scores_json`、`evaluation_meta_json`），并补数据库迁移。
- 已完成：评分服务单测覆盖正常 / 超时 / 401 / fallback 场景。
- 已完成：Follow Read 评分迁移到 BigASR 识别驱动的自建评分引擎（移除 Azure 依赖）。
- 已完成：删除所有 Azure 基础设施和配置（AppConfig、Profile、UI）。

详细按文件改造清单见 `docs/volcengine_migration_plan.md` 中的 `Concrete Code Refactor Checklist`。

## 开发约束

- 只使用 `dio` 进行 HTTP 调用
- Widget 不直接 `await` API，通过 Provider 中转
- Service 层负责解析模型，不把原始 JSON 直接传给 UI
- Service 层必须提供 mock fallback，保证无 Key 时也能本地调试
- 处理构建、发布、模拟器任务时，优先复用根目录 PowerShell 脚本
- Android 构建相关配置需保留：
  - `pubspec.yaml` 中 `hooks.user_defines.sqlite3.source: system`
  - `pubspec.yaml` 中 `hooks.user_defines.sqlite3.name_windows: winsqlite3`
  - `app/android/gradle.properties` 中 `android.overridePathCheck=true`
  - `app/android/gradle.properties` 中 `kotlin.compiler.execution.strategy=in-process`

## 参考资源

- Flutter 官方文档：<https://flutter.dev/docs>
- Riverpod：<https://riverpod.dev>
- go_router：<https://pub.dev/packages/go_router>
- 火山引擎：<https://www.volcengine.com>
- Vite：<https://vite.dev>
