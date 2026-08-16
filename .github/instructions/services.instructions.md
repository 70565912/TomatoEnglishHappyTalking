---
description: "Path-specific rules for service classes: boundaries, models, HTTP reuse, credentials, errors, caching, and diagnostics."
applyTo: "app/lib/services/**/*.dart"
---

# Services 路径级规则

先遵守 `/AGENTS.md`，并按任务阅读 `docs/agent_guides/cloud_service_development_rules.md`；涉及 Provider、端点、模型或密钥时再读 `docs/agent_guides/cloud_service_configuration_rules.md`。

- Service 只负责远程 API、本地数据处理、缓存、文件和模型转换，不持有 Widget UI 状态，不显示 Dialog。
- 沿用对应服务的现有传输栈、Provider 选择、超时、重试和异常类型：HTTP 通常复用 `dio`，实时/流式协议复用仓库现有 WebSocket 实现；不要增加平行网络栈或复制业务链路。
- API 原始响应在 Service 内校验并转换为 Dart 模型或明确的业务值，不直接暴露给 Widget。
- API Key 和敏感配置只从 `AppConfig` / secure storage 读取，不硬编码、不写日志、不进入 fixture、Bridge payload 或缓存。
- 远程失败应保留可诊断的真实错误语义。只有现有产品契约或明确测试场景要求时才返回可识别的 fallback；不得用 mock 冒充远程成功。
- 只缓存成功的真实结果，cache key 覆盖所有影响输出的输入和配置；错误、安全拒绝和 mock/fallback 不进入成功缓存。
- 正式诊断使用 `TomatoLogger`，只记录 ID、hash、长度、阶段、状态和短摘要。
- 数据库写操作保持事务、幂等性和当前返回契约；表名、列名沿用集中定义。

供应商 endpoint、鉴权头、模型 ID 和响应 schema 不在本文件固化。修改前以当前代码、专项文档和供应商官方文档交叉验证。
