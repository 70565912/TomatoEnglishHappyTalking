---
description: "Path-specific rules for repository PowerShell build, release, QA, emulator, and maintenance scripts."
applyTo: "**/*.ps1"
---

# PowerShell 工具路径级规则

先遵守 `/AGENTS.md`，并阅读 `docs/agent_guides/powershell_tooling_rules.md`；构建或发布脚本还需阅读 `docs/agent_guides/build_and_release_rules.md`。

- 保持 `Set-StrictMode -Version Latest` 和 `$ErrorActionPreference = 'Stop'`；外部进程必须检查退出码并在失败时停止。
- 优先复用现有 helper（包括退出码、Flutter lock/cache 预检和环境解析），不要复制第二套构建或启动流程。
- 脚本应自行解析或配置 `PATH`、Flutter/Android SDK 与 Android 环境变量，不依赖调用者终端状态，也不把单台开发机绝对路径当成项目协议。
- 保持当前中文输出风格和可定位的阶段信息；日志不得泄露凭据或私有路径。
- 修改产物名或目录时，同步构建、发布、旧程序文件清理与验证逻辑，但不得清空数据库、缓存、录音、绘本、日志或安全配置等用户运行数据。
- Web UI 构建继续由既有脚本同步到 `app/assets/web/`；新增依赖时同步 `package.json` 与 lockfile，不提交 `node_modules`。
- Windows 对外发布使用干净 staging，不直接压缩含运行数据的发布目录。
- 对路径、进程和删除范围做显式校验；临时文件使用隔离目录并在成功或失败后安全清理。
