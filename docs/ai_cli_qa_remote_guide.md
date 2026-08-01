# Tomato App CLI / QA 远程调用指南（AI 代理版）

本文面向需要从终端控制 Tomato Windows App 的 AI 代理。目标是让代理在不操作
SQLite、不猜测 UI 状态的前提下，快速完成启动、查询、页面操作、原生 bridge 调用、
截图取证、日志排查和 QA 清理。

实现入口：

- QA HTTP 服务：`app/lib/features/web_shell/web_shell_qa_server.dart`
- QA 状态与 DOM 操作：`app/lib/features/web_shell/web_shell_screen.dart`
- typed bridge 协议：`app/lib/features/web_shell/web_bridge_protocol.dart`
- 完整 Windows 回归示例：`tools/qa_windows_release.mjs`
- 面向人工的详细说明：`docs/qa-remote-control.md`

## 1. 核心结论

- 默认地址：`http://127.0.0.1:39317`
- 仅监听 IPv4 loopback，不接受局域网访问。
- `tools/build_windows.ps1 -Run` 和 `-Release -Run` 默认启用 QA 服务。
- AI 开始操作前必须等待 `/health` 同时满足 `ok=true`、`webReady=true`。
- 验证正式内置 Web 资源时还应确认 `usesDevServer=false`。
- 页面操作使用 `/navigate`、`/snapshot`、`/click`、`/fill`、`/eval`。
- Flutter 原生业务能力使用 `/bridge`，不要直接修改运行时 SQLite。
- 异步任务不要只靠固定 sleep；使用 `/health`、`/snapshot` 或 `/logs/recent` 轮询。
- `/bridge` 的 HTTP 200 不代表业务成功；必须继续检查返回 JSON 的 `ok`。
- QA 服务可能直接读写正式 Release App 的本地数据。删除、覆盖、生成、导出前必须确认
  `articleId`、`seriesId`、句子 index 和目标目录。
- 图片、TTS、ASR、文本、歌曲等命令可能调用付费云 API。未获授权时只查询状态，不触发生成。

## 2. 30 秒启动流程

在仓库根目录运行：

```powershell
.\tools\build_windows.ps1 -Release -Run
```

等待服务与 Web UI 就绪：

```powershell
$qaBase = "http://127.0.0.1:39317"
$health = Invoke-RestMethod "$qaBase/health"
$health | ConvertTo-Json -Depth 20
```

就绪条件：

```powershell
if (-not ($health.ok -and $health.webReady)) {
    throw "Tomato QA 尚未就绪"
}
```

确认运行的是正式内置 Web 资源：

```powershell
if ($health.usesDevServer) {
    throw "当前连接的是 Vite dev server，不是正式内置 Web 资源"
}
```

列出书籍和文章：

```powershell
$body = @{
    type = "article.list"
    payload = @{}
} | ConvertTo-Json -Depth 20

$result = Invoke-RestMethod "$qaBase/bridge" `
    -Method Post `
    -ContentType "application/json" `
    -Body $body

if (-not $result.ok) {
    throw $result.error.message
}
$result.payload | ConvertTo-Json -Depth 30
```

## 3. Token 鉴权

本机临时调试可以不设置 token。需要长时间开启时：

```powershell
.\tools\build_windows.ps1 -Release -Run `
    -DartDefine TOMATO_QA_TOKEN=dev-token
```

请求头：

```powershell
$qaHeaders = @{ "X-Tomato-QA-Token" = "dev-token" }
Invoke-RestMethod "$qaBase/health" -Headers $qaHeaders
```

也支持 `?token=dev-token`，但 AI 应优先使用请求头，避免 token 出现在 URL、历史记录和日志里。
不要在文档、提交、聊天输出或截图中保留真实 token。

## 4. 推荐 PowerShell 调用封装

```powershell
$qaBase = "http://127.0.0.1:39317"
$qaHeaders = @{} # 有 token 时加入 X-Tomato-QA-Token

function Invoke-TomatoQa {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [hashtable]$Body
    )

    if ($null -eq $Body) {
        return Invoke-RestMethod "$qaBase$Path" -Headers $qaHeaders
    }

    return Invoke-RestMethod "$qaBase$Path" `
        -Method Post `
        -Headers $qaHeaders `
        -ContentType "application/json" `
        -Body ($Body | ConvertTo-Json -Depth 40)
}

function Invoke-TomatoBridge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [hashtable]$Payload = @{}
    )

    $response = Invoke-TomatoQa -Path "/bridge" -Body @{
        type = $Type
        payload = $Payload
    }
    if (-not $response.ok) {
        throw "Bridge $Type 失败: $($response.error.message)"
    }
    return $response.payload
}
```

调用：

```powershell
$library = Invoke-TomatoBridge -Type "article.list"
$library.articles
$library.series
```

## 5. HTTP 接口速查

| 方法 | 路径 | 作用 | 关键注意事项 |
| --- | --- | --- | --- |
| GET | `/health` | 进程、WebView 和轻量运行状态 | 第一条请求；等待 `webReady=true` |
| GET | `/snapshot` | DOM、按钮、表单、图片、溢出和业务运行状态 | UI 操作前后都应调用 |
| GET | `/screenshot` | 当前 WebView PNG 截图 | Windows 优先生成全页面截图 |
| GET | `/logs/recent` | 最近结构化日志 | 支持 `limit/level/category/since` |
| GET | `/logs/stream` | SSE 实时日志 | 每 15 秒 heartbeat |
| GET | `/logs/files` | 日志文件列表 | 返回脱敏后的文件信息 |
| GET | `/logs/export` | 生成诊断导出包 | 会写本地诊断包 |
| POST | `/navigate` | 导航 hash 路由 | body: `{"path":"/settings"}` |
| POST | `/click` | 点击可见 DOM 元素 | body 支持 `selector/text/exact/index` |
| POST | `/fill` | 填写 React 受控输入 | body 支持 `selector/value/index` |
| POST | `/eval` | 在主 WebView 执行 JavaScript | 返回值必须可解码为 JSON object |
| POST | `/bridge` | 调用 Flutter typed bridge | body: `{"type":"...","payload":{...}}` |

未知路径返回 HTTP 404。请求体格式错误或 handler 抛错返回 HTTP 500。Token 错误返回
HTTP 401。

## 6. 页面控制

### 6.1 导航

```powershell
Invoke-TomatoQa -Path "/navigate" -Body @{ path = "/settings" }
Invoke-TomatoQa -Path "/navigate" -Body @{ path = "/article/new" }
Invoke-TomatoQa -Path "/navigate" -Body @{
    path = "/creation?seriesId=23&articleId=72"
}
Invoke-TomatoQa -Path "/navigate" -Body @{
    path = "/books/23/player?articleId=72&mode=listening"
}
```

常用路由：

| 页面 | 路由 |
| --- | --- |
| 书库 | `/` |
| 新增章节 | `/article/new` |
| 书籍详情 | `/books/<seriesId>` |
| 书籍播放器 | `/books/<seriesId>/player?articleId=<id>&mode=listening` |
| 歌曲播放器 | `/books/<seriesId>/player?articleId=<id>&mode=song` |
| 创作中心 | `/creation?seriesId=<seriesId>&articleId=<articleId>` |
| 练习中心 | `/practice?seriesId=<seriesId>` |
| 设置 | `/settings` |

导航成功只表示路由已提交。随后轮询 `/snapshot.hash` 和 `visibleText`，确认目标页面已渲染。

### 6.2 点击

按文字：

```powershell
$result = Invoke-TomatoQa -Path "/click" -Body @{
    text = "保存章节"
    exact = $true
}
if (-not $result.ok) { throw $result.error.message }
```

按 selector 和序号：

```powershell
Invoke-TomatoQa -Path "/click" -Body @{
    selector = ".creation-tabs button"
    index = 1
}
```

匹配范围是可见的 `button`、`[role=button]`、`a`、`label`、`input`、`textarea`、
`select`。禁用元素返回 `ok=false`，不能把 HTTP 200 当成点击成功。

### 6.3 填写

```powershell
Invoke-TomatoQa -Path "/fill" -Body @{
    selector = "#article-title"
    value = "QA Chapter"
}

Invoke-TomatoQa -Path "/fill" -Body @{
    selector = "#article-content"
    value = "Tom opens a book. He reads it aloud."
}
```

`/fill` 会设置原生 value setter，并触发冒泡的 `input` 和 `change` 事件，适用于 React
受控表单。优先使用稳定的 `id`、`aria-label` 或明确的局部 selector，不使用依赖 DOM
层级的脆弱 selector。

### 6.4 Eval

`source` 应返回 JSON object 或 JSON 字符串：

```powershell
Invoke-TomatoQa -Path "/eval" -Body @{
    source = @'
(() => JSON.stringify({
  ok: true,
  title: document.title,
  hash: window.location.hash
}))()
'@
}
```

优先使用 `/snapshot`、`/click` 和 `/fill`。只有标准接口无法表达的只读检查才使用
`/eval`；不要用它绕过产品流程直接改 `localStorage`、React 内部状态或 DOM 业务数据。

## 7. Snapshot 判定方法

`/snapshot` 主要字段：

- `hash`：当前 hash 路由。
- `visibleText`：页面可见文本摘要。
- `images` / `brokenImages`：图片尺寸和破图。
- `overflowElements`：过滤隐藏控件和正常滚动容器后的可见溢出。
- `buttons`：按钮文字、disabled 和位置。
- `formControls`：输入框、textarea、select 的值和状态。
- `activeElement`：当前焦点元素。
- `pictureBookScene`：听力绘本区域的 loading/ready/error、图片、字幕、页码和重试状态。
- `runtimeState`：跟读、听力、对话、绘本、录制、WebView FPS 等原生状态摘要。

AI 的标准验证顺序：

1. 调用动作。
2. 轮询 `/snapshot`，等待目标路由、文字或 runtimeState。
3. 检查 `brokenImages` 和相关 `overflowElements`。
4. 保存 `/screenshot` 作为视觉证据。
5. 异常时查询 `/logs/recent`，不要只根据截图猜原因。

## 8. Bridge 返回结构

成功：

```json
{
  "id": "qa_...",
  "ok": true,
  "type": "article.list.success",
  "payload": {
    "articles": [],
    "series": []
  }
}
```

失败：

```json
{
  "id": "qa_...",
  "ok": false,
  "type": "article.list.error",
  "error": {
    "message": "..."
  }
}
```

部分失败会在 `error.data` 中给出续传信息，例如 `article.create` 后续步骤失败时的
`resumeArticleId` 和 `failedPhase`。AI 不应再次创建重复文章，应使用返回的
`resumeArticleId` 续传。

## 9. 常用 Bridge 示例

### 9.1 查询书库与文章

```powershell
$library = Invoke-TomatoBridge "article.list"
$article = Invoke-TomatoBridge "article.fullText" @{
    articleId = 72
}
$series = Invoke-TomatoBridge "series.list"
```

### 9.2 新建文章

纯查询 QA 不应调用本命令。创建测试数据时使用唯一 `QA` 前缀，并在 finally 中清理。
新建流程先调用 `article.prepareCreate`，它只做解析和最终英文提取，不写数据库；返回的
`preparedId` 与正文哈希绑定、15 分钟过期，并在文章正文成功写入后消费。Web/Node 可用
共享的 `read_aloud_dp_v2` 核心生成 `sentences`；人工审核稿使用 `reviewed_dp_v2`。

```powershell
$prepared = Invoke-TomatoBridge "article.prepareCreate" @{
    content = "Tom opens a book. He reads it aloud."
}
$created = Invoke-TomatoBridge "article.create" @{
    title = "QA Chapter 20260730"
    content = "Tom opens a book. He reads it aloud."
    preparedId = $prepared.preparedId
    sentences = @("Tom opens a book.", "He reads it aloud.")
    sentenceSplitVersion = "read_aloud_dp_v2"
    pictureBookEnabled = $false
}
```

挂到已有书籍：

```powershell
$created = Invoke-TomatoBridge "article.create" @{
    title = "QA Chapter 20260730"
    content = "Tom opens a book. He reads it aloud."
    preparedId = $prepared.preparedId
    sentences = @("Tom opens a book.", "He reads it aloud.")
    sentenceSplitVersion = "read_aloud_dp_v2"
    pictureBookEnabled = $true
    seriesId = 23
}
```

传入 `sentences` 时 Bridge 会逐块拒绝：空块、持久化显示换行、超过 30 词，或规范化
拼接与 `prepareCreate` 的最终英文不等价。英文显示层允许按可用宽度自动换成多行；
这种视觉换行不写入持久化句子。校验失败时不会静默重切。
`resumeArticleId` 只续传已有创建流程，不再次调用 `prepareCreate`，也不重分已保存文章。

创建过程可能调用文本、翻译或绘本规划云服务。超时应按阶段日志判断，不要重复提交。

### 9.3 重命名与删除

```powershell
Invoke-TomatoBridge "article.rename" @{
    articleId = 72
    title = "New Chapter Title"
}

# 破坏性操作：执行前重新 article.list 核对 id/title/series。
Invoke-TomatoBridge "article.delete" @{ articleId = 72 }
```

```powershell
Invoke-TomatoBridge "series.create" @{
    title = "QA Book 20260730"
    description = "Temporary QA book."
    characters = @()
}

# 只允许删除空书籍。
Invoke-TomatoBridge "series.delete" @{ seriesId = 23 }
```

### 9.4 绘本状态与图片

```powershell
$state = Invoke-TomatoBridge "pictureBook.state" @{
    articleId = 72
    includeImageUris = $false
}

$image = Invoke-TomatoBridge "pictureBook.pageImage" @{
    articleId = 72
    pageIndex = 0
    variant = "display"
}
```

`variant` 可为 `thumbnail`、`display`、`full`。WebView 视觉验证使用 `display`；
列表使用 `thumbnail`；`full` 只用于原生导出等用途，不应交给 WebView `<img>`。

读取已持久化的审核草稿不会调用图片 API：

```powershell
$review = Invoke-TomatoBridge "pictureBook.promptReview" @{
    articleId = 72
    regenerate = $false
}
```

`pictureBook.refreshPromptReview`、`confirmPromptReview`、`confirmPagePromptReview`、
`generate`、`retryPage` 会生成或重新生成内容，可能产生费用。确认前必须读取审核结果，
核对完整 scene 覆盖和目标文章。

整表重设分镜（不调文本 AI、不出图；可超过 12 景）可用：

```powershell
Invoke-TomatoBridge "pictureBook.replaceChapterPlan" @{
    articleId = 72
    chapterDescription = "Alice meets the Queen in the garden."
    scenes = @(
        @{
            pageIndex = 0
            sentenceStartIndex = 0
            sentenceEndIndex = 2
            sceneDescription = "Alice walks into the garden path."
        },
        @{
            pageIndex = 1
            sentenceStartIndex = 3
            sentenceEndIndex = 5
            sceneDescription = "The Queen points across the croquet ground."
        }
    )
}
```

要求：`articles.sentences` 已按朗读/字幕长度切好；`scenes` 必须 `pageIndex` 连续、区间无重叠且覆盖全部句子槽，描述非空。手工/QA 分镜**可以超过 12 景**；`replaceChapterPlan` 会同步 `picture_book_pages` 骨架（新页为「尚未导入图片」），随后可直接 `pictureBook.importPageImage` 逐页挂本地图。

若走 AI 组图：再 `promptReview` 核对后用 `confirmPromptReview`。**超过 12 景时 `confirmPromptReview` 会明确拒绝**（万相连续组图上限），不会删图、不会调图片 API；本地导入不受此限制。

UI 手工改景数：打开审核后设置场景数量，确认「按此数量匹配分镜」会调用
`refreshPromptReview` 并带 `targetSceneCount`（文本 AI）。

`pictureBook.importPageImage`、`exportChapterImages` 会打开系统文件选择器，纯 CLI
无人值守流程不能假设它们会自动完成。

### 9.5 听力与 TTS

```powershell
$listening = Invoke-TomatoBridge "listening.open" @{ articleId = 72 }
$status = Invoke-TomatoBridge "listening.audioStatus" @{ articleId = 72 }
```

生成缺失听力：

```powershell
$result = Invoke-TomatoBridge "listening.audioGenerate" @{
    articleId = 72
    overwrite = $false
}
```

`overwrite=true` 会覆盖既有听力材料并重新产生 TTS 成本，必须获得明确授权。

修改或软隐藏句子：

```powershell
Invoke-TomatoBridge "listening.updateSentence" @{
    articleId = 72
    index = 4
    english = "Updated English sentence."
    chinese = "更新后的中文字幕。"
    previousEnglish = "Old English sentence."
    previousChinese = "旧中文字幕。"
}
```

`index` 为 0-based。`english=""` 表示软隐藏原槽位，不会重排 index。执行前必须先通过
`article.fullText` 获取当前句子，不能凭旧截图提交。

### 9.6 跟读与对话

```powershell
Invoke-TomatoBridge "follow.open" @{ articleId = 72 }
Invoke-TomatoBridge "follow.play"
Invoke-TomatoBridge "follow.next"
```

录音命令依赖可用麦克风和系统权限：

```powershell
Invoke-TomatoBridge "follow.recordStart"
Invoke-TomatoBridge "follow.recordStop"
```

对话：

```powershell
Invoke-TomatoBridge "chat.open" @{ articleId = 72 }
Invoke-TomatoBridge "chat.sendText" @{
    text = "What happened in this chapter?"
}
```

对话可能调用实时语音或文本云服务。用 `/health.runtimeState` 和日志判断 provider 状态。

### 9.7 歌曲、视频和导出

```powershell
Invoke-TomatoBridge "listening.songState" @{ articleId = 72 }
Invoke-TomatoBridge "recording.videoList" @{ articleId = 72 }
```

歌曲生成、字幕生成、音频导出、视频录制都可能耗时较长、产生费用或打开系统窗口。
AI 在未获授权时只调用状态和列表命令。

### 9.8 设置与诊断

```powershell
$settings = Invoke-TomatoBridge "settings.load"
$logs = Invoke-TomatoBridge "diagnostics.logsRecent" @{
    limit = 100
    level = "info"
    category = "bridge,pictureBook,listening"
}
```

`settings.load` 只应返回脱敏状态。不要通过 `settings.saveCloud` 在命令行、文档或日志中
传递 API Key；凭据应由用户在 App 设置页安全输入。

## 10. Bridge 能力地图

下列名称来自当前 `BridgeRouter` 注册表。payload 的最终事实以对应 `_handle...` 方法和
Web UI 的 `sendNative(...)` 调用为准。

### App 与文章

```text
app.ready
app.navigate
app.back
article.list
article.translateToEnglish
article.suggestTitle
article.prepareCreate
article.create
article.rename
article.fullText
article.delete
```

### 书籍

```text
series.list
series.suggestDescription
series.create
series.update
series.delete
series.attachArticle
series.export
series.import
```

### 绘本

```text
pictureBook.state
pictureBook.pageImage
pictureBook.promptReview
pictureBook.pagePromptReview
pictureBook.refreshPromptReview
pictureBook.resolveRelevantCharacters
pictureBook.savePromptReview
pictureBook.replaceChapterPlan
pictureBook.confirmPromptReview
pictureBook.confirmPagePromptReview
pictureBook.cancelPromptReview
pictureBook.generate
pictureBook.retryPage
pictureBook.importPageImage
pictureBook.exportChapterImages
pictureBook.clearArticleCache
```

### 跟读

```text
follow.open
follow.play
follow.recordStart
follow.recordStop
follow.recordReplay
follow.retry
follow.next
follow.replay
follow.pause
follow.resume
```

### 听力、歌曲和视频

```text
listening.open
listening.audioStatus
listening.audioGenerate
listening.prepare
listening.preloadChinese
listening.play
listening.playSequence
listening.fullscreenReady
listening.recordingReady
listening.recordVideo
listening.cancelRecording
listening.songState
listening.songGenerate
listening.songImportExternal
listening.songTimelineGenerate
listening.songPlay
listening.songSetDefault
listening.songDeleteVersion
listening.songStop
listening.songPause
listening.songResume
listening.songRecordVideo
listening.songExportAudio
listening.updateSentence
listening.resynthesizeSentence
listening.stop
listening.pause
listening.resume
recording.videoList
recording.videoSetDefault
recording.videoPlay
recording.videoDelete
recording.videoOpenDirectory
```

### 单词、对话、设置与诊断

```text
word.lookup
word.play
word.stop
chat.open
chat.recordStart
chat.recordStop
chat.sendText
chat.replay
settings.load
settings.saveVoice
settings.saveSong
settings.saveCloud
settings.previewVoice
recording.settings.load
recording.settings.save
diagnostics.logsRecent
diagnostics.logsExport
diagnostics.clientLog
diagnostics.songAsrSnapshot
diagnostics.songTimelineFromAsrSnapshot
contentSafety.setRuleEnabled
contentSafety.deleteRule
```

快速查询某个命令的真实 payload：

```powershell
rg -n "'pictureBook.confirmPromptReview'|_handlePictureBookConfirmPromptReview|sendNative" `
    app\lib\features\web_shell\web_shell_screen.dart `
    web_ui\src\App.tsx
```

不要根据命令名字自行猜字段。

## 11. 异步任务与超时

建议等待函数：

```powershell
function Wait-TomatoState {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Check,
        [int]$TimeoutSeconds = 60,
        [int]$IntervalMilliseconds = 1000
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $value = & $Check
            if ($null -ne $value) { return $value }
        } catch {
            $lastError = $_
        }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
    throw "等待 Tomato 状态超时。最后错误: $lastError"
}
```

典型超时预算：

| 操作 | 建议预算 |
| --- | --- |
| QA 服务和 Web UI 启动 | 60 秒 |
| 普通导航、点击、表单状态 | 10–60 秒 |
| 文章保存、翻译、TTS | 2–10 分钟，按实际内容 |
| 整章绘本组图 | 最多 60 分钟 |
| Android 冷构建 | 25–30 分钟 |

轮询时保持 0.5–2 秒间隔。不要高频请求 `/snapshot`；只需原生状态时优先使用较轻的
`/health`。整章绘本用 `runtimeState.pictureBook` 或 `pictureBook.state`，不要轮询
带 base64 图片的响应。

## 12. 日志与取证

最近日志：

```powershell
Invoke-RestMethod `
    "$qaBase/logs/recent?limit=200&level=info&category=qa,bridge,pictureBook,listening" `
    -Headers $qaHeaders
```

`category` 支持逗号分隔；`level` 是最低级别；`since` 使用时间过滤。

截图：

```powershell
$target = ".tmp\qa-evidence\current.png"
New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
Invoke-WebRequest "$qaBase/screenshot" -Headers $qaHeaders -OutFile $target
```

诊断包：

```powershell
Invoke-RestMethod "$qaBase/logs/export" -Headers $qaHeaders
```

诊断导出有统一脱敏，但 AI 仍应在分享前检查内容，不提交本地日志、绝对路径、数据库、
缓存、文章全文或凭据。

## 13. 自动化脚本

启动 Windows App 后：

```powershell
npm run qa:windows
npm run qa:layout
npm run qa:picture-book-live
```

其它专项脚本：

```text
tools/qa_input_focus_probe.mjs
tools/qa_listening_hide_sentences.mjs
tools/qa_chapter_plan_dialogue_narrative.mjs
tools/qa_chapter_plan_prompt_opt_retest.mjs
tools/qa_chapter_plan_variance_retest.mjs
tools/qa_onion_chapter_e2e.mjs
```

执行前先阅读脚本参数和数据副作用。真实绘本、TTS、ASR、歌曲和视频链路可能产生费用。

## 14. AI 操作规范

### 必须

- 操作前记录 `/health`、目标 `articleId/seriesId` 和当前标题。
- 写操作前重新 `article.list` 或读取对应 state，避免使用陈旧 id。
- 每次 UI 动作后验证 `/snapshot`，每个业务动作后验证 bridge payload。
- 生成测试数据时使用唯一 `QA` 前缀，并在 `finally` 中精确删除。
- 删除后再次 `article.list` 验证，只删除本次创建的数据。
- 付费调用前确认用户授权、provider、目标文章和覆盖选项。
- 将截图、报告和临时 JSON 放入 `.tmp/` 或明确的 QA 输出目录，不提交运行产物。

### 禁止

- 不通过 QA/bridge 而直接编辑 Release SQLite。
- 使用 `git add -A` 把 QA 产物、日志、数据库、发布目录或账号配置提交。
- 在命令行或请求 JSON 中输出 API Key、密码、Cookie、Authorization。
- 将 HTTP 200、按钮存在、日志无错误单独当作业务成功。
- 对异步生成反复重试；先读状态和日志，确认失败后再决定。
- 对真实文章执行未确认的 delete、overwrite、clear cache、重新生成或句子改写。
- 用 `/eval` 绕过正常产品流程修改业务状态。

## 15. 常见故障

### 无法连接 39317

1. 确认启动的是 `tools/build_windows.ps1 -Run` 或 `-Release -Run`。
2. 检查 Tomato 进程是否仍在运行。
3. 查看启动日志中的 `qa.server.started` 或 `qa.server.start_failed`。
4. 确认端口未被其它进程占用。

### `/health` 可用但 `webReady=false`

WebView 尚未完成加载或加载失败。等待并查询日志，不要立刻调用 DOM 接口。

### `/click` HTTP 200 但没有动作

检查响应自身的 `ok`。常见原因是元素 disabled、文字匹配到错误元素或 index 不正确。
先看 `/snapshot.buttons`，再使用更精确的 selector。

### `/bridge` HTTP 200 但业务失败

检查 bridge envelope 的 `ok=false` 和 `error.message/error.data`。HTTP 层只表示请求已被
QA 服务处理。

### 构建后仍缺少 `/eval` 或新命令

关闭正在运行的旧 EXE，重新构建并从
`release/windows/tomato_english_happy_talking/` 启动。不要误用旧构建目录中的程序。

### 长任务看似超时

先检查 `/health.runtimeState`、`/logs/recent` 和业务 state。区分“HTTP 客户端超时”、
“任务仍在后台运行”和“服务已明确失败”，不要盲目重复提交。
