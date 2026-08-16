# PowerShell 工具专项规则

> 新增或修改仓库 PowerShell 工具时必读。

## PowerShell Tooling 规范

适用范围：

- `tools/build_windows.ps1`
- `tools/build_android.ps1`
- `tools/run_android_debug.ps1`
- `tools/setup_android_emulator.ps1`

脚本风格：

- 保持 `Set-StrictMode -Version Latest`。
- 保持 `$ErrorActionPreference = "Stop"`。
- 需要检查外部命令退出码时，优先封装或复用 `Assert-LastExitCode`。
- 输出信息保持当前中文风格。
- 阶段标题统一用 `=== 标题 ===`。
- 优先让脚本自行设置 `PATH`、`ANDROID_HOME`、`ANDROID_SDK_ROOT` 等环境变量，不依赖用户当前终端状态。

当前产物命名：

- Windows 可执行文件：`tomato_english_happy_talking.exe`
- Windows 发布目录：`release\windows\tomato_english_happy_talking`
- Android 发布 APK：`release\android\tomato_english_happy_talking-android-release.apk`
- Web UI 打包产物：`app\assets\web\`
- Windows 发布目录同时是本机运行数据目录，可能包含数据库、日志、诊断、导出媒体、缓存和 `security/`。对外分发 zip 不要直接压缩该目录，必须先做干净 staging，只保留程序文件、Flutter assets、FFmpeg 及依赖，排除运行数据和账号/key/settings 文件。

修改约束：

- 修改产物名时，同时更新脚本中的发布目录和旧产物清理逻辑。
- 修改 Android 启动或模拟器脚本时，始终同时设置：
  - `ANDROID_HOME`
  - `ANDROID_SDK_ROOT`
  - `ANDROID_USER_HOME`
  - `ANDROID_AVD_HOME`
- 涉及 Windows 构建名变更时，注意清理旧的 `app\build\windows` CMake 缓存，避免继续引用旧 target 名。
- 涉及 Android 调试脚本时，优先复用 `build_android.ps1 -Run`，不要复制一套新的 Flutter 启动逻辑。
- 修改 Web UI 后，保持 `tools/build_windows.ps1`、`tools/build_android.ps1` 自动执行 `npm ci` / `npm install` 与 `npm run build`，确保 `app\assets\web\` 随 EXE/APK 更新。Windows 脚本会用 `node_modules\.tomato-package-lock.sha256` 跳过未变化依赖安装；如果本地 `node_modules` 被占用导致构建失败，脚本会复制 `web_ui/` 到临时目录构建后同步 `app\assets\web\`。
- 新增 Web UI 依赖时同步更新 `web_ui\package.json` 与 `web_ui\package-lock.json`，不要提交 `node_modules`。
- Windows Debug 和 Release 可以是两套可执行程序，但桌面运行目录和数据必须共用 `release\windows\tomato_english_happy_talking`；Debug 构建/运行也要先把程序文件发布到该目录，确保 `ffmpeg.exe`、依赖 DLL、数据库和 API 缓存都从同一处读取，不要直接运行 `app\build\windows\...\Debug` 旁边的 EXE。
