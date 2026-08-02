# 参与 Tomato

Tomato 当前优先收集家长、教师和实际使用者的反馈。无需会写代码，也可以帮助项目改善。

## 提问和反馈

- 使用问题、经验交流和作品展示：使用 [GitHub Discussions](https://github.com/70565912/TomatoEnglishHappyTalking/discussions)。
- 可以稳定复现的程序问题：使用 [Bug report](https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose)。
- 新功能或流程建议：使用 [Feature request](https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose)。

提交前请搜索已有 Issue，并提供版本、平台、操作步骤、期望结果和实际结果。日志和截图必须先脱敏。

## 严禁公开的信息

不要在 Issue、Discussion、Pull Request、截图或日志中提交：

- API Key、Token、Cookie、账号或密码；
- 本机绝对路径、个人邮箱之外的身份信息；
- 本地数据库、安全配置、完整诊断包；
- 未确认授权的文章、图片、音频或视频。

发现安全问题时不要创建公开 Issue，请按 [安全政策](SECURITY.md) 私下报告。

## 代码贡献

1. 先为行为变化创建或关联 Issue，确认问题边界。
2. 保持改动聚焦，不夹带无关重构、生成产物、运行数据或凭据。
3. Web UI 改动运行 `npm test` 和 `npm run build`；Flutter 改动运行 `flutter analyze` 和相关 `flutter test`。
4. 涉及 Windows/Android 用户流程时，说明实际平台验证结果。
5. Pull Request 描述应包含目的、行为变化、测试证据和必要的脱敏截图。

开发环境和构建命令见 [开发与构建指南](docs/development-guide.md)。
