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

## 检测下载（`listening.songDownloadSunoExisting`）

创作中心「检测下载」与 Create 提交后的自动下载是两条入口，但检测下载有独立产品约束：

- **每次**用户点击「检测下载」，都必须打开 Suno WebView 并执行完整扫描流程（Library 召回 → 详情页歌词核对 → 下载缺失版本）。
- **禁止**因本地 `downloadComplete=true`、`missingSongUrls` 为空、或已有本地 `versions` 而在 `_startExistingSunoDownload` 入口直接返回 `ready`、不打开 Suno。用户常见工作流是：在 Suno 网站用不同风格多次 Create → 回到 App 点「检测下载」拉回新歌。
- `downloadComplete` / `missingSongUrls` / `detectedSongUrls` 只描述**当前缓存里已知链接的落盘状态**；不能代替「重新进 Suno 扫描 Library 是否有同歌词的新 `songUrl`」。
- 同一 `songUrl` 已有本地音频时，本轮**跳过该链接的重复下载**，但自动化仍应继续 Library 扫描，直到没有新的歌词匹配候选、或达到超时 / `manualAction` 安全停止。
- 若已知 `missingSongUrls` 非空，可优先打开第一个缺失链接；若为空，默认从 `https://suno.com/me` Library 开始扫描。
- **Library 广召回**：Suno Library 行通常只有标题 + 风格描述，不含全文歌词。检测下载（`_sunoExistingDownloadOnly`）以及 Create 提交后的 downloading 阶段（`_sunoUseLibraryBroadRecall`）时，**不得**要求 Library 行 `expectedScore > 0` 或 `sameTitle` 才打开详情页；否则新生成、标题与旧版本不同的歌曲会被跳过。上述阶段应按 Library **DOM 自上而下**依次打开未下载/未拒绝的 `/song/` 行，在详情页做歌词 exact match 后再下载。
- 实现锚点：`app/lib/features/web_shell/suno/`（`SunoAutomationController`）、`web_shell_screen.dart` bridge 胶水。修改检测下载路径前必须先读本节。

## Post-create 阶段（Create 已提交后）

- 用户确认 Create 并通过 Suno 真人审核后，Create 页右侧会出现新的 `/song/` 条目；Tomato 应打开候选**歌曲详情页**，在页面上等待生成完成、核对歌词，再进入下载流程。
- Suno 一次 Create 通常会生成**两首**同歌词完整歌曲；post-create 使用 **`SunoCreateBatch`** 跟踪 Create 侧栏新 URL（排除 pre-create 快照）作为诊断和已下载标记来源，但 pending 残留不再驱动回 Create。
- post-create 下载阶段与「检测下载」共用 **Library 广召回 + DOM 自上而下**扫描；首首落盘后统一回到或留在 Library 继续，不得在 Library 仍有候选时 `complete`。
- **Create 页歌词探测**：completion 脚本只读侧栏 clip 文本做 `currentPageLyricsExactMatch`，**不得**用 Lyrics/Styles 表单 textarea 全文（否则会误判已匹配并过早打开第一首详情）。
- completion 返回 `createSidebarSongUrls` / `createSidebarGeneratingCount`；Dart 记 `batch.sidebar_detected` 日志。
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

## 仿真回放 fixture（`tomato_suno_replay_fixture_v1`）

- 存放目录：`app/test/fixtures/suno/`（TS vitest 与 Dart `suno_fixture_replay_test.dart` 共用）。
- 从联调现场导出：在 Suno WebView 关键步骤调用 `suno.debugSnapshot`，再用 `node tools/suno_snapshot_trim_fixture.mjs <snapshot.json>` 裁剪；手工补全 `expected` 与 `automation.batch`。
- 回放入口：`web_ui/src/sunoFixtureReplay.ts`（`replaySunoFixture` / `decidePostCreatePhase` / `assertSunoReplayFixture`）。
- 验收：`npx vitest run src/sunoFixtureReplay.test.ts`；`flutter test test/suno_fixture_replay_test.dart`。


| event | 含义 |
|-------|------|
| `phase.transition` | 阶段 `from` / `to` / `reason` |
| `batch.snapshot` | `pending` / `downloaded` / `rejected` / `preCreate` 计数 |
| `batch.sidebar_detected` | Create 侧栏新 URL（hash + count） |
| `complete.blocked` | `SunoCompletionPolicy` 未放行原因 |
| `complete.allowed` | 最终 complete 条件摘要 |
| `direct_media.not_ready` | CDN 403/404 或生成中，继续等待 |

联调验收（一次 Create 应落两首）：`batch.sidebar_detected` count≥2 → 两次 `direct_media.saved` 或 `download.saved` → `complete.allowed` 且 `versions` 较 baseline +2；不应出现 Create 页 `currentPageLyricsExactMatch=true` 且 `songUrlCount=0` 后立即打开旧 Library 歌。
