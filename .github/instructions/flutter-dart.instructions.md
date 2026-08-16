---
description: "Path-specific Dart and Flutter rules for null safety, async code, widgets, theming, naming, and diagnostics."
applyTo: "app/lib/**/*.dart"
---

# Flutter / Dart 路径级规则

先遵守 `/AGENTS.md`。页面、Provider 或 Bridge 改动同时阅读 `docs/agent_guides/feature_development_rules.md`。

- 保持 sound null safety。优先使用 `??`、`?.` 和显式 guard；只有逻辑上已证明非空时使用 `!`，并让理由在代码上下文中可见。
- 异步流程优先 `async` / `await`。捕获异常时保留真实失败语义并用 `TomatoLogger` 记录必要摘要；不要吞异常或返回假成功。
- 类和 Widget 使用 `UpperCamelCase`，文件使用 `snake_case`，变量、函数和常量使用 `lowerCamelCase`；Screen 文件沿用 `*_screen.dart`。
- 无本地可变状态时优先 `StatelessWidget` / `ConsumerWidget`；确需本地生命周期状态时使用 `ConsumerStatefulWidget`。
- Widget 通过 Provider / `AsyncValue` 获取业务状态，不直接调用远程 API；加载、成功和错误状态都应可观察。
- Flutter UI 颜色和字体沿用 `AppTheme` 与当前设计系统，不复制硬编码主题值；同时检查 Windows 和 Android 布局。
- 不手工编辑生成文件；修改注解或模型后运行仓库现有代码生成与相关验证。
