# Android 原生专项规则

> 修改 Android 原生目录、Manifest、Gradle 或插件注册时必读。

不得移除或恢复以下兼容配置：

- 不要移除 Android 构建稳定性相关配置：
  - `android.overridePathCheck=true`
  - `kotlin.compiler.execution.strategy=in-process`
  - `hooks.user_defines.sqlite3.source: system`
  - `hooks.user_defines.sqlite3.name_windows: winsqlite3`
- 不要把旧包名 `com.example.english_love_reading` 重新引入源码。

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
