# 开发与构建指南

Tomato English Happy Talking 是 Flutter 独立 App，主界面为打包进本地 WebView 的 React/Vite 页面。客户端直接调用已配置的云服务，不依赖 Tomato 私有后端。

## 项目结构

```text
app/                  Flutter 应用、原生平台工程和打包后的 Web UI
web_ui/               React + Vite + TypeScript 源码
tools/                Windows、Android、QA 和 Release 脚本
docs/                 用户、设计、调试和变更文档
```

运行时链路：

```text
React/Vite Web UI
        ↓ typed command/event bridge
Flutter WebShellScreen
        ↓
Riverpod / SQLite / secure storage / audio / cloud services / export
```

## 环境

- Flutter 3.41.9 stable 与 Dart
- Node.js 和 npm
- Android SDK（构建 APK 时）
- Microsoft Edge WebView2 Runtime（Windows）
- FFmpeg（Windows 音视频导出）
- 可选：支持 Vulkan 的显卡（Windows 绘本超分）

仓库的本机工具链示例路径不是项目硬性要求。请通过自己的 Flutter 和 Android SDK 配置运行。

## 安装依赖

```powershell
cd app
flutter pub get

cd ..\web_ui
npm install
```

## 构建

从仓库根目录运行：

```powershell
.\tools\build_windows.ps1 -Release
.\tools\build_android.ps1
```

不要直接把开发机 `release/` 运行目录压缩发布。正式 GitHub Release 使用：

```powershell
.\tools\publish_github_release.ps1 -Version <semver>
```

发布脚本会构建、整理干净资产、检查 Windows ZIP 中的运行数据和密钥风险、生成 `SHA256SUMS.txt`，再创建标签和 GitHub Release。

## 验证

```powershell
cd web_ui
npm test
npm run build

cd ..\app
flutter analyze
flutter test
```

涉及真实 Windows WebView 工作流时，使用仓库 QA 接口和脚本完成 Release 联调。协议、健康检查和安全边界见 [AI CLI / QA 远程调用指南](ai_cli_qa_remote_guide.md)。

## 架构约定

- Web UI 与 Flutter 只通过 typed bridge command/event 协议交互。
- Service 层负责 API 与数据处理，Provider 持有 UI 状态，Widget 不直接调用远程 API。
- 云调用先查本地业务数据和成功缓存，避免重复计费。
- API Key 只从安全配置读取，不硬编码、不写日志、不进入测试夹具。
- 构建与发布故障处理见 [构建与发布坑位](build-and-release-pitfalls.md)。

## 进一步阅读

- [用户指南与截图](user-guide/)
- [AI 调用链与提示词逻辑](ai-call-flow-and-prompt-logic.md)
- [变更记录](change_log.md)
- [贡献说明](../CONTRIBUTING.md)
- [安全政策](../SECURITY.md)
