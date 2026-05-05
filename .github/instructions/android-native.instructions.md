---
description: "Use when writing or modifying Android native project files under app/android, including Gradle scripts, AndroidManifest.xml, Kotlin MainActivity, resources, and Android project metadata. Covers the current package name, MainActivity path, manifest label, and build constraints verified for this project."
applyTo: "app/android/**"
---

# Android 原生目录规范

## 当前项目事实

- Android package / namespace 固定为 `com.example.tomato_english_happy_talking`
- `MainActivity` 文件路径固定为 `app/android/app/src/main/kotlin/com/example/tomato_english_happy_talking/MainActivity.kt`
- `MainActivity` 包声明必须与 package 名一致：`package com.example.tomato_english_happy_talking`
- Android 启动器显示名固定为 `Tomato English Happy Talking`

## Gradle 配置约束

- `app/android/app/build.gradle.kts` 中的 `namespace` 与 `defaultConfig.applicationId` 必须保持一致
- Gradle 插件顺序保持现状：
  - `com.android.application`
  - `kotlin-android`
  - `dev.flutter.flutter-gradle-plugin`
- 保持 Java 17 配置：
  - `sourceCompatibility = JavaVersion.VERSION_17`
  - `targetCompatibility = JavaVersion.VERSION_17`
  - `kotlinOptions.jvmTarget = JavaVersion.VERSION_17.toString()`
- 当前 `release` 构建保留 `signingConfig = signingConfigs.getByName("debug")`，除非任务明确要求切换正式签名

## gradle.properties 约束

- 保留 `android.useAndroidX=true`
- 保留 `android.overridePathCheck=true`
- 保留 `kotlin.compiler.execution.strategy=in-process`
- 不要随意移除这些项；它们与当前本地 Android 构建稳定性直接相关

## Manifest 与入口约束

- `AndroidManifest.xml` 中的 `<application android:label>` 保持为 `Tomato English Happy Talking`
- 主 Activity 保持为 `.MainActivity`
- 保留当前的 `android:exported="true"`、`launchMode="singleTop"`、`hardwareAccelerated="true"` 和 `windowSoftInputMode="adjustResize"`
- 保留当前 `PROCESS_TEXT` queries 配置，除非明确确认不再需要

## 修改注意事项

- 修改 package 名时，必须同时更新：
  - `app/android/app/build.gradle.kts`
  - `app/android/app/src/main/AndroidManifest.xml`（若涉及组件全名或包关联）
  - `app/android/app/src/main/kotlin/.../MainActivity.kt`
  - Kotlin 目录结构本身
- 不要把旧包名 `com.example.english_love_reading` 重新引入到源码中
- 若只是修改应用显示名，优先改 `AndroidManifest.xml` 的 `android:label`，不要误改 package 名
- 涉及 Android 运行或构建流程时，优先复用 `tools/` 下脚本：
  - `tools/build_android.ps1`
  - `tools/run_android_debug.ps1`
  - `tools/setup_android_emulator.ps1`

## 本地环境事实

- Android SDK 位于 `D:\Android\SDK`
- Android 用户目录位于 `D:\Android\.android`
- AVD 目录位于 `D:\Android\.android\avd`
- 当前默认模拟器名称为 `EnglishRead_API_35`