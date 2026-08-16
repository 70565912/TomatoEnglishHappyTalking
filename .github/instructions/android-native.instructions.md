---
description: "Path-specific rules for Android Gradle, Manifest, Kotlin entrypoint, resources, package identity, and verified compatibility settings."
applyTo: "app/android/**"
---

# Android 原生路径级规则

先遵守 `/AGENTS.md`，并阅读 `docs/agent_guides/android_native_rules.md` 与构建专项文档。

- 当前 package / namespace 为 `com.example.tomato_english_happy_talking`；`MainActivity` 的包声明、Kotlin 目录、`namespace` 和 `applicationId` 必须一致。
- 修改显示名不要误改 package；修改 package 时同步 Gradle、Manifest、Kotlin 声明和目录结构，且不要恢复旧包名。
- 保持当前 Gradle plugin 顺序、Java/Kotlin 17 配置和 AndroidX 设置，除非任务明确要求且完成 Android 回归。
- 不随意移除仓库为当前构建稳定性保留的 `android.overridePathCheck=true`、`kotlin.compiler.execution.strategy=in-process`、sqlite3 hooks 或 Manifest 入口/权限配置；先查清存在原因。
- 签名、权限、Manifest、Gradle、Kotlin 或 native plugin 变更必须运行 Android 构建或设备/模拟器验证。
- 构建和运行优先使用 `tools/build_android.ps1`、`tools/run_android_debug.ps1` 与 `tools/setup_android_emulator.ps1`。

SDK 路径、Android 用户目录和 AVD 名称是本机配置，不在本文件固定。
