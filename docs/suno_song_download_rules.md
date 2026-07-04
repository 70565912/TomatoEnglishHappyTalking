# Suno 歌曲下载检测规则

## 归属边界

- 一篇文章的 Suno 歌曲归属以文章歌词匹配为准。
- 同一篇文章可以生成不同风格的多首歌曲；风格、标题、时长、生成顺序都不能作为排除条件。
- `songUrl` 只表示某个具体 Suno 版本，不表示当前文章已经下载完整；如果同歌词还有其它 `songUrl`，仍要继续检测和下载。

## 检测流程

- Library 页面只做候选召回：允许用标题、页面文本、轻量歌词 token 分数找可能属于当前文章的候选。
- Library 候选不能直接保存音频，也不能直接标记 `downloadComplete=true`。
- 候选详情页必须通过当前文章歌词匹配校验后，才能提取媒体地址或触发下载。
- 候选详情页歌词不匹配时，把该 `songUrl` 加入本次 rejected 集合，回到 Library 继续找下一个候选。
- 已下载版本和未下载候选要分别处理：已下载的 `songUrl` 不能让检测提前完成，除非 Library 没有可核对的其它候选。

## Post-create 阶段（Create 已提交后）

- 用户确认 Create 并通过 Suno 真人审核后，Create 页右侧会出现新的 `/song/` 条目；Tomato 应打开候选**歌曲详情页**，在页面上等待生成完成、核对歌词，再进入下载流程。
- `_sunoCreateSubmitted == true` 时，**不得**再执行 Create 填表/魔法棒/等待 Styles 分支，也不得因 `manualAction`/`failed` 状态把 WebView 拉回 `/create`。
- 点击 Create 前会用 `_snapshotSunoPreCreateSongUrls` 把 Create 页面上已有的旧歌 URL 记入 rejected，避免真人审核完成前误跳到旧歌详情页；只有审核后出现的新 URL 才作为 post-create 候选。
- 从 Create sidebar 打开 post-create 候选时，应把该 URL 加入 trusted 集合，以便详情页歌词尚未完全展示时 completion 探针仍识别当前歌曲。
- 详情页 settled 但歌词尚未 exact match 时：若歌曲仍在 generating（completion 返回 `currentPageGenerating`）或 post-create 首轮候选，**等待**而非 reject；只有非 post-create 的 Library 补下载流程才在确认不匹配后 reject 并换候选。
- 详情页歌词已匹配但下载菜单/媒体地址尚未就绪时，保持 `downloading`/`creating` 继续 polling，不要过早 `manualAction` 并 cancel 自动化。

## 详情页下载菜单（2026-07 新版 UI）

- 新版 Suno（`hxc-btn` 设计系统）的歌曲详情页 More 菜单容器不带 `role="menu"`、radix popper 或 floating-ui portal 标记，打开后的 `Download` 菜单项无法通过 `menuLayerSelector` 判定为 `inOpenMenu`。
- 已核对歌词（或 trusted）的歌曲详情页上，纯 `Download` 标签按钮（`isDownloadAdvanceItem`）优先于 `More menu contents` 触发器被点击；否则查找器会一直回落到 More 触发器，反复开/关菜单形成下载死循环。
- 点开 `Download` 后出现的 `MP3 Audio` 等具体格式项由既有 direct 规则（`download audio|mp3`）命中并触发真实下载。
- `Download Cover Image` 按钮含 `image`，会被 reject 规则过滤，不会被误点。
- 该优先级在 `web_ui/src/sunoAutomationSimulator.ts` 有同构实现和回归测试（`clicks the new-UI Download menu item that is not detected as inOpenMenu`）。

## 字幕与导出联动

- 歌曲字幕时间线要记录当前对齐算法版本；旧版本时间线只显示为 `stale`，不能直接用于歌曲视频录制。
- 重新生成字幕时优先使用歌曲版本自己的 `submittedLyrics`，不要把文章逐句翻译强行复用到压缩歌词或外部导入音频上。
- 歌曲视频导出必须读取当前时间线；没有时间线、时间线过期或 cue 为空时，先提示用户重新生成字幕。

## 回归样例

- `E03 - Alice's Long Fall` 在 Suno Library 中可能出现两首 `Down the Rabbit Hole`，都属于同一篇文章。
- `E26 - The Royal Procession` 在 Suno Library 中可能出现两首 `The Queen's Croquet Ground`，都属于同一篇文章。
- 上述样例即使风格或 metadata 不同，只要详情页歌词匹配，都应下载为同一文章下的多个本地歌曲版本。
