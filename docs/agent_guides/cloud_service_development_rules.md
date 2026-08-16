# 云 API Service 开发专项规则

> 新建或重构云 API Service 时必读。

## 新建或重构云 API Service 工作流

新建 service 时：

- 文件放在 `app/lib/services/<service_name>_service.dart`。
- 配置存取入口在 `app/lib/core/config/app_config.dart`。
- 如新增非密钥运行参数，通常同步更新 `app/lib/features/profile/profile_screen.dart` 和 Web UI `settings.load` 展示。
- 设置页可以通过云服务选项卡保存/清除百炼、方舟和火山语音 key；输入框只能处理用户草稿值，bridge payload 只能返回配置状态和脱敏 mask，不得回传明文 key。不要在代码、日志、文档或测试 fixture 中硬编码真实 API Key。
- 不要为了验证服务逻辑去改构建链。

Service 必须满足：

- HTTP 调用复用 `dio`；实时/流式接口复用仓库现有 WebSocket 协议实现，不为同类传输增加第二套网络栈。
- API Key 通过 `AppConfig` 读取。
- 只有现有产品契约或明确测试/本地演示场景要求时才提供可识别的 mock/fallback；不得伪装为远程成功或写入成功缓存。
- 返回 Dart 模型类。
- 错误时用 `TomatoLogger` 记录摘要，并按现有调用契约返回或抛出可诊断的失败；不要吞异常或无条件返回 fallback。
- 不修改 `pubspec.yaml` 既有依赖版本，除非任务明确要求。
