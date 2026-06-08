# 本机 QA 控制接口

当外部窗口捕获或 in-app browser 无法直接操作 Windows 版时，可以临时开启 App 内置的本机 QA 控制接口。它只监听 `127.0.0.1`，默认关闭，必须通过 `--dart-define` 显式开启。

## 启动方式

Debug 运行：

```powershell
.\tools\build_windows.ps1 -Run -DartDefine TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317
```

Release 构建并运行：

```powershell
.\tools\build_windows.ps1 -Release -Run -DartDefine TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317
```

可选：设置访问 token。

```powershell
.\tools\build_windows.ps1 -Run -DartDefine TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317,TOMATO_QA_TOKEN=dev-token
```

设置 token 后，请求需要带请求头：

```powershell
$headers = @{ "X-Tomato-QA-Token" = "dev-token" }
```

## 接口

## 自动回归脚本

当 Windows EXE 已用 `TOMATO_QA_REMOTE=true` 启动后，可以直接跑完整主流程回归：

```powershell
npm run qa:windows
```

脚本会检查：

- QA 服务加载的是内置 Web 资源，不是 Vite dev server。
- 首页、新增文章、设置、跟读、对话页面没有破图和可见溢出。
- 新增文章初始为空，保存按钮初始禁用，填入英文后出现短句预览。
- 设置页使用可滚动声音卡片列表，而不是下拉框。
- 跟读页初始录音禁用，播放完原音后录音和重播可用。
- 对话页进入 `userIdle` 后输入框可用，并使用 LEGO 奖励图标。
- 旧 `monster-*`、`reward-*`、`tomato-*` 资源没有被渲染。
- 测试文章会在结束时删除。

默认截图保存到 `.tmp/qa-windows/`。可选参数：

```powershell
node .\tools\qa_windows_release.mjs --port 39317
node .\tools\qa_windows_release.mjs --token dev-token
node .\tools\qa_windows_release.mjs --no-screenshots
```

绘本整章组图和听力模式需要跑真实异步链路，不要只用 service
test 代替。先用 QA 接口启动 Windows App，再运行：

```powershell
npm run qa:picture-book-live
```

默认会读取 Alice E27 粘贴文本，使用 UI 新增文章页保存到
`Alice's Adventures in Wonderland`，打开听力页，确认真实 WebView
显示“绘本图正在生成中...”，长轮询 `/health.runtimeState.pictureBook`
等待整章组图进入 `ready` / `error` / `partial` / `skipped`，再验证首句
字幕、重听本句播放和第 6 句切到第 2 张绘本页。脚本不点击真实重试按钮；
失败时只记录失败文案和重试按钮状态。

可选参数：

```powershell
node .\tools\qa_picture_book_live.mjs --picture-timeout-minutes 60
node .\tools\qa_picture_book_live.mjs --text C:\path\chapter.txt --title "E27 - The Queen's Croquet-Ground"
node .\tools\qa_picture_book_live.mjs --no-screenshots
```

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/health
```

获取页面状态、图片加载、溢出元素、按钮等信息：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/snapshot
```

`/snapshot` 会返回 `images`、`brokenImages`、`overflowElements`、`buttons`、`formControls`、`pictureBookScene` 和 `runtimeState`。`formControls` 可用于确认输入框是否已清空；`pictureBookScene` 可用于确认真实 WebView 当前绘本区域是 loading、ready 还是 error，并读取页码、失败文案、重试按钮、字幕和图片尺寸；`runtimeState.follow.step` / `runtimeState.follow.playbackState` 可用于确认跟读播放是否处于 `loadingTts`、`playing` 或已恢复到 `idle`。`runtimeState.pictureBook` 是轻量页状态摘要，不包含 base64 图片，适合长轮询整章组图生成。

`/health` 也会返回 `runtimeState`，适合在不需要 DOM 快照时快速看当前跟读 / 对话 provider 状态。

`overflowElements` 会过滤 `.visually-hidden`、`hidden`、`aria-hidden`、1px 隐藏控件和正常可滚动容器。排查遮挡时优先看剩余的可见溢出项；声音列表这类内部滚动区域不应被当作布局错误。

保存当前 WebView 截图：

```powershell
Invoke-WebRequest http://127.0.0.1:39317/screenshot -OutFile .tmp\tomato-ui.png
```

导航页面：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/navigate `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"path":"/settings"}'
```

按按钮文字或 CSS selector 点击页面元素：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/click `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"text":"保存任务"}'

Invoke-RestMethod http://127.0.0.1:39317/click `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"selector":"button","text":"发送"}'
```

如果命中的元素是 disabled，`/click` 会返回 `ok: false`，避免把不可点击按钮误判为成功操作。

填写输入框或文本域，接口会触发 `input` / `change` 事件，适合 React 受控表单：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/fill `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"selector":"input","value":"Space Snacks"}'

Invoke-RestMethod http://127.0.0.1:39317/fill `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"selector":"textarea","value":"Tom is on a space trip."}'
```

调用原生 bridge 命令：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/bridge `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"type":"article.list","payload":{}}'
```

打开跟读页并播放当前句子：

```powershell
Invoke-RestMethod http://127.0.0.1:39317/bridge `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"type":"follow.open","payload":{"articleId":1}}'

Invoke-RestMethod http://127.0.0.1:39317/bridge `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"type":"follow.play","payload":{}}'
```

## 安全约束

- 该接口只用于开发和 QA，不要在普通发布包中默认开启。
- 该接口只绑定 `127.0.0.1`，不监听局域网地址。
- 如果需要长时间开启，建议设置 `TOMATO_QA_TOKEN`。
- 不要通过该接口传入 API Key、密码或其他敏感信息。

## 排查建议

如果 Windows 版出现破图，优先看 `/snapshot` 的 `brokenImages`。

如果怀疑页面遮挡或布局溢出，优先看 `/snapshot` 的 `overflowElements`，再用 `/screenshot` 保存当前画面复核。

如果按钮状态不对，查看 `/snapshot` 的 `buttons`，确认按钮文本、禁用状态和位置。

## 当前 UI 回归检查清单

每次改完 Web UI 并重新构建 Windows 版后，至少检查：

- 首页：`brokenImages` 为 0，番茄形象不遮挡奖励卡，主按钮能进入新增文章或跟读。
- 新增文章：标题和正文初始为空，`保存任务` 初始禁用；填入英文后出现短句预览，保存后回到大厅。
- 设置：声音用可滚动列表展示，没有下拉框；当前声音能在右侧显示，保存后按钮恢复禁用。
- 跟读：初始只允许 `播放原音` 和跳过/完成；播放时有准备/播放提示；最后一句按钮显示 `完成`；伙伴状态按听原音、跟读录音、查看得分切换。
- 对话：用户空输入时 `发送` 禁用；用户可输入状态显示 `轮到你说英语啦。`；AI 说话或处理时输入框禁用；奖励图标使用 LEGO 道具。
- QA 状态：`/snapshot.runtimeState.follow.step` 和 `playbackState` 能解释按钮状态，不只依赖截图猜测。
