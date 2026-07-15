# Suno Lexical Lyrics 编辑器（v5.5+）

## 背景

Suno Create 在 v5.x 将 **Lyrics** 从原生 `<textarea>` 改为 **Lexical** 内联编辑器：

```html
<div aria-label="Lyrics editor"
     class="lyrics-editor-content touch-pan-y"
     contenteditable="true" role="textbox"
     data-lexical-editor="true">
  <p class="lyrics-paragraph"><span data-lexical-text="true">...</span></p>
</div>
```

**Styles** 仍是原生 `textarea`，自动化必须分叉处理。

权威 DOM 样本与 Playwright 分析见 `docs/fixtures/suno/`。

## DOM 对照

| 字段 | 旧版 | 新版 v5.5 |
|------|------|-----------|
| Lyrics | `<textarea>` | `.lyrics-editor-content[role=textbox]` |
| 文本读取 | `value` / `innerText` | `[data-lexical-text="true"]` 节点拼接 |
| 字符计数 | 字段附近 `N/5000` | `aria-describedby` 或面板内 `3829 of 5000` / `3829/5000` |
| Styles | `textarea` | 仍为 `textarea`（不变） |

## 根因：文章 <5000 却显示 >5000

**不是**数据库文章超长，而是 Tomato 读写路径在 Lexical 上失真：

1. **写入叠加**：旧逻辑 180 字分块 `insertText`，失败时 `appendChild` 裸文本；`textContent=''` 不能清空 Lexical 状态；4s tick 重试导致内容叠加。
2. **读取虚高**：对 lyrics 面板 wrapper 读 `innerText`，会把工具栏、Cowriter、计数器文案一并计入（QA 曾见 `5985/3099` ≈ 2× 预期）。

Playwright 人工填入 3829 字时，只读 `.lyrics-editor-content` 内 `[data-lexical-text]` 与 Suno 计数器 **一致**（见 `lexical-v55-manual-fill-analysis.json`）。

## 根因：WebView 崩溃

- 高频 `evaluateJavascript` + 分块写入风暴（3262 字 / 180 ≈ 18 次/轮）
- 非 Lexical 安全路径（历史 `innerHTML`、全屏编辑器、**synthetic ClipboardEvent 注入歌词**）
- **粘贴后仍每 2s 跑 `inspectScript` / `readSunoLyricsCounter` 读 `document.body.innerText` 或 Lyrics 面板父链 `innerText`**：人工一次粘贴后没有这类 DOM 全量扫描；Lexical 正在落 3000+ 字白字节点时，WebView2 容易因此崩溃（白字已出现仍崩，即此因）
- 人工一次粘贴 3829 字不崩 → 问题在自动化策略，不是 5000 上限

### Windows：App 内 WebView 键盘输入必崩（2026-07-11 确认）

隔离测试（无自动化、无抓帧限速、`display_only` 纯展示）下，在 App WebView 的 Suno Lexical Lyrics 里**输入 1 个字符**约 14s 后进程仍会退出。根因在 `flutter_inappwebview_windows` 的 WebView2 + Lexical 键盘/IME 链路，**与 Tomato 自动化无关**。

**2026-07-11 追加**：独立 [InAppBrowser] 弹窗（HWND WebView2，非主 WebView texture capture）在 Lexical Lyrics **手动输入字符同样导致 App 崩溃**（article 84 日志 `popup_create.open` → `popup_test.create_ready` 后进程退出）。弹窗**不能**作为 Create 正式路径。

**Windows 正式方案（2026-07-11）**：不再在 App 内打开 Suno Create（主 WebView 或弹窗均会在 Lexical 键盘输入时崩溃）。产品改为：

1. 歌词复制到系统剪贴板
2. 用**系统浏览器**打开 `https://suno.com/create`（用户登录/粘贴/Create/下载 MP3）
3. 用户回到 App，用「导入本地音乐」添加 MP3 版本

实现：`SunoExternalLauncher.launchManualCreate`（`app/lib/features/web_shell/suno/suno_external_launcher.dart`）。

若日后评估「不走 Lexical、直接 HTTP 提交歌词」的非官方自动化，参见开源对照笔记 `docs/suno_cli_http_automation_notes.md`（[paperfoot/suno-cli](https://github.com/paperfoot/suno-cli)：JSON `prompt` + `v2-web` + 本机 Chrome 过 hCaptcha）。**不**应再尝试 App 内 WebView2 填词。

历史环境变量（App 内 WebView 实验，已不作为正式路径）：

| 变量 | 说明 |
|------|------|
| `TOMATO_SUNO_EXTERNAL_BROWSER=false` | 曾尝试 App 内主 WebView Create（Lexical 输入崩溃） |
| `TOMATO_SUNO_POPUP_BROWSER=true` | 曾尝试弹窗 Create（同样崩溃） |
| `TOMATO_SUNO_DISPLAY_ONLY=true` | 调试用纯展示 |

## 最终方案：系统浏览器手动流程

```text
创作中心 → 生成 Suno 歌曲 → 剪贴板 + 系统浏览器 Create
用户：登录 / 粘贴 / 风格 / Create / 在 Suno 下载 MP3
创作中心 → 导入本地音乐 → 版本列表 / 字幕 / 播放 / 导出
```

- **已删除**：App 内 WebView 填表、`SunoAutomationController`、创作中心「检测下载」「确认创建歌曲」、Suno 顶栏、`tools/qa_suno_*` 联调脚本。
- **保留文档**：本文 Lexical DOM、崩溃根因、粘贴/探针踩坑时间线，供理解为何放弃 in-app 自动化。

以下「正确自动化策略 / Live 验证」章节为**历史归档**（代码已删）。

| | 人工 Ctrl+V | 旧自动化 |
|--|-----------|---------|
| 粘贴 | 一次全文 | 一次 CDP paste（已对齐） |
| 粘贴后 DOM 读取 | 无 | 每 2s `inspectScript` → `body.innerText` |
| 计数器探针 | 无 | `readSunoLyricsCounter` 读父链 + `body.innerText` |
| Flutter 状态 | 无 | 每 2s `setStatus` → rebuild |

修复：**粘贴后 15s 内零 WebView JS**；`inspectScript` 在 Create+Lexical 时只读顶栏/按钮 chrome；`readSunoLyricsCounter` 只读 `aria-describedby` 计数节点，不读 body/面板 innerText。

## 正确自动化策略

| 操作 | 做法 |
|------|------|
| 定位 | `.lyrics-editor-content[aria-label="Lyrics editor"]`，排除 `[aria-label="Cowriter prompt"]` |
| 写入 | **一次全文真实粘贴**：`Clipboard.setData(全文)` → 光标落在空编辑器首行 → WebView CDP `Ctrl+V`（**禁止**分段/JS 注入/全选删除） |
| 读取 | `readLexicalLyricsValue`：拼接 `[data-lexical-text="true"]` |
| 成功信号 | 白字 `[data-lexical-text="true"]` + counter **100%** 等于预期字符数 + hash 完全匹配 |
| 频率 | 每 session **只自动粘贴一次**；粘贴后 **15s 内禁止任何 page JS**（含 `inspectScript`）；探针只读 counter 节点与 `[data-lexical-text]` hash |
| Styles | 验证歌词阶段 **关闭**（`skipStyles: true`）；`lyricsPasteOk` 后才开 Styles |

控制器：`SunoWebViewPaste` + `suno_automation_controller.dart` Create tick。

## Dart 嵌入 JS 转义坑（必读）

`suno_web_scripts.dart` 里 Suno WebView 脚本分两类字符串，**转义规则相反**，混用必炸：

| Dart 写法 | 用途 | JS 正则 `\d` 应写 | JS 正则 `\s` 应写 |
|-----------|------|-------------------|-------------------|
| `r'''...'''` raw | `_lexicalLyricsHelperJs` 及嵌入它的脚本 | `\d` | `\s` |
| `'''...'''` 普通 | `createLyricsPasteTickScript`、`inspectScript` 等独立脚本 | `\\d` | `\\s` |

### 已反复出现的错误

1. **在 `r'''` helper 里对 regex 使用 Dart 双反斜杠（如 `\\d`、`\\s*\\/`）**
   - Node 报 `SyntaxError: Invalid regular expression flags`
   - WebView `evaluateJavascript` 返回空 → 日志 `focus_failed` + `data:{}` → UI「未能定位 Lyrics 编辑器」
   - **正确（raw 单反斜杠）**：`joined.match(/(\d+)\s*\/\s*5000/)`

2. **在 `r'''` 里写 `'\\n'` 当 join 分隔符**
   - 得到字面量 `\` + `n`，不是换行（counter 拼接仍可用，但不要误以为已是 `\n`）

3. **把 helper 嵌进普通 `'''` 后又对 regex 二次转义**
   - helper 内容已定型，嵌入时只 `$ _lexicalLyricsHelperJs` 拼接，不要再改 helper 内 `\d` 为 `\\d`

4. **粘贴后读 `document.body.innerText` / Lyrics 父链 `innerText`**
   - 人工粘贴后不扫 DOM；自动化每 2s 扫会崩（见「WebView 崩溃」）
   - counter 只读 `#lyrics-editor-char-count` 等小节点

### 改完必跑

```powershell
cd app
flutter test test/suno_lexical_lyrics_test.dart
```

其中 **`Suno injected JavaScript syntax`** 组会对生产脚本跑 `node --check`；失败即语法错误，**不得** merge 或只跑 live QA。

手工抽查（可选）：

```powershell
# 导出后 node --check；或改 test 里脚本列表
dart run tool/validate_suno_scripts.dart
```

## 禁止项

- OS 级 `SendInput` Ctrl+V（会贴到 Cursor 等前台窗口）
- CDP `Input.insertText` 全文注入 Lexical
- 打开全屏 Lyrics 编辑器
- `innerHTML` / `textContent` bulk 赋值
- 180 字分块、`appendChild` 兜底
- 读 lyrics 面板 wrapper 的 `innerText`
- 同一 tick 内 `fillScript` + 歌词双写
- `lyricsWriteAttempted == true` 时强制 `lyricsAlreadyPresent = true`
- Lyrics 未确认时点击 Styles 展开 / 魔法棒 / 滚动 Styles

## 干扰项

- `[aria-label="Cowriter prompt"]`：独立 textbox，必须排除
- Search / Current page / Song Title / Enhance lyrics 等工具框
- Styles textarea 与 Lyrics Lexical 分叉

## 资料索引

| 文件 | 说明 |
|------|------|
| `docs/fixtures/suno/lexical-v55-manual-fill-analysis.json` | 3829 字人工填入分析 |
| `docs/fixtures/suno/lexical-v55-lyrics-editor-outerhtml-sample.txt` | 编辑器 outerHTML 样本 |
| `docs/fixtures/suno/lexical-v55-manual-fill-screenshot.png` | 截图 |
| `docs/fixtures/suno/lexical-v55-create-page-snapshot.txt` | Create 页快照（可选） |
| `app/test/suno_lexical_lyrics_test.dart` | fixture 回放 + **`node --check` 语法门禁** |
| `app/tool/validate_suno_scripts.dart` | 手工跑 `node --check` 抽查全部生产脚本 |
| `tools/qa_suno_fill_quick.mjs` | 快速联调：不崩溃 + counter/lexical 通过 |
| `tools/capture_suno_lyrics_dom.mjs` | 重新抓取 DOM（需已登录 Suno） |

## 复现 / 更新抓取

```powershell
# 1. 启动 App（QA 接口）
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317"

# 2. 浏览器登录 suno.com/create，人工填入长歌词后：
node tools/capture_suno_lyrics_dom.mjs

# 3. 将 output/playwright/ 新产物复制到 docs/fixtures/suno/ 并更新本文件
```

## Live 验证（Agent / 开发必跑）

修改 Suno Lexical 填表、粘贴、探针或相关 QA 脚本后，**同一轮会话内必须跑 live**，不得只提交单元测试或文档。

| 步骤 | 命令 | 说明 |
|------|------|------|
| 1 | `flutter test test/suno_lexical_lyrics_test.dart` | 脚本/fixture 回归（沙箱外 Flutter） |
| 2 | `npm run qa:suno-fill-loop` | **默认**：rebuild + 最多 3 次 article 84 联调 |
| 单次 | `node tools/qa_suno_fill_loop.mjs --articleId 84 --rebuild --attempts 1` | 快速单次 |

前提：Suno 账号已在 App WebView 登录；QA 接口 `127.0.0.1:39317`（`build_windows.ps1 -Run` 或 `TOMATO_QA_REMOTE=true`）。

**通过条件**（与 `tools/qa_suno_fill_quick.mjs` 一致）：

- App **不崩溃**
- 日志 `create.clipboard_paste`，`pasteMethod` 为 `osCtrlV` / `cdpCtrlVKeys` / `cdpCtrlV` 之一
- 自动化状态进入 `waitingConfirm`，且 **20s 内 App 不崩溃**（粘贴后轮询已停止，避免 `inspectScript` 干扰 Lexical）

失败时：读 `output/qa/suno-fill-quick/suno-fill-quick-report.json`、截图与 `logs/` 中 `category=suno`；修复后 **再次 rebuild + loop**，不要留「待用户验证」。

## 联调（手动）

```powershell
.\tools\build_windows.ps1 -Run -DartDefine "TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317"
node tools/qa_suno_fill_quick.mjs --articleId 84
# 或自动 rebuild + 重试：
npm run qa:suno-fill-loop
```

成功条件：App 不崩溃；日志 `create.clipboard_paste` 且 `pasteMethod=cdpCtrlV`；状态 `waitingConfirm`；**本轮不点击 Styles**（粘贴后不做 counter/全文探针）。
