# 构建与发布踩坑记录

本文记录本项目构建、发布和资源打包中已经踩过的坑。遇到类似问题时，先按这里排查，避免重复试错。

## Windows Release 显示破图

症状：

- Windows EXE 中品牌图、番茄伙伴或 LEGO 动画帧显示为破图。
- Web UI 构建产物里能找到图片，但打开 `release/windows/tomato_english_happy_talking/tomato_english_happy_talking.exe` 仍然没有图。

原因与处理：

- Web UI 图片需要同时存在于 `web_ui/public/assets/ui/` 和 `app/assets/web/assets/ui/`。
- 如果新增了多级目录，例如 `assets/web/assets/ui/lego/animations/speaking/`，必须在 `app/pubspec.yaml` 的 `flutter.assets` 中显式列入相关目录。
- 不要只看 `app/build/windows/...`，还要确认发布目录 `release/windows/...` 已经更新。

快速验证：

```powershell
Test-Path .\release\windows\tomato_english_happy_talking\data\flutter_assets\assets\web\assets\ui\lego\brand-tomato.png
Test-Path .\release\windows\tomato_english_happy_talking\data\flutter_assets\assets\web\assets\ui\lego\mascot-blink\frame-01.png
Test-Path .\release\windows\tomato_english_happy_talking\data\flutter_assets\assets\web\assets\ui\lego\animations\speaking\frame-01.png
```

三个结果都应为 `True`。

## 发布目录被正在运行的 EXE 锁住

症状：

- `.\tools\build_windows.ps1 -Release` 已经显示 Flutter Windows 构建成功。
- 但最后更新 `release/windows/tomato_english_happy_talking/` 失败。
- 常见锁定文件是本地数据库，例如 `.dart_tool/sqflite_common_ffi/databases/english_love.db`。

原因与处理：

- 当前发布目录里的 EXE 还在运行，脚本无法删除旧发布目录。
- 先确认进程，再关闭运行中的发布版。

```powershell
Get-Process -Name tomato_english_happy_talking -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,Path
```

确认 `Path` 指向本仓库的 `release/windows/tomato_english_happy_talking/` 后，再结束进程或手动关闭窗口，然后重新运行：

```powershell
.\tools\build_windows.ps1 -Release
```

注意：此时 `app/build/windows/x64/runner/Release/` 可能已经是新包，但 `release/windows/...` 仍然是旧包。最终给用户测试的一定是 `release/windows/...` 里的 EXE。

## Windows Release 重建后文章列表变空

症状：

- 关闭旧 EXE 后重新运行 `.\tools\build_windows.ps1 -Release`。
- 新版发布目录启动正常，但本地调试文章、学习记录突然不见了。

原因与处理：

- Windows 桌面版的 `sqflite_common_ffi` 数据库会落在 EXE 工作目录下的 `.dart_tool/sqflite_common_ffi/databases/english_love.db`。
- 如果发布脚本直接删除整个 `release/windows/tomato_english_happy_talking/` 再复制新构建，运行数据库也会被一起删掉。
- `tools/build_windows.ps1` 发布阶段需要在删除发布目录前临时备份 `.dart_tool`，复制新包后再恢复。
- 联调时不要把发布目录里的 `.dart_tool` 当作普通构建缓存随手清理；它可能就是当前测试数据。

快速验证：

```powershell
Test-Path .\release\windows\tomato_english_happy_talking\.dart_tool\sqflite_common_ffi\databases\english_love.db
```

重新构建后该文件仍应存在，文章列表不应被清空。

## Flutter 插件 symlink 指到错误依赖源

症状：

- Windows Release 链接失败，提示找不到类似 `rive_native.lib` 的库文件。
- `.plugin_symlinks` 指向了 `C:\Users\Ryan\AppData\Local\Pub\Cache\hosted\pub.dev\...`，但 `pubspec.lock` 锁定的是 `pub.flutter-io.cn` 上的版本。

处理：

在 `app/` 目录使用镜像源和锁文件强制恢复依赖，不要裸跑会改锁文件的 `flutter pub get`。

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
D:\DevTools\flutter\bin\flutter.bat pub get --enforce-lockfile
```

然后再构建：

```powershell
.\tools\build_windows.ps1 -Release
```

构建前后要检查 `app/pubspec.lock` 是否被意外改动：

```powershell
git diff -- app\pubspec.lock
```

## Web UI 构建成功不等于 Windows 发布完成

症状：

- `npm run build` 成功，`app/assets/web/` 有新 JS/CSS/图片。
- 但 Windows EXE 仍然显示旧 UI 或旧资源。

原因与处理：

- Windows EXE 使用 Flutter assets 中的 `app/assets/web/`，需要重新运行根目录脚本完成 Flutter 打包和发布目录更新。
- 修改 Web UI 后，优先运行：

```powershell
.\tools\build_windows.ps1 -Release
```

本地调试需要 Web UI dev server 时才使用：

```powershell
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_WEB_UI_DEV_URL=http://127.0.0.1:5173"
```

## LEGO 道具图出现黑色切片线

症状：

- UI 中的 LEGO 星星、积木等奖励图标旁边出现黑色竖线、横线或帧表边界线。
- 原因通常是从帧表裁切道具时，浅色背景被去掉了，但深色切片边界仍被当作可见内容一起缩放。

处理：

```powershell
npm run assets:lego-props
```

然后重新构建 Web UI 和 Windows Release：

```powershell
cd web_ui
npm run build
cd ..
.\tools\build_windows.ps1 -Release
```

## 程序图标大小号不一致

症状：

- Windows 发布目录里的 `tomato_english_happy_talking.exe` 大图标已经是番茄，但列表模式或最小号图标仍显示 Flutter 默认蓝色图标。
- 番茄程序图标底部残留白色/灰色投影，缩小后像没有抠干净。
- Android launcher 图标和 Windows EXE 图标风格不一致。

原因：

- Windows EXE 使用 `app/windows/runner/resources/app_icon.ico`，一个 `.ico` 里需要包含 16/24/32/48/64/128/256px 多个尺寸；只看大图标不能证明 16px 条目也正确。
- Explorer 会缓存同一路径 EXE 的小图标。即使 EXE 资源已更新，文件管理器列表模式仍可能显示旧蓝色图标。
- LEGO 番茄道具图底部有用于 UI 展示的阴影，不能直接作为程序图标源图使用。

处理：

```powershell
npm run assets:app-icons
.\tools\build_windows.ps1 -Release
```

`tools/generate_app_icons.mjs` 会：

- 从 `web_ui/public/assets/ui/lego/prop-tomato.png` 生成 Windows `.ico` 和 Android `mipmap-*/ic_launcher.png`。
- 去掉程序图标不需要的底部白色/灰色投影。
- 为 Windows 16/24/32px 条目生成专用平面小番茄，避免复杂 3D 图缩小时糊掉或被缓存误判。

验证：

```powershell
Add-Type -AssemblyName System.Drawing
$exe = (Resolve-Path release\windows\tomato_english_happy_talking\tomato_english_happy_talking.exe).Path
$icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
$icon.ToBitmap().Save((Resolve-Path .tmp).Path + '\tomato-exe-icon.png')
```

如果提取出的图标是番茄，但 Explorer 里仍是旧蓝色图标，刷新或清理 Windows 图标缓存：

```powershell
$local = [Environment]::GetFolderPath('LocalApplicationData')
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Remove-Item "$local\IconCache.db" -Force -ErrorAction SilentlyContinue
Remove-Item "$local\Microsoft\Windows\Explorer\iconcache*.db" -Force -ErrorAction SilentlyContinue
Start-Process explorer.exe
```

清理缓存会重启 Explorer，当前文件管理器窗口会闪一下或重开。重新进入发布目录或按 `F5` 后再看小图标。

## CMake dev warning

症状：

- 构建末尾出现 `flutter_inappwebview_windows` 的 `add_custom_command(TARGET): DEPENDS` / `CMP0175` warning。

处理：

- 这是第三方插件的 CMake developer warning。
- 如果构建退出码为 0，且发布目录已更新，可以暂时忽略。
- 不要把它当成破图或播放问题的根因。

## Dart format telemetry 权限失败

症状：

- `dart format ...` 显示 `Formatted ...`，但命令最后报：
  `Failed to set file modification time, path = 'C:\Users\Ryan\AppData\Roaming\.dart-tool\dart-flutter-telemetry-session.json'`。

处理：

- 这不是代码格式化失败，而是 Dart 工具在受限环境里写 telemetry 会话文件失败。
- 先看输出中的 `Formatted N files`，确认格式化是否已执行。
- 需要干净退出码时，改用已授权的外部 PowerShell 环境执行，或在普通终端中先处理 Dart/Flutter analytics 设置。

## Flutter SDK Git ownership / cache 权限卡住

症状：

- 直接运行 `flutter --version`、`flutter analyze` 或 `flutter test` 长时间无输出。
- 单独运行 `git -C D:\DevTools\flutter ...` 可能报 `dubious ownership`。
- 非提权环境单独运行 `update_engine_version.ps1` 可能报无法写入 `D:\DevTools\flutter\bin\cache\engine.stamp`。

处理：

- 构建、发布优先使用根目录脚本，并按需要在外部 PowerShell 权限下运行。
- `tools/build_windows.ps1` / `tools/build_android.ps1` 会在仓库 `.tmp\tooling\flutter-safe-gitconfig` 中临时设置 `safe.directory`，不修改用户全局 Git 配置。
- 不要把这个问题误判为 Dart 语法错误；必要时先用 Dart SDK 直接分析具体文件：

```powershell
$env:LOCALAPPDATA=(Resolve-Path .tmp\localappdata).Path
$env:APPDATA=(Resolve-Path .tmp\appdata).Path
D:\DevTools\flutter\bin\cache\dart-sdk\bin\dart.exe analyze <files>
```

## Windows 发布目录被运行中的 EXE 占用

症状：

- `flutter build windows` 已成功，但脚本清理 `release\windows\tomato_english_happy_talking` 时报：
  `The process cannot access the file ... english_love.db because it is being used by another process.`

处理：

- 先关闭正在运行的 Windows App，再重新执行发布脚本。
- 这是发布目录中的本地数据库被旧 EXE 占用，不是 Web UI 构建失败。

## 自动化实测限制

有时 Codex 的 Windows 窗口捕获或 in-app browser 访问本地地址会被环境策略拦截。遇到这种情况时：

- 不要绕过策略。
- 优先开启本机 QA 控制接口，用 `GET /screenshot` 和 `GET /snapshot` 获取真实 WebView 截图和页面状态。使用方式见 `docs/qa-remote-control.md`。
- 如果 QA 接口也不可用，再用文件存在性、构建输出、发布目录、日志和用户截图做证据。
- 关键 UI 问题仍需要最终在 Windows EXE 中人工或可用的窗口工具复核。

## 隐藏 file input 被全局输入框样式撑开

症状：

- 新增文章页有隐藏的导入文件 `<input type="file">`。
- QA `/snapshot` 报这个隐藏 input 有 overflow，或者页面顶部/按钮附近出现 1px 但 46px 高的异常点击区域。

原因与处理：

- Web UI 的全局 `input, textarea, select` 会设置 `min-height: 46px`、padding 和 border。
- `.visually-hidden` 必须覆盖这些全局样式，至少包含 `height/min-height/padding/border` 的强制隐藏规则。
- 修改后用 `/snapshot` 看 `formControls` 和 `overflowElements`，确认隐藏控件不再被当作可见大控件。

## JSDOM 没有 scrollIntoView

症状：

- React/Vitest 测试中组件挂载崩溃：`scrollIntoView is not a function`。
- 真实浏览器里正常，但 `npm test` 失败。

处理：

- UI 自动滚动增强需要写成可选调用：

```ts
elementRef.current?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });
```

- 不要为了测试删除真实浏览器需要的滚动行为；加方法存在性守卫即可。
