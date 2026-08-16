# 功能页面开发专项规则

> 新建或重构页面、Provider、bridge command 或 Web UI 功能时必读。

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
