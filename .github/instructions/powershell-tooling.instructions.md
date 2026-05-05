---
description: "Use when writing or modifying the root PowerShell build, release, emulator, or run scripts. Covers the fixed Flutter/Android toolchain paths, current artifact names, release directories, and fail-fast script patterns for this project."
applyTo: "*.ps1"
---

# PowerShell Tooling 规范

## 适用范围

- `tools/build_windows.ps1`
- `tools/build_android.ps1`
- `tools/run_android_debug.ps1`
- `tools/setup_android_emulator.ps1`

## 固定环境事实

- Flutter SDK 固定在 `D:\DevTools\flutter`
- Android SDK 固定在 `D:\Android\SDK`
- Android 用户目录固定在 `D:\Android\.android`
- AVD 目录固定在 `D:\Android\.android\avd`
- 默认模拟器名称为 `EnglishRead_API_35`
- 国内镜像环境需要：
  - `PUB_HOSTED_URL=https://pub.flutter-io.cn`
  - `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

## 脚本风格

- 保持 `Set-StrictMode -Version Latest`
- 保持 `$ErrorActionPreference = "Stop"`
- 需要检查外部命令退出码时，优先封装 `Assert-LastExitCode`
- 输出信息保持当前中文风格，阶段标题统一用 `=== 标题 ===`
- 优先让脚本自行设置 `PATH`、`ANDROID_HOME`、`ANDROID_SDK_ROOT` 等环境，不依赖用户当前终端状态

## 当前产物命名

- Windows 可执行文件：`tomato_english_happy_talking.exe`
- Windows 发布目录：`release\windows\tomato_english_happy_talking`
- Android 发布 APK：`release\android\tomato_english_happy_talking-android-release.apk`

## 修改约束

- 修改产物名时，同时更新脚本中的发布目录和旧产物清理逻辑
- 修改 Android 启动或模拟器脚本时，始终同时设置：
  - `ANDROID_HOME`
  - `ANDROID_SDK_ROOT`
  - `ANDROID_USER_HOME`
  - `ANDROID_AVD_HOME`
- 涉及 Windows 构建名变更时，注意清理旧的 `app\build\windows` CMake 缓存，避免继续引用旧 target 名
- 涉及 Android 调试脚本时，优先复用 `build_android.ps1 -Run`，不要复制一套新的 Flutter 启动逻辑