# Tomato English Happy Talking — Copilot 项目指引

## 项目概述

「Tomato English Happy Talking」是一个 Flutter 独立 App（无后端服务器），支持 Windows EXE 和 Android APK 双平台。
App 直接调用云 REST API，无需中间服务器。

## 当前项目标识

- **Flutter 包名**: `tomato_english_happy_talking`
- **应用显示名**: `Tomato English Happy Talking`
- **Android package / namespace**: `com.example.tomato_english_happy_talking`
- **Windows 可执行文件名**: `tomato_english_happy_talking.exe`

## 技术栈

- **框架**: Flutter 3.41.9 (stable)，SDK 位于 `D:\DevTools\flutter`
- **语言**: Dart（严格空安全 `sound null safety`）
- **状态管理**: `flutter_riverpod` + `riverpod_annotation`（代码生成风格）
- **路由**: `go_router`
- **HTTP**: `dio`（所有云 API 调用均通过 dio）
- **本地数据库**: `sqflite` + `path`
- **安全存储**: `flutter_secure_storage`（API Key 加密存储）
- **音频播放**: `just_audio`
- **录音**: `record`（录制 WAV/AAC）
- **波形可视化**: `audio_waveforms`
- **动画/虚拟形象**: `rive`
- **UI 动效**: `flutter_animate`
- **字体**: `google_fonts`（Nunito）

## 本地工具链与环境

- **Flutter SDK**: `D:\DevTools\flutter`
- **Android SDK**: `D:\Android\SDK`
- **Android 用户目录**: `D:\Android\.android`
- **AVD 目录**: `D:\Android\.android\avd`
- **当前可用模拟器**: `EnglishRead_API_35`
- 默认网络环境需要设置：
	- `PUB_HOSTED_URL=https://pub.flutter-io.cn`
	- `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

## 当前构建脚本

- **Windows 构建脚本**: `tools\build_windows.ps1`
	- `-Release` 构建 Release 并发布到 `release\windows\tomato_english_happy_talking`
	- `-Run` 运行 Windows Debug，或与 `-Release` 组合运行 Release
	- 脚本已包含旧 CMake 缓存检测与清理逻辑，避免改名后仍引用旧的可执行文件名
- **Android 构建脚本**: `tools\build_android.ps1`
	- 默认构建 Release APK 并复制到 `release\android\tomato_english_happy_talking-android-release.apk`
	- `-Run` 在已连接设备或模拟器上运行 Debug
	- `-Release -Run` 以 Release 模式运行
	- 调试命令示例：`\.\tools\build_android.ps1 -Run`
- **Android Debug 启动脚本**: `tools\run_android_debug.ps1`
	- 负责启动或复用 `EnglishRead_API_35` 模拟器
	- 等待开机完成后调用 `tools\build_android.ps1 -Run`
- **Android 模拟器环境脚本**: `tools\setup_android_emulator.ps1`
	- 安装 SDK/模拟器组件并可创建或启动 AVD

## 云服务（直连，无中间层）

| 服务 | 用途 | 端点 |
|------|------|------|
| 火山引擎 TTS | 语音合成 | `https://openspeech.bytedance.com/api/v1/tts` |
| 火山方舟 Doubao | AI 对话 | `https://ark.cn-beijing.volces.com/api/v3/chat/completions` |
| Azure Speech | 发音评分 | `https://{region}.stt.speech.microsoft.com/...` |

## 项目结构

```
app/lib/
├── main.dart
├── core/
│   ├── config/app_config.dart      # API Key 安全存储
│   ├── theme/app_theme.dart        # 主题（橙色 #FF6B35 + 深蓝 #1A237E）
│   └── router/app_router.dart      # go_router 路由配置
├── services/
│   ├── tts_service.dart            # 火山引擎 TTS
│   ├── scoring_service.dart        # Azure 发音评分
│   ├── ai_service.dart             # 火山方舟 Doubao
│   └── nlp_service.dart            # 本地分句（Dart 正则）
├── data/models/                    # sqflite 数据模型
├── features/
│   ├── home/                       # 首页
│   ├── article/                    # 文章输入与管理
│   ├── follow_read/                # 跟读模式
│   ├── chat/                       # AI 聊天模式
│   └── profile/                    # 学习记录与设置
└── shared/widgets/                 # 公共组件
```

## 代码规范

### 架构
- **Services 层**：只做 API 调用，不持有 UI 状态，返回值或抛出异常
- **Providers 层**：用 `@riverpod` 注解，持有 UI 状态，调用 services
- **Screens/Widgets 层**：只做 UI，通过 `ref.watch` / `ref.read` 读取状态

### Dart 风格
- 必须使用 `null safety`，禁止 `!` 强制解包（除非确实不可空）
- 异步函数全部使用 `async/await`，避免裸 `then()`
- 类名 `UpperCamelCase`，文件名 `snake_case`
- 每个 feature 目录下的 screen 文件命名为 `xxx_screen.dart`

### API 调用安全
- API Key **绝不** 硬编码在源代码中
- 所有 Key 通过 `AppConfig` 从 `flutter_secure_storage` 读取
- API 调用失败时降级到 mock 数据，不崩溃

### UI 主题
- 主色 `AppTheme.primary`（橙色 `#FF6B35`）
- 背景蓝 `AppTheme.darkBlue`（`#1A237E`）
- 强调黄 `AppTheme.accent`（`#FFD54F`）
- 字体始终用 `GoogleFonts.nunito()`

## 构建命令

```powershell
# 设置 Flutter PATH（每次新终端执行一次）
$env:PATH = "D:\DevTools\flutter\bin;" + $env:PATH

# 安装依赖
cd f:\TomatoEnglishHappyTalking\app
flutter pub get

# Windows 调试运行（优先使用脚本）
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run

# Windows Release 构建
.\tools\build_windows.ps1 -Release

# Android Release 构建
.\tools\build_android.ps1

# Android 调试运行（已连接设备）
.\tools\build_android.ps1 -Run -DeviceId <device-id>

# 启动模拟器并运行 Android Debug
.\tools\run_android_debug.ps1

# 初始化或重建 Android 模拟器环境
.\tools\setup_android_emulator.ps1 -Start

# 构建产物
build\windows\x64\runner\Release\tomato_english_happy_talking.exe
release\windows\tomato_english_happy_talking\
release\android\tomato_english_happy_talking-android-release.apk
```

## 重要约束

- **不要**引入新的 HTTP 库，只用 `dio`
- **不要**在 Widget 中直接 `await` API 调用，通过 Provider 中转
- **不要**把 API 响应原始 JSON 直接传给 Widget，先在 Service 层解析为 Dart 模型
- Services 必须提供 mock fallback，方便无 API Key 时本地开发调试
- 处理构建、发布、模拟器任务时，**优先更新或复用根目录 PowerShell 脚本**，不要只给出一次性的裸终端命令
- 修改 Android 构建相关文件时，保持 `pubspec.yaml` 中 `hooks.user_defines.sqlite3.source: system` 与 `name_windows: winsqlite3`
- 修改 Android Gradle 配置时，保留 `android.overridePathCheck=true` 与 `kotlin.compiler.execution.strategy=in-process`，除非明确确认问题已根除
- 更新 Windows 或 Android 产物命名时，同时同步根目录脚本、发布目录命名和旧产物清理逻辑
