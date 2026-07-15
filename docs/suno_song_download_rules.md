# Suno 歌曲版本规则

> **2026-07-11 产品变更**：App 内 Suno WebView 自动化与创作中心「检测下载」已移除。新流程为：生成时复制歌词并打开系统浏览器 Create → 用户在 Suno 下载 MP3 → 回到 App 用「导入本地音乐」添加版本。下文「检测下载 / Library 扫描 / post-create 自动化」章节仅作历史归档。

## 当前产品流程（系统浏览器手动）

1. 创作中心 →「生成 Suno 歌曲」→ 确认弹框
2. App 复制整篇英文歌词到剪贴板，系统浏览器打开 `https://suno.com/create`
3. 用户在浏览器登录、粘贴、设风格、Create，并在 Suno 网站下载 MP3
4. 回到创作中心 →「导入本地音乐」→ 选择 MP3，纳入本地歌曲版本列表
5. 生成歌曲字幕、播放、导出与百聆 / 外部导入版本相同

实现入口：`app/lib/features/web_shell/suno/suno_external_launcher.dart`（`launchManualCreate` / `manualActionMessage`）。

可选技术备忘（非正式路径）：跳过网页填写、HTTP 提交歌词的开源方案调研见 `docs/suno_cli_http_automation_notes.md`。

## 归属边界

- 一篇文章的歌曲版本归属以 `articleId` 为准；同一文章可有多个本地版本（不同来源、不同导入文件）。
- 历史 Suno 自动化 cache 仍按 `articleId` 展示；`lyricsHash` 仅用于 dedup 与 metadata，**禁止**用当前 hash 过滤已落盘版本。规则见 `docs/article_song_version_retention.md`。
- Suno 历史音频与 metadata 保存在持久目录 `suno-music/`（设置页「Suno 输出目录」）。

## 字幕与导出联动

- 歌曲字幕时间线要记录当前对齐算法版本；旧版本时间线只显示为 `stale`，不能直接用于歌曲视频录制。
- 重新生成字幕时优先使用歌曲版本自己的 `submittedLyrics`，不要把文章逐句翻译强行复用到压缩歌词或外部导入音频上。
- 歌曲视频导出必须读取当前时间线；没有时间线、时间线过期或 cue 为空时，先提示用户重新生成字幕。

---

## 历史归档：检测下载与 WebView 自动化（已移除）

以下规则曾用于 `listening.songDownloadSunoExisting` 与 `SunoAutomationController`，已于 2026-07-11 删除。保留供排查旧 cache / 日志 / fixture 时参考。

### 检测流程（旧）

- Library 页面只做候选召回；候选详情页必须通过歌词匹配校验后才能下载。
- 「检测下载」每次点击都打开 Suno WebView 扫描 Library → 详情页核对 → 下载缺失版本。
- Library **广召回**：不得要求行级 `expectedScore > 0` 才打开详情页；DOM 自上而下打开未下载的 `/song/` 行。

### Post-create 阶段（旧）

- Create 提交后打开侧栏新 `/song/` 详情页，等待生成完成并下载；一次 Create 通常两首同歌词歌曲。
- 使用 `SunoCreateBatch` / `SunoCompletionPolicy` 跟踪 pending 与 complete 条件。

### 详情页下载菜单（2026-07 旧 UI）

- 新版 Suno More 菜单无 `role="menu"`；纯 `Download` 标签优先于 More 触发器，避免下载死循环。

### 回归样例（旧自动化）

- `E03 - Alice's Long Fall`、`E26 - The Royal Procession` 等同歌词多首 Library 行均应下载为同一文章多个版本。
