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
- 当前主 UI 是 `web_ui` 打包后的本地 WebView 页面；Flutter 的 `WebShellScreen` 负责桥接数据库、录音、播放、TTS、ASR、AI 对话和安全配置。
- `app/lib/features/home|article|follow_read|chat|profile` 下的原生 Screen 仍可作为参考/兼容层，但默认路由进入 `WebShellScreen`。
- Web UI 与 Flutter 交互时必须通过 `web_bridge_protocol.dart` / `bridge.ts` 的 typed command/event 协议，不要从 Web UI 直接访问云 API 或本地文件系统。

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

### 云服务端点

Doubao TTS 2.0：

- 端点：`https://openspeech.bytedance.com/api/v3/tts/unidirectional`
- 鉴权：Header `X-Api-Key`、`X-Api-Resource-Id`、可选 `X-Api-Request-Id`
- 默认 Resource ID：`seed-tts-2.0`
- 返回 HTTP chunked JSON 行，`data` 字段为 Base64 MP3 分片，按顺序解码合并后交给 `just_audio`

Realtime V3 AI 对话：

- 端点：`wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- 推荐鉴权：`X-Api-Key`、`X-Api-Resource-Id: volc.speech.dialog`、`X-Api-Connect-Id`
- 兼容回退鉴权：`X-Api-App-ID`、`X-Api-Access-Key`、`X-Api-App-Key`
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

- 统一火山引擎密钥字段：`volc_api_key` / `TOMATO_VOLC_API_KEY`
- 推荐本机注入：`security/api-key.txt` + `security/api-key.key.txt`，由 `AppConfig.seedSecureStorageFromEncryptedFile()` 启动时解密到运行时配置
- 调试兼容注入：`--dart-define TOMATO_VOLC_API_KEY=...`
- 旧字段 `TOMATO_VOLC_TTS_API_KEY`、`TOMATO_VOLC_REALTIME_API_KEY`、`TOMATO_VOLC_BIGASR_API_KEY` 只做兼容读取，新配置不要再拆分填写
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

## 构建、运行与发布

处理构建、发布、模拟器任务时，优先复用根目录 PowerShell 脚本，不要只给一次性裸终端命令。

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

- Windows 构建输出：`app\build\windows\x64\runner\Release\tomato_english_happy_talking.exe`
- Windows 发布目录：`release\windows\tomato_english_happy_talking\`
- Android 构建输出：`app\build\app\outputs\flutter-apk\app-release.apk`
- Android 发布 APK：`release\android\tomato_english_happy_talking-android-release.apk`
- Web UI 构建输出 / App 内置资源：`app\assets\web\`（由 `web_ui/vite.config.ts` 的 `outDir` 指定）

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
- 错误时 `debugPrint` 并返回 `null` 或 fallback。
- 不修改 `pubspec.yaml` 既有依赖版本，除非任务明确要求。

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
