# Tomato English Happy Talking

Tomato English Happy Talking 是一个基于 Flutter 的独立英语学习 App，支持 Windows EXE 和 Android APK 双平台运行。

应用直接调用云 REST API，不依赖本地后端或中间服务。当前项目重点覆盖英文文章导入、逐句跟读、发音评分、AI 对话练习，以及本地学习记录管理。

## 核心功能

- 文章导入与本地分句处理
- 书籍与章节列表：首页按书籍组织文章，章节封面图和章节名可直接进入跟读
- 跟读模式：TTS 播放、录音、基于识别的评分反馈
- AI 聊天模式：基于文章内容的英文对话练习
- 本地学习记录与 API 配置管理
- Web UI 虚拟伙伴与音频交互状态反馈
- 本地 WebView 独立 UI：React/Vite 页面随 App 打包，Flutter 负责原生能力与云服务调用

## 近期实现状态（2026-06）

- UI 已独立为本地 WebView 页面：Flutter 保留数据库、录音、播放、TTS、ASR、AI 对话和安全存储，React/Vite Web UI 负责全页面展示与游戏化交互。
- 首页已简化为闯关入口、学习统计和书籍/章节列表；章节列表的排序与上一页/下一页翻页控件合并展示，章节封面图和章节名称都可点击进入跟读。
- 跟读页和听力页的顶部标题改为书籍名、章节名两行展示，章节名字号略小，避免长书名和章节名挤在同一行。
- 聊天主链路已切到 Realtime V3 二进制 WebSocket 协议，结合 BigASR 负责语音识别，不再把 Ark 文本聊天作为主路径。
- 一次性文本生成任务已拆到 Ark Chat Completions HTTP 通道，英文练习文章、标题、翻译和单词解释由 `PracticeTextService` 统一处理。
- 聊天与跟读共用逐句播放状态 UI：等待播放时先显示动态省略号；真正开始播放后显示文本并尾随省略号；失败时显示错误图标；每句都支持重播。
- 绘本链路新增 `ChapterStoryOutlineService`：先生成并缓存章节结构化分镜提纲（`chapter_story_outline_v1`），再按分镜顺序生成整章图片，默认覆盖完整章节并限制在最多 14 段。
- 绘本图片生成切换为顺序组图模式：`PictureBookService` 优先通过 `VolcImageService.generatePictureBookImageGroup(..., useSequential: true)` 一次请求整章，页级重试仍可单页补图。
- 绘本状态与重试链路补强：新增 page image payload 和缺失缓存文件判定（“绘本缓存文件丢失，请重试生成”），并在 Flutter/Web 双侧增加 in-flight 去重，避免重复点击触发并发重试。
- `VolcImageService` 的组图接收超时改为按图片数动态计算，支持通过 `TOMATO_VOLC_IMAGE_SECONDS_PER_IMAGE`、`TOMATO_VOLC_IMAGE_MIN_RECEIVE_TIMEOUT_SECONDS`、`TOMATO_VOLC_IMAGE_MAX_RECEIVE_TIMEOUT_SECONDS` 调整。
- 跟读翻译缓存修复：当句子翻译返回“中文翻译暂不可用”时不再长期污染内存缓存，后续重试可命中真实翻译结果。
- 听力模式主按钮文案改为“开始播放”，并从当前选中句开始播放（默认第 1 句，用户切换后按所选句起播）。
- Windows 构建脚本增强了 `-DartDefine` 兼容性：支持数组输入和逗号分隔键值，避免联调时 define 参数被整体吞并。
- 新增统一诊断日志系统：启动、bridge、QA、WebView、Suno、TTS、ASR、聊天、跟读、听力、录制和绘本链路会写入发布运行目录 `logs/`，QA 接口支持 recent / SSE stream / export。
- 听力页新增全屏播放录制导出：支持 H.264 / H.265、2560x1440 / 1920x1080 / 1280x720、绘本页转场、进度回传、取消录制和同名 SRT 字幕，音频直接复用已缓存 MP3。
- 听力歌曲链路补齐 Suno 自动化与 MiniMax 生成：保存并复用风格提示，展示多版本歌曲，下载前校验当前歌曲/歌词/风格匹配，避免误下载旧歌或错歌。
- 听力歌曲弹窗拆为“播放 / 设置”页签：已下载歌曲按风格分组播放；Suno 会记录同一风格检测到的完整歌曲链接，只下载缺失版本，已完整下载的风格进入待命状态而不重复消耗 credits。
- TTS 新增内存热缓存与预加载状态：听力、跟读和聊天播放可复用同一套缓存，录制前会检查英文/中文音频准备度，避免播放中临时合成或读盘等待。
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
│   ├── TextGenerationService (Ark HTTP chat completions)
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
    └── Volcengine Ark Chat Completions

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
| Ark Chat Completions | 一次性文本生成、翻译、标题、单词解释 | `https://ark.cn-beijing.volces.com/api/v3/chat/completions` |

所有 API Key 都通过 `AppConfig` 读取，不应硬编码在源码中，也不在应用设置页中手动输入。

当前仓库的本机密钥材料以明文凭证文件保存在 `security/` 目录下：

- `security/speech-api-key.txt`：豆包语音新版 API Key，供 TTS、Realtime、BigASR 使用。
- `security/ark.txt`：方舟 Bearer API Key 和模型，供一次性文本任务与绘本图片生成使用。

Windows 发布目录运行时会从 exe 所在目录向上查找这些文件。旧的加密注入方案已移除。

当前迁移涉及的关键凭证字段仅记录为配置项，不应把真实密钥写入仓库文档：

- 豆包语音新版 API Key：`volc_speech_api_key` / `TOMATO_VOLC_SPEECH_API_KEY`
- Doubao TTS 2.0：`X-Api-Key` 使用语音 API Key，`X-Api-Resource-Id` 当前计划值为 `seed-tts-2.0`
- Realtime 语音对话：仅使用新版 `X-Api-Key`
- BigASR 识别：`X-Api-Key` 使用语音 API Key
- Ark 文本生成：`volc_ark_api_key` / `TOMATO_VOLC_ARK_API_KEY`，模型 `volc_ark_text_model` / `TOMATO_VOLC_ARK_TEXT_MODEL`
- Ark 图片生成：`volc_ark_api_key` / `TOMATO_VOLC_ARK_API_KEY`，模型默认 `doubao-seedream-5-0-260128`

当前程序内已内置 `docs/豆包语音合成模型2.0 音色列表.md` 中 “豆包语音合成模型2.0” 表的官方音色预置。设置页只保留声音选择，不展示或填写 API Key、BigASR、Realtime 等密钥/服务配置。英文学习场景默认使用 `en_female_dacey_uranus_bigtts`。

### 本机 API Key 注入方案

- 当前代码已在应用启动时执行 `AppConfig.seedSecureStorageFromEnvironment()`，并直接从发布目录/项目目录附近查找 `security/speech-api-key.txt` 和 `security/ark.txt`。
- 推荐方式是维护 `security/speech-api-key.txt` 与 `security/ark.txt`，运行期统一通过 `AppConfig` 读取，不依赖终端用户手动输入。
- `security/ark.txt` 推荐使用标签多行格式：

```text
ARK_API_KEY=your-ark-bearer-key
ARK_TEXT_MODEL=doubao-seed-2-0-lite-260215
```

- 未配置 `ARK_TEXT_MODEL` 时默认使用 `doubao-seed-2-0-lite-260215`；无标签多行文件只把最长的 32+ 字符行作为 key，不从无标签行推断模型。
- `--dart-define` 仍保留为调试注入方式。
- 当前已支持的本机注入字段包括：
  - `TOMATO_VOLC_SPEECH_API_KEY`
  - `TOMATO_VOLC_TTS_RESOURCE_ID`
  - `TOMATO_VOLC_TTS_SPEAKER_ID`
  - `TOMATO_VOLC_ARK_API_KEY`
  - `TOMATO_VOLC_ARK_TEXT_MODEL`
  - `TOMATO_VOLC_ARK_IMAGE_MODEL`
- 旧的统一语音 key 和分服务语音 key 字段不再作为兜底。
- 推荐最小注入示例：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine `
  "TOMATO_VOLC_SPEECH_API_KEY=your-speech-key", `
  "TOMATO_VOLC_TTS_RESOURCE_ID=seed-tts-2.0", `
  "TOMATO_VOLC_TTS_SPEAKER_ID=en_female_dacey_uranus_bigtts"
```

- Android 调试可直接使用：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\run_android_debug.ps1 -DartDefine `
  "TOMATO_VOLC_SPEECH_API_KEY=your-speech-key", `
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
- `RealtimeVoiceService` 只负责实时英语对话会话；文章生成、标题、翻译、单词解释等一次性文本任务走 Ark HTTP 文本通道。
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
