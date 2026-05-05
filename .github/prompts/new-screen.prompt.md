---
description: "Use when adding a new Tomato English Happy Talking feature screen, provider, and route. Follow the current Riverpod and go_router structure, keep widgets thin, and use the repository root scripts for runtime verification when needed."
argument-hint: "Screen name (e.g. 'vocabulary list')"
agent: "agent"
tools: [read, edit, search]
---

为「Tomato English Happy Talking」项目新建一个完整的 Flutter 功能页面。

## 先对齐当前项目事实

- 主应用标题是 `Tomato English Happy Talking`
- 路由统一维护在 `app/lib/core/router/app_router.dart`
- 状态管理使用 `flutter_riverpod` + `riverpod_annotation`
- 若需要实际运行验证：
  - Windows 优先用 `./tools/build_windows.ps1 -Run`
  - Android 模拟器优先用 `./tools/run_android_debug.ps1`

## 需要生成的内容

请在 `app/lib/features/<feature_name>/` 目录下创建以下文件：

1. **`<feature_name>_screen.dart`** — 主屏 UI
2. **`providers/<feature_name>_provider.dart`** — Riverpod 状态
3. **`widgets/`** — 需要的子 Widget（如果有）

## 规范要求

### Screen 文件模板

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import 'providers/<feature_name>_provider.dart';

class <FeatureName>Screen extends ConsumerWidget {
  const <FeatureName>Screen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ref.watch(provider) 读取状态
    return Scaffold(
      backgroundColor: AppTheme.darkBlue,
      appBar: AppBar(
        title: Text('标题', style: GoogleFonts.nunito()),
        backgroundColor: AppTheme.primary,
      ),
      body: const _Body(),
    );
  }
}
```

### Provider 文件模板

```dart
import 'package:riverpod_annotation/riverpod_annotation.dart';
part '<feature_name>_provider.g.dart';

@riverpod
class <FeatureName>Notifier extends _$<FeatureName>Notifier {
  @override
  <StateType> build() => <initialState>;

  // 方法...
}
```

### go_router 注册

在 `app/lib/core/router/app_router.dart` 的路由表里添加新路由：

```dart
GoRoute(
  path: '/<feature-path>',
  builder: (context, state) => const <FeatureName>Screen(),
),
```

## 约束

- 使用 `AppTheme.primary`（橙色）、`AppTheme.darkBlue`（深蓝）配色
- 字体用 `GoogleFonts.nunito()`
- Screen 不直接调用 API，通过 Provider 中转
- 所有图标用 Material Icons
- 支持 Windows 和 Android 两端布局（避免硬编码宽度）
- 如果页面需要调用云 API，通过 `app/lib/services/` + Provider 组合接入，不要把请求写进 Widget
