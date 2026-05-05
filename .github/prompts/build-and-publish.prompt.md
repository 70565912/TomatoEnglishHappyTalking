---
description: "Use when building, publishing, or deploying Tomato English Happy Talking for Windows or Android. Prefer the repository root PowerShell scripts over raw flutter commands for release builds, artifact publishing, emulator setup, and Android debug launch."
argument-hint: "Describe the goal (e.g. 'build Windows release and Android APK, refresh release directory, then launch Android debug on the emulator')"
agent: "agent"
tools: [read, search, edit]
---

帮我处理「Tomato English Happy Talking」的构建、发布与调试启动流程。

## 优先工作流

除非任务本身是在修脚本，否则优先使用 `tools/` 下脚本，不要先退回到裸 `flutter` / `gradle` 命令：

- Windows Debug 运行：`./tools/build_windows.ps1 -Run`
- Windows Release 构建：`./tools/build_windows.ps1 -Release`
- Windows Release 构建并运行：`./tools/build_windows.ps1 -Release -Run`
- Android Release 构建并发布：`./tools/build_android.ps1`
- Android 已连接设备 Debug：`./tools/build_android.ps1 -Run -DeviceId <device-id>`
- Android 模拟器 Debug：`./tools/run_android_debug.ps1`
- 初始化或重建 Android 模拟器环境：`./tools/setup_android_emulator.ps1 -Start`

只有在怀疑这些脚本本身有问题时，才直接使用底层 `flutter build`、`flutter run`、`gradlew`、`adb` 或 `emulator` 命令进行定位。

## 当前项目事实

- Flutter 包名：`tomato_english_happy_talking`
- 应用显示名：`Tomato English Happy Talking`
- Android package：`com.example.tomato_english_happy_talking`
- Windows 可执行文件：`tomato_english_happy_talking.exe`
- Android SDK：`D:\Android\SDK`
- Android 用户目录：`D:\Android\.android`
- 默认模拟器：`EnglishRead_API_35`

## 当前产物位置

- Windows 构建输出：`app/build/windows/x64/runner/Release/tomato_english_happy_talking.exe`
- Windows 发布目录：`release/windows/tomato_english_happy_talking/`
- Android 构建输出：`app/build/app/outputs/flutter-apk/app-release.apk`
- Android 发布 APK：`release/android/tomato_english_happy_talking-android-release.apk`

## 处理要求

根据用户目标，选择合适的脚本组合完成任务，例如：

- 只构建 Windows Release
- 同时构建 Windows + Android Release 并刷新 `release/` 目录
- 启动 Android 模拟器并跑 Debug
- 先发布再验证产物是否存在和名称是否正确

如需修改脚本或构建配置，请遵守以下约束：

- 修改产物命名时，同时同步脚本中的发布目录、输出路径和旧产物清理逻辑
- Android 构建相关修改要保留：
  - `android.overridePathCheck=true`
  - `kotlin.compiler.execution.strategy=in-process`
  - `pubspec.yaml` 中 `hooks.user_defines.sqlite3.source: system`
  - `pubspec.yaml` 中 `hooks.user_defines.sqlite3.name_windows: winsqlite3`
- Windows 构建名变更后，要注意旧 CMake 缓存清理逻辑是否仍然正确

## 输出期望

请给出：

1. 实际执行了哪些根目录脚本或命令
2. 是否成功生成了 Windows / Android 产物
3. 发布目录是否已刷新到最新文件
4. 如果启动了模拟器或应用，说明最终运行状态
5. 如果失败，指出卡在哪一步，并优先给出脚本层修复方案