# Security Policy

## Supported versions

安全修复优先应用到最新 GitHub Release 和 `main` 分支。旧版本可能不会单独回补，请先确认问题能否在最新版本复现。

## Reporting a vulnerability

请不要为以下问题创建公开 Issue：

- API Key、Token、Cookie 或账号信息泄露；
- 安全存储、Flutter/Web bridge、远程 QA 接口的绕过；
- 发布包意外包含本地数据库、日志、缓存或用户生成内容；
- 可导致任意文件读写、命令执行或未授权网络访问的问题。

请发送邮件至 [70565912@qq.com](mailto:70565912@qq.com)，主题使用 `Tomato Security Report`，并提供受影响版本、平台、复现步骤、影响范围和已经采取的临时措施。不要发送真实有效的密钥；如必须提供日志，请先脱敏。

维护者会先确认收到报告，再评估影响、修复和披露方式。修复公开前，请避免传播可直接利用的细节。

## Secret exposure

如果凭据已经出现在仓库、Issue、日志或截图中，应立即在对应供应商控制台撤销并重新创建。删除公开文本不能使已经暴露的凭据重新安全。
