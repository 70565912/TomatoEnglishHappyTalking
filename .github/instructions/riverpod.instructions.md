---
description: "Path-specific Riverpod rules for generated providers, state ownership, AsyncValue, lifecycle, injection, and side effects."
applyTo: "app/lib/**/providers/**/*.dart"
---

# Riverpod 路径级规则

先遵守 `/AGENTS.md`，并阅读 `docs/agent_guides/feature_development_rules.md`。

- 沿用 `riverpod_annotation` 代码生成风格：`@riverpod` 或确有跨页面生命周期需求时使用 `@Riverpod(keepAlive: true)`；不要引入平行状态管理或无理由恢复手写 Provider 风格。
- `ref.watch()` 用于构建期响应状态，`ref.read()` 用于事件和一次性依赖访问；不要在 UI 中复制 Provider 的业务规则。
- UI 面对异步状态时明确处理 data、loading 和 error；失败不得被空数据或 mock 静默覆盖。
- Service 通过现有 Provider 注入，不在 Notifier 中随意 `new`；状态归属和生命周期应与页面/跨页面使用范围一致。
- 避免在 `build()` 外制造隐式副作用。远程调用、订阅、timer 和资源释放要有明确生命周期、并发与取消策略。
- 状态更新集中在 Notifier 或现有函数式 Provider 中，避免同一业务状态在 Widget、Bridge 和 Provider 多处维护。
- 修改注解后运行项目现有代码生成流程，不手工编辑 `.g.dart`。
