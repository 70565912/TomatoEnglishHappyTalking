# Tomato English Happy Talking

Tomato English Happy Talking 是一个基于 Flutter 的独立英语学习 App，支持 Windows EXE 和 Android APK 双平台运行。

应用直接调用云 REST API，不依赖本地后端或中间服务。当前项目重点覆盖英文文章导入、逐句跟读、发音评分、AI 对话练习，以及本地学习记录管理。

## 核心功能

- 文章导入与本地分句处理
- 跟读模式：TTS 播放、录音、基于识别的评分反馈
- AI 聊天模式：基于文章内容的英文对话练习
- 本地学习记录与 API 配置管理
- Web UI 虚拟伙伴与音频交互状态反馈
- 本地 WebView 独立 UI：React/Vite 页面随 App 打包，Flutter 负责原生能力与云服务调用

## 近期实现状态（2026-05）

- UI 已独立为本地 WebView 页面：Flutter 保留数据库、录音、播放、TTS、ASR、AI 对话和安全存储，React/Vite Web UI 负责全页面展示与游戏化交互。
- 聊天主链路已切到 Realtime V3 二进制 WebSocket 协议，结合 BigASR 负责语音识别，不再把 Ark 文本聊天作为主路径。
- 聊天与跟读共用逐句播放状态 UI：等待播放时先显示动态省略号；真正开始播放后显示文本并尾随省略号；失败时显示错误图标；每句都支持重播。
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

Windows 调试运行：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run
```

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

Web UI 本地调试：

```powershell
cd f:\TomatoEnglishHappyTalking\web_ui
npm run dev

cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_WEB_UI_DEV_URL=http://127.0.0.1:5173"
```

常规 Windows / Android 构建脚本会自动执行 `npm ci` 或 `npm install`，再执行 `npm run build`，并把最新 Web UI 产物写入 `app/assets/web/` 后打包进 EXE/APK。

## 构建脚本说明

### `tools/build_windows.ps1`

- `-Run`：运行 Windows Debug
- `-Release`：构建 Windows Release
- `-Release -Run`：构建并运行 Windows Release
- 自动清理旧的 Windows CMake 缓存，避免改名后仍引用旧目标名

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
| 端到端实时语音大模型 | 实时语音对话 / 文本 query | WebSocket 会话接口（事件协议） |
| BigASR | 聊天与跟读语音识别 | WebSocket ASR 接口 |

所有 API Key 都通过 `AppConfig` 读取，不应硬编码在源码中，也不在应用设置页中手动输入。

当前仓库的本机密钥材料以密文形式保存在 `security/` 目录下：

- `security/api-key.txt`：密文载荷
- `security/api-key.key.txt`：本机解密 key

应用启动时会优先尝试从该密文文件解密并注入运行时配置；Windows 发布目录运行时会从 exe 所在目录向上查找 `security/`。

当前迁移涉及的关键凭证字段仅记录为配置项，不应把真实密钥写入仓库文档：

- 火山引擎统一 API Key：`volc_api_key` / `TOMATO_VOLC_API_KEY`
- Doubao TTS 2.0：`X-Api-Key` 使用统一 API Key，`X-Api-Resource-Id` 当前计划值为 `seed-tts-2.0`
- Realtime 语音对话：推荐 `X-Api-Key`，使用统一 API Key
- Realtime 语音对话兼容字段：`X-Api-App-ID`、`X-Api-Access-Key`、`X-Api-Resource-Id=volc.speech.dialog`、`X-Api-App-Key=PlgvMymc7f3tQnJ6`
- BigASR 识别：`X-Api-Key` 使用统一 API Key

当前程序内已内置一组来自火山引擎公开文档的 Doubao TTS 2.0 官方音色预置，设置页只展示当前运行时读取到的音色状态：

- `en_female_dacey_uranus_bigtts`
- `en_male_tim_uranus_bigtts`
- `en_female_stokie_uranus_bigtts`
- `zh_female_yingyujiaoxue_uranus_bigtts`

这些音色 ID 依据火山引擎公开文档“音色列表”页整理，英文学习场景默认优先使用英文音色。

### 本机 API Key 注入方案

- 当前代码已在应用启动时执行 `AppConfig.seedSecureStorageFromEncryptedFile()` 和 `AppConfig.seedSecureStorageFromEnvironment()`。
- 推荐方式是维护 `security/api-key.txt` 与 `security/api-key.key.txt` 两个本机加密配置文件，运行期统一通过 `AppConfig` 读取，不依赖终端用户手动输入。
- `--dart-define` 仍保留为调试/兼容注入方式。
- 当前已支持的本机注入字段包括：
  - `TOMATO_VOLC_API_KEY`
  - `TOMATO_VOLC_TTS_RESOURCE_ID`
  - `TOMATO_VOLC_TTS_SPEAKER_ID`
  - `TOMATO_VOLC_REALTIME_APP_ID`
- 旧字段 `TOMATO_VOLC_TTS_API_KEY`、`TOMATO_VOLC_REALTIME_API_KEY`、`TOMATO_VOLC_BIGASR_API_KEY` 仍会被兼容读取并合并到统一 `volc_api_key`，新配置不要再拆分填写。
- `TOMATO_VOLC_REALTIME_APP_ID` 仅在 Realtime 回退旧鉴权头时需要，推荐的 API-key 模式下可以留空。
- 推荐最小注入示例：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine `
  "TOMATO_VOLC_API_KEY=your-shared-key", `
  "TOMATO_VOLC_TTS_RESOURCE_ID=seed-tts-2.0", `
  "TOMATO_VOLC_TTS_SPEAKER_ID=en_female_dacey_uranus_bigtts"
```

- 如需兼容 Realtime 旧鉴权头，可额外传入：`TOMATO_VOLC_REALTIME_APP_ID`。

- Android 调试可直接使用：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\run_android_debug.ps1 -DartDefine `
  "TOMATO_VOLC_API_KEY=your-shared-key", `
  "TOMATO_VOLC_TTS_RESOURCE_ID=seed-tts-2.0", `
  "TOMATO_VOLC_TTS_SPEAKER_ID=en_female_dacey_uranus_bigtts"
```

### 聊天 / 跟读播放故障日志追踪（TTS / 播放器）

- 运行时可开启音频链路 trace：`TOMATO_AUDIO_TRACE=true`
- 开启后会输出：
  - `TtsTrace`：请求参数摘要、分片包统计、返回字节数、服务端失败信息
  - `ChatTrace`：聊天播放状态迁移、AI 回复播放启动/完成判定、重播链路日志
  - `FollowReadTrace`：状态迁移、临时音频文件路径、播放器状态与错误

Windows 调试示例：

```powershell
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine `
  "TOMATO_AUDIO_TRACE=true"
```

当出现“聊天无声”或“跟读播放失败”时，请保留终端中最近的 `TtsTrace`、`ChatTrace` 与 `FollowReadTrace` 日志片段，便于快速定位是：
- 云端 TTS 返回异常
- 音频落盘/解码异常
- 播放器状态卡死或超时

### Realtime V3 二进制协议（已接入）

- 聊天 WebSocket 端点：`wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- 推荐握手头：`X-Api-Key`、`X-Api-Resource-Id: volc.speech.dialog`、`X-Api-Connect-Id`
- 若 API-key 握手失败且已配置 `App ID`，客户端会自动回退旧鉴权头：`X-Api-App-ID`、`X-Api-Access-Key`、`X-Api-App-Key`、`X-Api-Resource-Id`
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
