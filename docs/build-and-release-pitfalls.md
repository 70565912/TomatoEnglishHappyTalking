# 构建与发布踩坑记录

本文记录本项目构建、发布和资源打包中已经踩过的坑。遇到类似问题时，先按这里排查，避免重复试错。

## Windows 对外 zip 不能直接压发布运行目录

症状：

- `release/windows/tomato_english_happy_talking/` 里既有 EXE / DLL / Flutter assets，也有 `logs/`、`diagnostics/`、`recording-export/`、`suno-music/`、`tomato_api_cache/`、数据库或 `security/`。
- 需要给外部机器分发 Windows 版，但用户明确要求不能包含生成产物、账号信息或本机运行数据。

原因：

- Windows Debug / Release 都复用 `release/windows/tomato_english_happy_talking/` 作为本机运行目录。
- `tools/build_windows.ps1` 会保护并恢复运行数据，避免本机重新发布后丢失数据库、缓存、歌曲和导出文件。
- 因此该目录适合本机运行和联调，不适合直接压缩成对外发布包。

处理：

- 先运行 `.\tools\build_windows.ps1 -Release`，确保程序文件、Flutter assets、`ffmpeg.exe` 和依赖 DLL 已同步到发布目录。
- 再复制出干净 staging，只保留程序运行必需文件：
  - `tomato_english_happy_talking.exe`
  - 运行所需 DLL
  - `native_assets.json`
  - `data/flutter_assets`、`data/icudtl.dat`、AOT 产物等 Flutter 程序数据
  - `ffmpeg.exe` 及同目录 FFmpeg DLL
- 必须排除：
  - `.dart_tool/`
  - `logs/`
  - `diagnostics/`
  - `recording-export/`
  - `recordings/`
  - `suno-music/`
  - `tomato_api_cache/`
  - `picture_book/`
  - `song-assets/`
  - `user_data/`
  - `security/`
  - `data/downloads`、`data/tomato_api_cache`、`data/recordings`、`data/picture_book`、`data/song-assets`、`data/suno-music`、`data/user_data`、`data/databases`
  - 根目录 `*.db`、`*.sqlite`、`*.sqlite3`、`settings.json`、`AccessKey.txt`、`speech-api-key.txt`

验证：

```powershell
# zip 条目中不应出现上述 runtime / secret 路径。
# 文本类文件中也不应出现 sk-、AKIA、Bearer token、Authorization 等真实密钥形态。
```

## Android Release 构建外层超时但 APK 已生成

症状：

- `.\tools\build_android.ps1` 在 Codex / 自动化命令外层 900 秒左右超时。
- 命令没有正常打印“发布目录已更新”，`release/android/` 仍是旧 APK。
- 但 `app/build/app/outputs/flutter-apk/app-release.apk` 和 `app/build/app/outputs/mapping/release/mapping.txt` 的时间戳已经更新。

原因：

- Android Release 首次或冷缓存构建可能接近或超过 15 分钟。
- 本项目会经历 Web UI build、Flutter Android build、R8/minify、资源压缩、mapping 生成；`rive_native` 首次 Android 构建还可能下载并初始化原生产物。
- 如果外层超时刚好卡在 Gradle build 成功返回前后，父 PowerShell 可能被杀掉，导致脚本没来得及把新 APK / mapping 复制到 `release/android/`。

排查：

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'java|gradle|dart|flutter' }

Get-Item app\build\app\outputs\flutter-apk\app-release.apk,
  app\build\app\outputs\mapping\release\mapping.txt,
  release\android\tomato_english_happy_talking-android-release.apk |
  Select-Object FullName,Length,LastWriteTime

Get-ChildItem $env:USERPROFILE\.gradle\daemon -Recurse -Filter *.log |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
```

看 Gradle daemon 日志里的关键信号：

- `Starting build in new daemon`
- `The daemon has finished executing the build`
- `ReturnResult ... Success`

处理：

- 自动化环境把 Android Release 外层 timeout 设为至少 25-30 分钟。
- 如果 APK 和 mapping 已经生成，但 `release/android/` 未更新，优先用更长 timeout 重新运行 `.\tools\build_android.ps1`。
- 临时救场时，可以按脚本目标把 `app-release.apk` 复制到 `release/android/tomato_english_happy_talking-android-release.apk`，把 `mapping.txt` 复制到 `release/android/mapping.txt`，再生成 SHA256 并执行 `apksigner verify --verbose`。
- 结束后可执行 `app/android/gradlew.bat --stop` 停掉 Gradle daemon。

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

## Windows Debug 缺少 ffmpeg.exe

症状：

- 听力录屏或视频导出不可用，提示：
  `程序目录缺少 ffmpeg.exe：...\app\build\windows\x64\runner\Debug\ffmpeg.exe。请重新发布程序或把 ffmpeg.exe 放到程序目录。`
- `release\windows\tomato_english_happy_talking\ffmpeg.exe` 存在，但 Debug 运行时仍然找 `app\build\windows\x64\runner\Debug\ffmpeg.exe`。

原因：

- App 固定从程序当前目录解析 `ffmpeg.exe`。
- 如果用 `flutter run -d windows` 直接启动 Debug，程序目录会变成 `app\build\windows\x64\runner\Debug`，绕过发布目录里的 FFmpeg 和运行数据。

处理：

- Windows Debug 也必须通过 `tools/build_windows.ps1` 发布到统一运行目录：

```powershell
.\tools\build_windows.ps1
.\tools\build_windows.ps1 -Run
```

- 脚本会先执行 `flutter build windows --debug`，再把 Debug 程序文件、`ffmpeg.exe` 和同目录 DLL 复制到 `release\windows\tomato_english_happy_talking\`。
- 不要直接运行 `app\build\windows\x64\runner\Debug\tomato_english_happy_talking.exe` 来验证录屏或视频导出；最终调试入口也应是 `release\windows\tomato_english_happy_talking\tomato_english_happy_talking.exe`。

验证：

```powershell
Test-Path .\release\windows\tomato_english_happy_talking\ffmpeg.exe
Test-Path .\release\windows\tomato_english_happy_talking\tomato_english_happy_talking.exe
```

两个结果都应为 `True`。启动后的设置或录屏状态中，`ffmpegPath` 应指向 `release\windows\tomato_english_happy_talking\ffmpeg.exe`。

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
- 如果发布脚本直接删除整个 `release/windows/tomato_english_happy_talking/` 再复制新构建，运行数据库、缓存、歌曲和导出文件都会被一起删掉。
- `tools/build_windows.ps1` 发布阶段只允许覆盖程序产物：EXE、DLL、`data/flutter_assets`、Flutter 运行文件、`ffmpeg.exe` 和同目录依赖。不要清空发布目录，也不要把运行数据搬出再搬回。
- 发布目录中的 `.dart_tool`、`tomato_api_cache`、`picture_book`、`suno-music`、`recording-export`、`diagnostics`、`logs` 等运行数据应保持原位。需要整理或迁移这些数据时，应单独手工执行并先核对路径。
- 联调时不要把发布目录里的 `.dart_tool` 当作普通构建缓存随手清理；它可能就是当前测试数据。

快速验证：

```powershell
Test-Path .\release\windows\tomato_english_happy_talking\.dart_tool\sqflite_common_ffi\databases\english_love.db
```

重新构建后该文件仍应存在，文章列表不应被清空；`recording-export`、`suno-music` 等用户生成资产也不应因为构建而消失。

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

## Web UI build 清理 app/assets/web 时 EPERM

症状：

- `npm --prefix web_ui run build` 在 `vite:prepare-out-dir` 阶段失败。
- 错误类似：`EPERM: operation not permitted, unlink '...\app\assets\web\assets\ui\...\*.png'`。
- 这通常不是 TypeScript 或 Vite 配置错误。

原因与处理：

- 正在运行的 Windows Debug/Release App 或 WebView 可能占用 `app/assets/web/` 里的静态资源。
- 先关闭 `tomato_english_happy_talking.exe`，再重新执行 Web UI build。
- 如果窗口不可见，先确认进程：

```powershell
Get-Process -Name tomato_english_happy_talking -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,Path
```

确认是本仓库运行的 App 后关闭窗口或结束该进程，再重跑：

```powershell
npm --prefix web_ui run build
```

## Windows 构建时 node_modules 被占用

症状：

- `tools/build_windows.ps1` 进入 Web UI 构建阶段，`npm run build` 或依赖读取因 `node_modules` 被占用失败。
- 单独 `npm --prefix web_ui run build` 可能成功，但发布脚本中同一个目录被安全软件、编辑器或测试进程短暂锁住。

处理：

- Windows 发布脚本会先用 `node_modules\.tomato-package-lock.sha256` 判断依赖是否与 `package-lock.json` 匹配；匹配时跳过重复 `npm ci`。
- 如果本地 `node_modules` 存在但构建失败，脚本会复制 `web_ui/` 到 `%TEMP%\tomato-web-ui-build-*`，在临时目录执行 `npm ci` / `npm run build`，再把临时 `app/assets/web/` 同步回仓库。
- 不要提交 `node_modules` 或 `.tomato-package-lock.sha256`；只提交刷新后的 `app/assets/web/` 静态产物。

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

## WebView 绘本图不要用 `file://` 原图路径

症状：

- 听力页、全屏播放或创作中心绘本预览出现裂图、破图，或点击缩略图后提示「原图加载失败 / 显示失败」。
- QA `/snapshot` 的 `brokenImages` 增多；`pictureBook.pageImage` 若返回 `file:///.../tomato_api_cache/...`，Web UI `<img>` 无法加载。

原因：

- 内置 WebView 页面从 `assets/web/index.html` 加载，即使开启 `allowFileAccessFromFileURLs`，也**不能**把 `release\...\tomato_api_cache\` 等运行目录下的绝对路径直接交给 `<img src>`。
- 2026-07-01 曾尝试让 `pictureBook.pageImage` `variant: full` 返回 `file://` 以绕开大 base64，结果听力与预览同时失效；已回退为 bridge data URI。
- 创作中心大图预览若在大图父层使用 `backdrop-filter: blur()`，Windows WebView2 还可能出现「先正常后花屏」的 GPU 合成问题；预览层应使用纯色遮罩分层，且不要用 `backdrop-filter` 叠在原图上。

处理：

- `PictureBookService.pageImagePayload` 的 `full` / `thumbnail` 继续通过 `_imageUriForPath` 返回 `data:image/...;base64,...`；不要把磁盘 `imagePath` 转成 `file://` 给 Web UI。
- Web UI `directImageSource` 只接受 `data:` / `blob:` / `http(s):` / bundled `assets/`；创作中心预览可先把 data URI 转成 Blob URL 再显示，并在 `onLoad` 后再露出图片。
- 修改绘本图片加载或预览层样式后，用 Release + `TOMATO_QA_REMOTE=true` 验证：`pictureBook.pageImage` 前缀为 `data:image/`，`/listening/<id>` 与创作中心缩略图预览 `brokenImages=0`。详见 `docs/qa-remote-control.md`。

## WebView2 大图 CSS 缩放花屏（听力/跟读/对话内嵌绘本图）

症状：

- 听力页、跟读页、对话页内嵌绘本场景图（`.picture-book-scene img`）、创作中心缩略图点开的大图预览、全屏听力/歌曲播放的绘本图，开始显示正常，几秒或切换后画面出现大量彩色小方块噪点（马赛克），刷新/重新打开可能复现或不复现。
- 已确认与 `backdrop-filter` 无关：此前怀疑并移除了预览层的 `backdrop-filter`（见上一节），花屏仍复现。
- 花屏图片不会被 QA `/snapshot` 判定为 broken，`brokenImages=0` 不能证明没问题。

原因：

- 绘本远程原图固定为 16:9 `2560x1440`（方舟最小像素限制导致，见 `docs/volc_ark_seedream_image_api_notes.md`），此前 `pictureBook.pageImage` 的 `full` 变体被直接拿来当 `<img src>` 在各展示场景使用。
- 把 2560x1440 的大纹理通过 CSS（`object-fit: cover` 或 `max-width/max-height` 缩放）降采样进窗口内的展示区域（内嵌容器 ~700-1120px 宽，弹层/全屏也只是窗口尺寸），Windows WebView2（Chromium + ANGLE D3D11 后端）在部分 GPU 驱动上会出现纹理采样/合成损坏，表现为随机彩色小方块噪点。降采样比例越大越容易触发，但窗口化的大图预览/全屏播放（2560 -> ~1000px）同样复现，**不能**假设“接近原图尺寸展示就安全”。
- 2026-07-02 第一次修复只把内嵌场景图换成 1280x720，保留大图预览/全屏用原图，用户实测预览/全屏仍花屏；第二次修复才把 WebView 全部展示路径统一到 1280x720，问题消失。

处理：

- 新增第三档图片变体 `display`（`PictureBookService._displayImageUriForPath`，本地缓存目录 `picture_book_display`，上限 `1280x720`，与产品定义的用户侧 16:9 `1280x720` 体验一致），介于列表 `thumbnail`（`640x360`，`picture_book_thumbnails`）和原始 `full` 之间；生成方式与缩略图一致，都是本地对已下载原图做 `_resizeImageToPng`，不重新调用生成 API。
- WebView 内**所有**大图展示一律用 `display`：内嵌场景视图（`PictureBookScene`，供 `ListeningPage`、`FollowReadPage`、`ChatPictureSceneBlock` 复用）、`usePredecodePictureBookImages` 预解码、`FullscreenListeningPlayer` / `FullscreenSongPlayer` 全屏播放、创作中心大图预览（`openPicturePreview`）。`full` 原图**永远不要**交给 WebView `<img>`，只保留在磁盘供视频导出等原生链路读取 `imagePath`。
- `pageHasPictureBookImageVariant` / `mergePictureBookPageImage` 按 `thumbnail(0) < display(1) < full(2)` 的分辨率等级比较，避免低分辨率请求覆盖已加载的高分辨率图片。
- 修改绘本图片分辨率分级或取图逻辑后，必须用 Release + `TOMATO_QA_REMOTE=true` 做视觉复核：打开听力页和创作中心缩略图预览，`/screenshot` 截图确认无噪点，并检查 `/snapshot` 中相应 `<img>` 的 `naturalWidth/naturalHeight` 是 `1280x720`（display）而不是 `2560x1440`；不要只看 `brokenImages` 计数。

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

## Vite build-html 收到 Windows 绝对入口路径

症状：

- `npm --prefix web_ui run build` 在 `vite build` 阶段失败：
  `The "fileName" or "name" properties of emitted chunks and assets must be strings that are neither absolute nor relative paths, received "F:/.../web_ui/index.html"`。
- `tsc --noEmit` 已经通过，失败出现在 `vite:build-html` / Rollup emit 阶段。

原因：

- Vite 单页应用默认会使用项目根目录下的 `index.html`。
- 在 `web_ui/vite.config.ts` 中额外写 `rollupOptions.input: 'index.html'` 时，当前 Vite/Rollup 组合会把它解析成 Windows 绝对路径，再被 build-html 当作非法输出 fileName。

处理：

- 删除单页应用不需要的 `rollupOptions.input`，保留 `base`、`plugins`、`build.outDir` 和 `emptyOutDir` 即可。

验证：

```powershell
npm --prefix web_ui run build
```

成功时应输出 `../app/assets/web/index.html`、新的 JS/CSS 资源和 `built in ...s`。

## 记录规则：只写已闭环的坑

本文件只记录已经有明确处理办法的构建、发布、联调问题。新增条目必须包含：

- 可识别的症状或错误文本。
- 原因判断。
- 可执行的处理步骤。
- 验证方法或成功信号。

如果只是遇到了问题但还没有稳定解决办法，不要写进本文件当作结论；先放在当次联调记录或任务说明里，等复现和解决路径闭环后再补。

## Flutter 命令在 Codex 沙箱内卡住

症状：

- `tools/build_windows.ps1` 卡在 `=== 检查 Flutter 环境 ===`，或者 `flutter.bat --version` 长时间无输出。
- Web UI 已构建完成，但脚本打印 `=== 构建 Windows Release ===` 后长时间没有 `Building Windows application...` 输出；此时 Release EXE 时间戳不会更新。
- 直接运行 Flutter tools snapshot 报：
  `Flutter failed to open a file at "D:\DevTools\flutter\bin\cache\lockfile"`。
- `dart.exe --version` 正常，说明 Dart SDK 本身没坏。
- 当前 Codex 受限沙箱中已经稳定复现：Flutter 相关命令会卡在 SDK cache / lockfile 阶段，不能把“先试沙箱内，失败再提权”当作默认流程。

原因：

- Flutter wrapper 需要读写 `D:\DevTools\flutter\bin\cache\lockfile`。
- 在受限沙箱里 SDK cache 目录不可写，或者上一次异常中断留下了陈旧 lockfile。
- 即使用 `FLUTTER_ALREADY_LOCKED=true` 绕过 SDK cache lock，Flutter 仍可能写用户目录中的 Dart/Flutter telemetry session；因此不要把单个环境变量当作长期解决方案。

处理：

0. Codex / 自动化会话中，所有 Flutter SDK 相关命令直接走已授权的沙箱外 PowerShell，不要先在沙箱内试跑：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command 'D:\DevTools\flutter\bin\flutter.bat analyze'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command 'D:\DevTools\flutter\bin\flutter.bat test --reporter expanded -j 1'
```

适用范围包括 `flutter --version`、`flutter pub get`、`flutter analyze`、`flutter test`、`tools/build_windows.ps1`、`tools/build_android.ps1`、`tools/run_android_debug.ps1` 和 `tools/setup_android_emulator.ps1`。纯 Web UI 的 `npm` / `tsc` / `vite` 命令不需要因此改走外部 PowerShell。

1. 先确认没有正在运行的 Flutter/Dart 工具进程：

```powershell
Get-Process flutter,dart -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,StartTime,Path
```

2. 如果没有相关进程，且确认是陈旧锁，可以删除 lockfile：

```powershell
Remove-Item -LiteralPath 'D:\DevTools\flutter\bin\cache\lockfile' -Force
```

3. 涉及 `flutter.bat --version`、`flutter analyze`、`tools/build_windows.ps1` 的命令，只在已授权的外部 PowerShell/沙箱外运行，让 Flutter 能写 SDK cache：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1 -Release'
```

验证：

- `D:\DevTools\flutter\bin\cache\dart-sdk\bin\dart.exe --version` 能正常输出。
- `flutter.bat --version` 能正常输出 Flutter 版本。
- `tools/build_windows.ps1 -Release` 能进入 Web UI 构建和 Windows build 阶段。
- 新版 `tools/build_windows.ps1` 会先关闭 Flutter analytics 并检查 `D:\DevTools\flutter\bin\cache\lockfile` 是否可写；如果在 Codex 受限沙箱内直接运行，应快速报出 Flutter cache lockfile 不可写，而不是静默卡在 Flutter build。
- 如果同一命令在沙箱外能完成、在沙箱内快速报 cache lockfile 不可写，则修复目标已经达到；后续发布构建应固定走沙箱外授权路径。

注意：

- 不要在有 `flutter` 或 `dart` 进程运行时删除 lockfile。
- 这个问题不是 Dart 代码错误，也不是 Web UI TypeScript 错误。

## PowerShell 路径含空格时必须用调用运算符

症状：

- 运行类似 `C:\Program Files\PowerShell\7\pwsh.exe -Command ...` 的命令时报：
  `The term 'C:\Program' is not recognized as a name of a cmdlet...`
- 命令本身并没有真正执行，后面的构建或测试也没有开始。

原因：

- PowerShell 会把空格前的 `C:\Program` 当作命令名。
- 给路径加引号还不够；要执行一个被引号包起来的可执行文件路径，必须使用调用运算符 `&`。

处理：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1 -Release'
```

更简单的情况，优先直接运行仓库脚本，避免多套一层 `pwsh.exe`：

```powershell
.\tools\build_windows.ps1 -Release
```

验证：

- 输出进入脚本自己的阶段，例如 `=== 检查 Flutter 环境 ===`。
- 不再出现 `C:\Program` 未识别错误。

## Windows PowerShell 5.1 缺少 Path.GetRelativePath

症状：

- `.\tools\build_windows.ps1 -Release -Run ...` 已完成 Flutter Release 构建，但发布阶段报错：
  `Method invocation failed because [System.IO.Path] does not contain a method named 'GetRelativePath'`。
- 错误出现在复制发布目录、计算相对路径或保留运行数据时。

原因：

- Windows PowerShell 5.1 使用的 .NET Framework 没有 `System.IO.Path.GetRelativePath`。
- 如果机器上没有 PowerShell 7，脚本不能依赖这个 API 才能完成真实 Windows App 发布验证。

处理：

- `tools/build_windows.ps1` 的 `Get-WindowsRelativePath` 使用 `System.Uri.MakeRelativeUri` 计算相对路径，兼容 Windows PowerShell 5.1 和 PowerShell 7。
- 如果后续再改发布复制逻辑，不要重新引入对 `Path.GetRelativePath` 的硬依赖。

验证：

- `.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true","TOMATO_QA_PORT=39317"` 能发布并启动 release 目录下的 Windows 程序。
- QA `/health` 返回 `ok: true`、`webReady: true`。

## 阿里云百聆（Fun-Music）拒绝歌词内容

症状：

- 选择阿里云百聆（Fun-Music）后返回 `Lyrics content is illegal` 或类似供应商拒绝。
- 长章节原文直接作为歌词时更容易触发长度、格式或内容限制。

处理：

- App 会先把过长或散文化章节压缩成 12 行歌曲格式，再提交给百炼；实际提交文本记录在歌曲版本的 `submittedLyrics` 中。
- 如果压缩后仍被拒绝，UI 会显示“阿里云百聆拒绝了当前歌词内容...”，不会自动回退到 Suno，避免用户误以为是另一家 provider 生成的版本。
- 歌曲字幕时间轴使用 `submittedLyrics`，不要用 BigASR 识别文本覆盖歌词正文。

## Suno Styles 为空且页面反复跳动

症状：

- Suno 自动化进入 Advanced 后，页面在 Lyrics / Styles 附近反复滚动或跳动。
- Tomato 一直显示“正在等待 Suno 自动风格生成完成...”。
- Suno 的 `Styles` 框看起来没有真实内容，字符计数仍像 `0/1000`。
- 或者 `Styles` 中短暂出现一串风格词，随后又被页面刷新回空值。

原因：

- Suno 的 `Styles` 默认 placeholder / 推荐标签是一组通用提示，不会根据当前歌词变化，不能当成自动风格结果。
- `Refresh recommended styles` 只会刷新推荐标签 / placeholder，不是根据歌词生成风格的魔法棒。
- 真正的风格魔法棒是 `Styles` 工具栏里的蓝色按钮，tooltip 为 `Personalize style prompt to match your taste`。
- 旧逻辑会把推荐 placeholder 写进 textarea；Suno 的 React 状态随后会把这个直接注入的值刷掉，于是页面像在反复跳。
- Suno 可能从 `Create` 跳到 `Discover` / Library 等页面；非 `https://suno.com/create` 页面上的 Search 输入框不能参与歌词或风格字段评分。
- 工具输入框过滤只能看 `aria-label`、`placeholder`、`name`、`id`、`type` 等字段元信息，不能看 textarea 正文。Alice 文本里出现 `in search of her hedgehog` 时，若用正文匹配 `search`，会把真正的 Lyrics / Styles textarea 错当搜索框排除。

处理：

- 每次进入 Suno 生成流程时，只填当前歌词；如果 `Styles` 折叠，先点击 `Styles` 折叠头展开到能看到 `Styles` 工具栏魔法棒，再清空旧值并点击蓝色 `Personalize style prompt to match your taste` 按钮；不要把 `More Options` 当成 `Styles` 展开入口。
- 保存过的风格只作为歌曲 metadata 便于排查，不再回填 `Styles`，也不再作为下载筛选或缓存分组条件。
- 不要点击 `Refresh recommended styles`，不要点击 `Add style: ...` 推荐标签，不要把默认 placeholder / 推荐串当成最终风格。
- 填表前先确认当前 URL 是 `https://suno.com/create`；如果 Suno 跳到其它页面，先导航回 Create，再开始定位 Lyrics / Styles。
- `Styles` 优先选择 Lyrics 下方同一列的大 textarea，排除 Search、Current page、Song Title、Enhance lyrics 等工具输入框。
- 歌词和风格填入后需要等待下一轮检测确认页面真实 value 已稳定，避免直接注入后被 React 重绘覆盖。
- Tomato 听力页不再显示或编辑 Suno 自动风格；风格由 Suno 每次根据当前歌词重新生成。

验证：

```powershell
$body = @{ type = 'suno.debugInspect'; payload = @{} } | ConvertTo-Json -Depth 4
$r = Invoke-RestMethod -Uri 'http://127.0.0.1:39317/bridge' -Method Post -ContentType 'application/json' -Body $body
$r.payload.diagnostics.editors | Select-Object tag,placeholder,text,rect
```

成功信号：

- `listening.songState` 返回 `automationStatus = waitingConfirm`。
- `stylePrompt` 可以为空；若返回非空只代表 Suno 本轮写入过 Styles metadata。
- `suno.debugInspect` 中 `Styles` 对应编辑器的 `value` 非空；不能只看 `placeholder`。
- `suno.debugFill` / 状态消息中 `magicTarget.ariaLabel` 应为 `Personalize style prompt to match your taste`，不应是 `Refresh recommended styles`。
- 对含有 `search` 等普通英文单词的歌词，`suno.debugFill` 仍能选中真正的 Lyrics / Styles textarea，而不是返回缺少 `lyrics` / `style`。
- Suno 的 Styles textarea 的 `text` 和 `placeholder` 都能看到同一段风格描述。
- 页面不再持续跳动；用户未点击确认前不会消耗 credits。

## Suno 下载到旧歌或错歌

症状：

- 在当前文章点击生成后，Suno 自动化跳到上一首或其它文章的歌曲详情页。
- Tomato 没有确认歌词是否对应，就开始下载，例如 Alice 文章误下载到 `Wrong Seat Apology`。
- 删除 `.tmp/qa-suno-song/downloads` 下的旧 metadata JSON 后，`listening.songState` 仍然返回旧 `songUrl`。

原因：

- Suno 页面和播放器可能保留上一首歌的详情页、媒体元素或 Library 菜单。
- 旧缓存中可能只剩 `songUrl` / `metadataPath`，但 metadata 文件和本地音频已经不存在。
- 仅凭 `pendingSongUrl`、页面级 `Audio` 文本或低匹配的详情页，会把旧歌当作当前文章的完整歌曲。

处理：

- 完成检测和下载检测都必须计算当前页面 / Library 行 / 菜单上下文里的歌词 token 与歌词片段匹配分。
- 下载候选必须达到当前歌词匹配阈值；短歌词按 token 数动态降低阈值，但最低仍需要 1 分。
- `pendingSongUrl` 只能在匹配详情页、匹配 Library 行或已经打开且匹配的菜单中使用；不能让侧栏、顶部 `Audio` tab 或全局 `More` 借用页面正文成为下载按钮。
- WebView 触发的媒体下载必须校验 `cdn1.suno.ai/<song-id>` 与目标 `https://suno.com/song/<song-id>` 一致，不一致就取消并提示人工处理。
- 缓存恢复时，如果只有 `metadataPath`，但文件已经不存在，且没有任何本地音频版本，应返回空状态，不再暴露旧 `songUrl`。

验证：

```powershell
$body = @{ type = 'listening.songState'; payload = @{ articleId = 24 } } | ConvertTo-Json -Depth 8
$state = Invoke-RestMethod -Uri 'http://127.0.0.1:39317/bridge' -Method Post -ContentType 'application/json' -Body $body
$state.payload | Select-Object status,audioPath,songUrl,metadataPath,automationStatus,downloadComplete,detectedSongUrls

$debugBody = @{ type = 'suno.debugSnapshot'; payload = @{} } | ConvertTo-Json -Depth 4
$debug = Invoke-RestMethod -Uri 'http://127.0.0.1:39317/bridge' -Method Post -ContentType 'application/json' -Body $debugBody
$debug.payload.downloadProbe | Select-Object ok,stage,currentPageExpectedScore,expectedMatchThreshold,title,songUrl
```

成功信号：

- 当前文章没有真实音频时，缺失 metadata 文件的旧缓存不会再返回旧 `songUrl`。
- `Wrong Seat Apology` 等旧歌详情页即使包含部分相同词，未达到歌词匹配阈值也不会下载。
- `downloadProbe` 不会把侧栏折叠按钮、顶部 `Audio` tab、全局 `More` 误判为下载入口。

## Suno Library 里有 Download 但自动下载卡住

症状：

- Suno 已生成完整歌曲，Tomato 状态停在“正在下载 Suno 歌曲版本 1 / 1...”。
- `suno.debugSnapshot` 的 `downloadProbe.target.text` 能看到 `Download Download`，但后续没有弹出 `Audio` 下载项，也没有触发 WebView 下载。
- 页面可能已经从歌曲详情页跳到 `https://suno.com/me` 的 Library。

原因：

- Suno 的 Library 菜单是前端浮层控件，某些二级菜单点击不会稳定响应 WebView 注入的合成 click 事件。
- 但完整歌曲加载到 Library/播放器后，页面 HTML 或媒体元素里通常已经暴露了目标歌曲 ID 对应的 `cdn1.suno.ai/<song-id>...` 完整媒体 URL。

处理：

- 下载逻辑先从 `audio/video/source` 和页面 HTML 中提取 `cdn1.suno.ai` 媒体 URL。
- 只接受 URL 中包含当前 `https://suno.com/song/<song-id>` 的媒体，排除 `sil-100`、preview、sample、snippet、teaser。
- App 直接下载该媒体文件并写入 Suno metadata；同一 `songUrl` 已有版本时立即跳过，不重复下载。
- 菜单点击仍保留为兜底路径。

验证：

```powershell
$body = @{ type = 'listening.songDownloadSunoExisting'; payload = @{ articleId = 25 } } | ConvertTo-Json -Depth 8
Invoke-RestMethod -Uri 'http://127.0.0.1:39317/bridge' -Method Post -ContentType 'application/json' -Body $body

$stateBody = @{ type = 'listening.songState'; payload = @{ articleId = 25 } } | ConvertTo-Json -Depth 8
$state = Invoke-RestMethod -Uri 'http://127.0.0.1:39317/bridge' -Method Post -ContentType 'application/json' -Body $stateBody
$state.payload.audioPath
```

成功信号：

- `listening.songState` 返回 `status = ready`、`automationStatus = complete`；若当前歌词所有检测到的完整歌曲都已有本地版本，则 `downloadComplete = true`。
- 本地音频文件存在，文件头为 `ID3` 或其它可播放媒体头，文件大小不是几十 KB 的占位音。
- 再次触发同一 `songUrl` 下载时，文件数量不增加，直接返回已下载版本。

## Suno 同一歌词多首歌曲只下载一首或重复下载

症状：

- Suno 一次生成同一歌词的多首完整歌曲，但 Tomato 只保存第一首，后续“检测下载”又重复打开已下载歌曲。
- 听力页已有本地版本，但无法判断哪些 `songUrl` 已经下载过。
- 用户只想补下载已手工生成的歌曲时，App 误进入创建流程，可能再次消耗 Suno credits。

原因：

- 旧缓存只保存一个 `songUrl` / 最新 metadata，无法表达同一歌词检测到多首完整歌曲。
- `versions` 没有稳定记录 `lyricsHash` / `songUrl`，无法用当前歌词判断哪些链接已经落成本地音频。
- 没有区分“检测到的完整歌曲链接”和“已经下载到本地的音频版本”，因此无法判断是否还有缺失版本。

处理：

- Suno metadata 必须按当前歌词的 `lyricsHash` / `contentHash` 恢复缓存组；`stylePrompt` / `styleKey` 只作为旧版本兼容 metadata。
- `detectedSongUrls` 保存当前歌词页面或 Library 中检测到的完整歌曲链接；`downloadComplete=true` 只在这些链接都已经有本地版本时返回。
- “检测下载”只针对 `missingSongUrls`，同一 `songUrl` 已存在本地版本时跳过，不重复下载。
- 用户点击生成新版本时，仍进入 Create 并让 Suno 根据歌词重新生成风格；用户点击检测下载时，只补当前歌词下未下载的 `songUrl`。
- 听力页歌曲弹窗使用“播放 / 生成”页签，播放页按本地版本展示歌曲，生成页用于新建 Suno 版本。

验证：

```powershell
$body = @{ type = 'listening.songState'; payload = @{ articleId = 25 } } | ConvertTo-Json -Depth 8
$state = Invoke-RestMethod -Uri 'http://127.0.0.1:39317/bridge' -Method Post -ContentType 'application/json' -Body $body
$state.payload | Select-Object status,source,downloadComplete,detectedSongUrls,versions
```

成功信号：

- `versions[]` 中同一 `songUrl` 不会重复新增本地音频版本；旧 `styleKey` 不再影响分组。
- `detectedSongUrls` 包含所有已检测到的完整歌曲链接；若只下载了一部分，`downloadComplete = false` 且“检测下载”只补缺失项。
- 同一 `songUrl` 已下载后再次检测不会新增重复音频文件。
