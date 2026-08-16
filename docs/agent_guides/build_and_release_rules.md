# 构建、运行与发布专项规则

> 执行 Flutter、Windows、Android、Web UI 构建或发布时必读。

- 不要只给裸 `flutter` 命令来处理构建、发布或模拟器任务，优先复用根目录脚本。

## 构建、运行与发布

处理构建、发布、模拟器任务时，优先复用根目录 PowerShell 脚本，不要只给一次性裸终端命令。

Codex / 自动化会话每次执行 Flutter 相关命令前都必须检查 SDK 的 `flutter.bat.lock`、`lockfile` 是否可独占打开且 cache 是否可写。测试、分析、版本查询和其它裸 Flutter 参数统一从相应工作目录调用 `tools/run_flutter.ps1`；Windows/Android 构建调用已经接入同一检查的 `tools/build_windows.ps1` / `tools/build_android.ps1`。检查失败必须立即报错，禁止直接调用 `flutter.bat` 进入无输出锁循环。当前受限沙箱不能写 `D:\DevTools\flutter\bin\cache`，因此这些入口应直接走已授权的沙箱外 PowerShell，并设置明确超时，例如：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1'
```

纯 Web UI 的 `npm` / `tsc` / `vite` 命令可以按普通仓库命令执行；只有需要 Flutter SDK、Android SDK 或启动桌面/模拟器时才直接走沙箱外。

常用命令：

```powershell
# 安装依赖
cd f:\TomatoEnglishHappyTalking\app
..\tools\run_flutter.ps1 pub get

# 测试 / 分析 / 版本检查
..\tools\run_flutter.ps1 test
..\tools\run_flutter.ps1 analyze
..\tools\run_flutter.ps1 --version

# Windows Debug 运行
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run

# Windows Release 构建
.\tools\build_windows.ps1 -Release

# Windows Release 构建并运行
.\tools\build_windows.ps1 -Release -Run

# Android Release 构建并发布
.\tools\build_android.ps1

# Android 已连接设备 Debug
.\tools\build_android.ps1 -Run -DeviceId <device-id>

# Android 模拟器 Debug
.\tools\run_android_debug.ps1

# 初始化或重建 Android 模拟器环境
.\tools\setup_android_emulator.ps1 -Start

# Web UI 本地调试
cd f:\TomatoEnglishHappyTalking\web_ui
npm run dev
cd f:\TomatoEnglishHappyTalking
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_WEB_UI_DEV_URL=http://127.0.0.1:5173"
```

构建产物：

- Windows Release 构建输出：`app\build\windows\x64\runner\Release\tomato_english_happy_talking.exe`
- Windows Debug 构建中间输出：`app\build\windows\x64\runner\Debug\tomato_english_happy_talking.exe`，但调试运行也应使用脚本同步后的发布目录 EXE。
- Windows 发布目录：`release\windows\tomato_english_happy_talking\`
- Android 构建输出：`app\build\app\outputs\flutter-apk\app-release.apk`
- Android 发布 APK：`release\android\tomato_english_happy_talking-android-release.apk`
- Web UI 构建输出 / App 内置资源：`app\assets\web\`（由 `web_ui/vite.config.ts` 的 `outDir` 指定）

- 桌面运行目录和数据固定跟随发布目录：Windows Debug 和 Release 可以是两套构建产物，但脚本会把最终运行的程序文件同步到 `release\windows\tomato_english_happy_talking\`；数据库、`tomato_api_cache/`、绘本图片、TTS、录音、`ffmpeg.exe` 和依赖 DLL 都应从这里读取，不要让 Debug 从 `app\build\windows\...\Debug` 直接启动或写入第二套数据。
- `tools/build_windows.ps1` 不得清空用户运行数据；如果需要清理发布目录，只能清理程序构建产物，必须保留数据库、`tomato_api_cache/`、录音、绘本图片和配置密钥文件。
- 当前 Codex 沙箱无权写 Flutter SDK cache；所有 Flutter 命令必须先经过公共锁预检并直接在已授权沙箱外执行。不要删除锁文件来猜测解锁；只有预检确认没有活跃持有者且确需清理零字节残留时才可处理，随后仍须验证 cache 可写性。
- Android Release 冷构建可能接近或超过 15 分钟，尤其是 R8/minify、资源压缩、mapping 和 `rive_native` Android artifact 初始化。自动化外层 timeout 至少预留 25-30 分钟；如果 `app/build/app/outputs/flutter-apk/app-release.apk` 与 `outputs/mapping/release/mapping.txt` 已更新但 `release/android/` 仍旧，先查 Gradle daemon 日志是否已 `Success`，再重新运行脚本或按脚本目标同步产物。

只有在怀疑脚本本身有问题时，才退回到底层 `flutter build`、`flutter run`、`gradlew`、`adb` 或 `emulator` 命令定位。
