# 修改日志

## 2026-07-10

- 创作中心视频导出体验与练习中心统一：创作中心“视频”标签导出听力视频、歌曲标签按具体歌曲版本导出歌曲视频，两者都复用录制设置框、`listening.recording.progress/completed/error` 事件、`RecordingProgressOverlay` 进度条、取消按钮和 `RecordingResultCard` 完成报告；不再用只显示等待文案的 `AiBlockingOverlay` 反馈视频导出。

验证：

- `npm run build` in `web_ui`
- `npm test` in `web_ui`

## 2026-07-08

- AI 供应商设置从旧 `ai_provider` 拆分为文本处理、图片生成、语音合成、音乐生成四个能力配置：`text_provider` / `image_provider` / `tts_provider` / `song_provider`。旧 `ai_provider` 继续作为文本、图片、TTS 的兼容 fallback；设置页改为四个能力分区。新增 ElevenLabs：TTS 走 `POST /v1/text-to-speech/:voice_id`，声音列表走在线 catalog 并缓存上次成功结果，音乐生成走 `POST /v1/music` 并保存为 `elevenlabs_music` 歌曲版本；`security/elevenlabs.txt` 可在启动时导入 key 到 secure storage。Suno、阿里云百聆、阿里云百炼、火山引擎路径保留。
- 新增 E22 疯茶会原始课程稿回归 fixture，验证当前 `PracticeInputParser` 能从 `英文原文` 区块中跳过中途 `【拓展】` 后恢复正文，并在末尾 `【文化卡片】/生词好句` 前停止，不再把 `17.I meant what I said`、`See? I meant what I said.` 等学习材料例句写入文章句子。同步修复 `NlpService.splitSentences` 与 Web UI `sentenceSplitter.ts`：直接引语前的强制切分只有在引语前叙述已经是舒适朗读块时才生效；如果前段过长，先按逗号/分号等普通断点拆开，避免 E22 `It was so large a house... saying to herself, "Suppose..."` 这类句子形成超长朗读块。
- 绘本章节规划改为精简的“同一连续故事场景归并 + 原文去对话”规则：移除 `picture_book_chapter_scene_plan_v2` prompt 中的 `compact`、`smallest complete scene set`、弱边界合并、叙述微阶段合并和其它泛化防错约束；scene 按原始句子顺序构造，先忽略直接引语、对话语义、歌词、喊话和内心独白内容，再把同一地点/时间、主要人物组和正在发生的事件/活动保持连续的内容归入同一场景，只有场景发生实质变化时才开启新 scene。`chapterDescription` / `sceneDescription` 基于原文保留可见内容，并移除对话、歌词、喊话、内心独白内容和对话语义摘要。E22 新分镜审核发现上一版把同一茶桌场景里的酒、礼貌、个人评价、谜语、反驳和沉默拆成 6 张对话语义 scene，导致达到 12 张上限；后续 10 张版本数量有所下降，但仍用 `exchange`、`conversation`、`riddle`、`remark` 等词把对话语义写回描述。本版明确禁止对话轮次、问答、谜语、争论、评价、反应或情绪变化在同一场景内单独切分，也禁止用 `exchange` / `conversation` / `discuss` / `debate` / `ask` / `answer` / `question` / `reply` / `remark` / `riddle` / `argue` / `claim` / `mean` / `say` / `said` / `offer` 等摘要词替代已移除的对话内容。旧 `story_chapters.summary_json` 不自动迁移，用户刷新章节规划后才使用新规则。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\api_cache_service_test.dart --name "picture-book"`
- `D:\DevTools\flutter\bin\flutter.bat test test\app_config_test.dart test\tts_service_test.dart test\eleven_labs_music_service_test.dart`
- `D:\DevTools\flutter\bin\flutter.bat test test\practice_input_parser_test.dart`
- `npm test` in `web_ui`
- `git diff --check`

## 2026-07-07

- 修复 Windows WebView2 静止页面持续占用 GPU：实测确认创作中心静止约 15%~20% GPU 的根因不是 CSS 或 WebView2 GPU 合成本身，而是 `flutter_inappwebview_windows` 使用 `Windows.Graphics.Capture` 持续把 WebView2 画面复制进 Flutter texture。最终采用插件已有 `setFpsLimit` 做主 WebView 自适应抓帧限速：活动时不限帧，活动结束后降到 `12fps`，静止后降到 `5fps`；不再停止可见窗口 capture，避免空白帧。Suno WebView 不纳入主窗口限速策略。坑位见 `docs/build-and-release-pitfalls.md`。
- 实测确认 `AiBlockingOverlay` GPU 占用降频改动后可接受；旋转图标观感不佳，改为三点跳动样式：`web_ui/src/App.tsx` 的 `.ai-blocking-spinner` 内不再渲染 `Icon name="refresh"`，改为三个 `.blocking-dots span` 圆点；`web_ui/src/styles.css` 新增 `blocking-dot-bounce` 动画（`1s steps(5, end) infinite`，5 步 × 200ms = 1s，仍是 **5fps** 节奏，配合 `animation-delay` 错开三点），移除此前的 `blocking-overlay-spin` 旋转规则；`prefers-reduced-motion: reduce` 下停止动画并固定半透明。仅作用于阻塞遮罩等待图标，不影响歌曲按钮、绘本 placeholder 等其它 `.icon-refresh` loading 图标。详见 `docs/video_export_wait_dialog_gpu_optimization.md`。
- `AiBlockingOverlay` 等待对话框旋转图标降频：`web_ui/src/styles.css` 将 `.ai-blocking-spinner .icon-refresh` 从 `picture-spin 900ms linear` 改为专用 `blocking-overlay-spin 2.4s steps(12, end)`（5fps 分步旋转）；`prefers-reduced-motion: reduce` 下停用动画。仅作用于阻塞遮罩 spinner，不影响歌曲按钮、绘本 placeholder 等其它 loading 图标。详见 `docs/video_export_wait_dialog_gpu_optimization.md`。（同日后续改为三点跳动样式，见上条）
- `AiBlockingOverlay` 移除全屏 `backdrop-filter`：`.ai-blocking-backdrop` 删除 `blur(2px)`，底色改为 `rgba(15, 23, 42, 0.55)`，降低 WebView2 等待期间整窗模糊重合成开销。`RecordingProgressOverlay` / `.audio-material-progress-overlay` 仍保留原 blur，待后续统一评估。
- Web UI 统一 `ConfirmDialog`：`window.confirm` 全部替换为 `createPortal(document.body)` 的应用内确认框；`ConfirmDialog` 支持 Esc 取消、Tab 焦点陷阱、点击遮罩取消、打开时聚焦取消按钮。创作中心「生成百聆 / Suno 歌曲」与 Suno 二次确认均走同一套 `songGenerationConfirmCopy` / `sunoCreateConfirmCopy` 文案。
- 听力页不再保留歌曲生成入口：移除未接线的 `SongDialog` / `openSongDialog` / 「歌曲管理」按钮及仅服务于该弹窗的生成、导入、检测下载逻辑；歌曲生成、导入、字幕与版本管理统一在创作中心完成，听力页仅保留 **歌曲模式** 下的播放、全屏与导出视频。

验证：

- `cd web_ui && npm test -- --run`（145 passed）

- 新增文档 `docs/video_export_wait_dialog_gpu_optimization.md`：分析生成视频等待对话框期间 GPU 占用严重的根因（全屏 `backdrop-filter: blur` 叠加 spinner 无限动画导致 WebView2 每帧整窗口模糊重合成，底层页面未冻结继续渲染），落档分级优化方案（P0 移除等待遮罩 backdrop-filter、spinner 降频；P1 对话框期间冻结底层页面；P2 进度事件节流与进度条 transform 化）及测量验收标准。方案覆盖 `AiBlockingOverlay`、`RecordingProgressOverlay` 和 `.audio-material-progress-overlay`。

## 2026-07-06

- 修正英文原文课程稿正文边界解析：`【文化卡片】` / `生词好句` / `重点词汇` 等学习材料 heading 现在即使处于 `【拓展】` soft interruption 内也会直接结束故事正文；`【拓展】` 后恢复正文不再仅凭引号或撇号开头，而是要求明确故事叙事信号或已有故事诗歌续行规则，避免把原诗、词汇例句误收进文章。
- 新增 Alice 课程稿回归样本：E20 公爵夫人厨房/婴儿段、E29 柴郡猫头争执段使用用户原始输入 fixture 覆盖。E20 不再混入 `’Tis full of anxious care!`、`it would be as well...` 词条例句等非故事英文；E29 在文化卡片前以 `"How fond she is of finding morals in things!" Alice thought to herself.` 正确结束。
- 绘本章节规划 prompt 调整：`picture_book_chapter_scene_plan_v2` 仍把完整原文提交给同一次文本 AI 以保留细节，但要求 `chapterDescription` / `sceneDescription` 排除直接引语、对话内容、歌词/喊话文本和内心独白原句，只保留图片可表达的动作、物体、地点、姿态、场景状态、人物关系和情绪表现；分镜策略继续按 visual story beat，不新增本地对话剔除器或额外 AI 调用。新增 E20 对话密集样本回归，确认 groupPrompt 保留厨房、胡椒、厨具、海星状婴儿等可见细节且不含原文台词。
- Windows 构建脚本默认开启本机 QA 调试接口：`tools/build_windows.ps1` 会自动补入 `TOMATO_QA_REMOTE=true` 与 `TOMATO_QA_PORT=39317`，日常 `-Run` / `-Release -Run` 不再需要输入冗长 `-DartDefine`；需要普通分发包时可用 `-DartDefine TOMATO_QA_REMOTE=false` 显式关闭。

验证：

- `git diff --check`
- `D:\DevTools\flutter\bin\flutter.bat test test\api_cache_service_test.dart --name "picture-book"`
- `D:\DevTools\flutter\bin\flutter.bat test test\practice_input_parser_test.dart`

## 2026-07-05

- **Suno 创建/下载全量重构**：逻辑迁至 `app/lib/features/web_shell/suno/`（`SunoAutomationController`、`SunoCreateBatch`、`SunoCompletionPolicy`、`SunoWebScripts`）。修复 Create 页表单歌词导致 `currentPageLyricsExactMatch` 假阳性、首首落盘后 batch 未跟踪第二首、CDN 403 记 `direct_media.not_ready` 等待、导航期 login 假阳性抑制。统一 `complete.blocked` / `complete.allowed` / `batch.sidebar_detected` 诊断日志。
- 绘本单页重生成参考图：可选列表含当前重生成页已有图片（默认仍预选最近邻页）；UI 标注「当前页」。
- **文章歌曲历史版本**：改原文或软隐藏后，已下载歌曲仍出现在创作中心/听力列表；`lyricsHash` 不再用于过滤列表；删除/更新就地改 `api_cache` 与 metadata，避免磁盘孤儿文件。规则见 `docs/article_song_version_retention.md`。
- 听力字幕**软隐藏**：练习中心编辑字幕时清空英文并保存，将该槽位存为 `""`（index 不变、不顺位删除）。听力列表显示「（已隐藏）」并可恢复；播放/跟读/听力材料生成/视频导出跳过隐藏句；歌曲 metadata 不重算；绘本分镜不因软隐藏失效。规则见 `docs/listening_sentence_hide_rules.md`。
- 修复听力字幕编辑框 z-index（`edit-dialog-backdrop` 100）与编辑时关闭单词卡，避免 WebView 无法输入。
- 修复 Windows WebView2 **输入框偶发失焦**：Web UI 增加 `webViewFocusGuard` 自动 refocus；单词卡 dismiss 改为非 button；编辑弹窗取消 `select()` 全选；Windows 构建 patch `flutter_inappwebview_windows` 延迟 focus。联调 `node tools/qa_input_focus_probe.mjs`；坑位见 `docs/build-and-release-pitfalls.md`。
- 绘本组图/单页/刷新提交改用 App 级 `AiBlockingOverlay`（`pictureBookBlockingOverlay.ts`），组图确认时显示预计超时倒计时（`max(180, 分镜数 × 150)` 秒、上限 2700）；`ai-blocking-backdrop` z-index 115，避免被审核弹窗遮挡。

验证：

- `flutter test test/api_cache_service_test.dart --name "picture-book single-page"`（5 passed，含当前页作参考图）
- `flutter test test/article_song_version_retention_test.dart`（3 passed）
- `flutter test test/listening_sentence_hide_test.dart test/listening_sentence_visibility_test.dart`
- `npx vitest run src/App.test.tsx -t "opens single-page picture prompt review|submits multiple selected reference"`（2 passed）
- `flutter test test/suno_completion_policy_test.dart test/suno_create_batch_test.dart`
- `flutter test test/suno_fixture_replay_test.dart`
- `npx vitest run src/sunoFixtureReplay.test.ts`

## 2026-07-04

- 绘本单页重生成支持用户多选参考图：创作中心「重新生成」进入 `pictureBook.pagePromptReview` 后，在「单张生成 Prompt」下方展示其它已生成页缩略图（不含当前重生成页），默认预选最近邻 1 张，可 toggle 多选（至少 1 张、最多 14 张）；确认时提交 `referencePageIndexes`，Flutter 解析为多张本地 `imagePath` 传给火山/万相 `referenceImagePaths`；`prompt_json` 记录 `referencePageIndexes`。整章组图仍不传参考图。
- 相关文档同步：`docs/ai-call-flow-and-prompt-logic.md`（单页重生成与参考图选择）、`AGENTS.md`（单页参考图规则）。

验证：

- `flutter test test/api_cache_service_test.dart --name "picture-book single-page"`（4 passed）
- `npm --prefix web_ui test -- --run -t "single-page prompt review|submits multiple selected reference"`（2 passed）

- 修复 Suno Create 提交并过真人审核后，Tomato 进入新歌详情页又立刻跳回 Create 填风格的问题。根因一：`_continueSunoAutomation` 里 Create 填表分支（`manualAction`/`failed`）排在 post-create 下载分支之前，且未排除 `_sunoCreateSubmitted`，一旦详情页歌词尚未就绪被误判为 `manualAction`，下一轮就会 `loadUrl(/create)` 并重跑魔法棒/Styles。根因二：post-create 打开候选详情页后，页面 settled 但歌词未 exact match（歌曲仍在 generating）时过早 reject 并 cancel 定时器，触发上述回跳。修复：Create 已提交后不再进入填表分支；打开 sidebar 新候选时 `_trustSunoSongUrls`；详情页 post-create 阶段改为等待生成/歌词匹配；下载入口未就绪时继续 polling 而非 `manualAction`+cancel；completion script 新增 `currentPageGenerating`。
- 修复上述改动联调时发现的歌曲详情页“下载死循环”：`_sunoDownloadScript` 每轮都点播放条 `More menu contents` 反复开/关菜单，永远点不到菜单里的 Download。根因是 2026-07 Suno 改版后（`hxc-btn` 设计系统）More 菜单容器不再带 `role="menu"`/radix popper/floating-ui 标记，打开后的 `Download` 菜单项 `inOpenMenu` 探测不到，且纯 `Download` 标签不满足 `download audio|mp3` 的 direct 规则，菜单查找只能回落到 More 触发器。修复：新增 `isDownloadAdvanceItem`——已核对歌词（或 trusted）的歌曲详情页上，纯 `Download` 标签按钮优先于 More 触发器被点击；点开后的 `MP3 Audio` 等子项走既有 direct 规则。`sunoAutomationSimulator.ts` 同步同一优先级并新增回归用例。
- 相关文档同步：`docs/suno_song_download_rules.md`（Post-create 阶段规则）。

验证：

- `flutter analyze lib/features/web_shell/web_shell_screen.dart`（通过）
- `npm test -- --run sunoAutomationSimulator`（42 passed）
- `.\tools\build_windows.ps1`（Windows Debug 构建通过）
- 真实联调（QA 远程接口 + 真实 Suno 登录态，article 79）：修复前 `download.probe` 每 18 秒 `stage=menu` 点 More 死循环约 35 分钟无产出；修复后自动点中 Download 菜单项，两个版本 mp3（5.3MB / 9.1MB）经 `direct_media.saved` 落盘 `suno-music/`，最终 `status=ready`、`downloadComplete=true`。
- 歌曲详情页下载：优先 CDN 直链 `cdn1.suno.ai/{uuid}.mp3`；点 MP3 后 45 秒内不再重复点菜单；More 按钮改用原生 click 减少右键菜单。
- 撤销错误的「检测下载早退」：`missingSongUrls` 为空时不得跳过 Suno；每次点击检测下载必须进 WebView。产品意图与实现锚点写入 `docs/suno_song_download_rules.md`「检测下载」、`AGENTS.md`、`_startExistingSunoDownload` 文档注释。
- 修复检测下载跳过 Library 顶部新歌：Library 召回不再要求 `expectedScore>0`/`sameTitle`（检测下载 `_sunoExistingDownloadOnly` 时按 DOM 自上而下广召回），避免只打开标题更像旧版的「Alice's Croquet Game」而跳过新歌「The Croquet Game」。新增 `library.candidate_open` 诊断日志（`broadRecall` / `candidateCount` / `candidateUrl`）。
- 修复 Create 提交后只下载一首就 `complete` 关闭 Suno：post-create downloading 阶段与检测下载共用 `_sunoUseLibraryBroadRecall`（Library 广召回 + 回到 Library 继续扫描），移除「已下载一首且下一候选歌词不匹配就停止扫描」的早退 `complete`。
- 审核补修：Library 懒加载未 settle 时不提前 `complete`；已在 Library 且广召回仍有候选时不走 `completedUrls` 空分支早退；Create 页 sidebar 仍有未下载候选时优先打开下一首详情页；检测到新 post-create URL 时重置 `_sunoExistingDownloadLibraryTried`。
- 修复 `build_windows.ps1` / `build_android.ps1` 的 `-DartDefine` 逗号拆分：单个参数 `TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317` 现在会正确展开为多个 `--dart-define`，与脚本头部注释和 `docs/qa-remote-control.md` 示例一致。

验证（检测下载广召回 + QA 参数）：

- `.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317"`（Release 构建通过，QA `/health` 一次可用）
- QA `listening.songDownloadSunoExisting` article 81：`library.candidate_open` 带 `broadRecall=true`；打开 `32e775b4-708c-44e8-950d-94f634fe4da6` 详情页 `currentPageLyricsExactMatch=true`；`direct_media.saved` 6.4MB mp3 落盘为 v2；扫描结束后 `manualAction` 但本地版本 1→2。

## 2026-07-03

- 修复歌曲全屏播放「每一句都停顿并闪显歌曲文件名」：根因是 `FullscreenSongPlayer` 的播放 effect 依赖 `startLineIndex`，而父层监听 `listening.song.position` 会在每个 cue 执行 `setCurrentIndex(cue.lineIndex)`，并把 `currentIndex` 直接透传成 `startLineIndex`。于是每换一行 effect 都重建：先 `setCurrentCue(null)`（字幕回退成 `version.title` 文件名），再重发 `listening.songPlay` 触发原生 `_playSongFile` 重新 `setFilePath`+`seek`（听感上的卡顿）。改为在打开全屏时用新增的 `songFullscreenStartIndex` 冻结起始行，播放中不再变化，effect 不再中途重启；行内字幕列表仍用实时 `currentIndex`。
- 修复「播放歌曲后切回听力，点击播放提示『听力任务尚未打开』」：根因是 `_handleAppNavigate` 只把 `/listen` 前缀视作听力上下文，而书籍播放器路由是 `/books/<id>/player?...&mode=listening`，切换听力/歌曲子模式只改 `mode` query、不会重跑 Web UI 的 `listening.open`（其 effect 仅依赖 `[articleId, onPictureBookLoaded]`）。旧逻辑因此在模式切换时把 `_activeListeningArticleId` 清空，导致 `listening.playSequence` 报错。新增 `_pathIsListeningContext`（匹配 `/listen` 或 `/books/<id>/player`），只有真正离开播放器时才停止播放并清空监听任务；切到别的文章播放器仍会因 `articleId` 变化重跑 `listening.open` 覆盖 id。

验证：

- `npx tsc --noEmit -p tsconfig.json`（web_ui，通过）
- `.\tools\build_windows.ps1`（web UI tsc+vite 与 Windows Debug 构建通过，产物已同步发布目录）
- 启动冒烟：运行发布目录 EXE，`logs/*.ndjson` 无 error/fatal，startup 序列正常

## 2026-07-02

- 重构歌曲字幕对齐内核：`SongSubtitleTimelineService` 的行级匹配从“贪心逐行游标 + 多层补丁（rescue/refine/低信息词跳过/括注回退）”改为**单次全局单调 DP（Needleman–Wunsch）**。把全部歌词 token 拍平与 ASR 词流做一次全局最优对齐（歌词 token gap 与 ASR 词 gap 分别计费），再按覆盖率/相似度折回每行判定 `matched`/`partial`/boundary。全局最优保证匹配单调不重叠，从根上消除重复短语（如 "said the Caterpillar"）导致的“弱锚级联”——旧算法下 E16 第 16 行拉长到约 94 秒、第 27–51 行塌缩到末尾约 11 秒，字幕完全错位。
- 删除 `alignmentVersion` 版本位与“版本过旧”闸门（`isCurrentTimeline` / `readCurrentTimeline` / `staleTimelineMessage` 语义调整）：timeline 是否可用只看文件是否存在且含 cue；缓存 key 不再含 `alignmentVersion`。算法升级不再自动作废旧缓存，需要时删除对应 `song-subtitle-timelines/*.json`（`getEntry` 会自动清理缺失文件的 DB 记录）或在 App 内重新生成。
- 新增 E16（`Alice Meets The Caterpillar`）真实 ASR 回归 fixture 与用例：断言无单行 cue 吞掉大段、cue 单调不重叠、关键行锚点落在真值时间、Father William 长诗段不塌缩。E16 重构后 54 行全部 `matched`、整体置信度 0.98。
- 相关文档同步：`docs/suno_song_subtitle_timeline_design.md`（对齐算法、生成流程、缓存 key）。

验证：

- `flutter test test/song_subtitle_timeline_service_test.dart`（27 passed，含 E03/E07/E13/E16）
- `.\tools\build_windows.ps1 -Release`

- 修复绘本图 WebView2 花屏（彩色小方块噪点）：新增 `display`（`1280x720`）图片变体，介于列表 `thumbnail`（`640x360`）与原始 `full`（`2560x1440`）之间，本地对已下载原图缩放缓存（`picture_book_display`），不重新调用生成 API。根因是 Windows WebView2/ANGLE 在部分 GPU 上把 2560x1440 大纹理降采样进窗口内展示区域时出现纹理合成损坏，与此前排查过的 `backdrop-filter` 无关。
- 第一次修复只把内嵌场景图（`PictureBookScene`）换成 `display`，用户实测创作中心大图预览/全屏播放仍花屏；随后把 WebView 全部展示路径统一为 `display`：内嵌场景视图、`usePredecodePictureBookImages` 预解码、`FullscreenListeningPlayer` / `FullscreenSongPlayer`（当前页+下一页显式 ensure）、创作中心大图预览（`openPicturePreview`）。`full` 原图不再交给 WebView `<img>`，只保留在磁盘供视频导出等原生链路使用。
- `pageHasPictureBookImageVariant` / `mergePictureBookPageImage` 改为按 `thumbnail < display < full` 分辨率等级比较，避免低分辨率请求覆盖已加载的高分辨率图片。详见 `docs/build-and-release-pitfalls.md`。

验证：

- `npx tsc --noEmit`（web_ui）
- `npm --prefix web_ui test -- --run`（127 passed）
- `flutter analyze lib/services/picture_book_service.dart`
- `.\tools\build_windows.ps1 -Release`
- Release + `TOMATO_QA_REMOTE=true`：`Alice Meets The Caterpillar`（此前花屏页面）听力页与创作中心「查看第 1 页大图」预览，`/screenshot` 均清晰无噪点；`/snapshot` 确认预览大图 `naturalWidth/naturalHeight` 为 `1280x720`（blob URL）、缩略图为 `640x360`，`brokenImages=0`

## 2026-07-01

- 朗读块分句（`NlpService` / `sentenceSplitter.ts`）补充设计说明：输出 read-aloud chunks 而非语言学真分句；舒适上限约 20 词、硬上限 32 词；规则保持通用，回归样本不驱动特例。
- 通用启发式优化：叙事破折号后的小写长从句不再被 merge 回卷；引号内 `!`/`?` 后短尾（≤5 词）并入同一句；逗号切分避开短介词尾句；舒适词数以上继续寻找断点。
- `nlp_service_test.dart` 为 E12 增加 `seen—`、大厅+玻璃桌同块、`Quick, now!` 并入、≤3 词碎片等断言。
- 创作中心绘本组图缩略图支持点击预览原图：列表仍只加载 `thumbnail`，点击后按需请求 `pictureBook.pageImage` `variant: full`（继续走 data URI，WebView 无法直接加载缓存目录 `file://` 原图；坑位记录见 `docs/build-and-release-pitfalls.md`）；预览通过 `createPortal` 固定在视口中央，遮罩与图片分层且不使用 `backdrop-filter`（避免 Windows WebView2 大图花屏）；`<img onLoad>` 后再显示，仅点击大图关闭。
- 创作中心「覆盖听力材料」确认框改为 `createPortal` 挂到 `document.body`，避免页面滚动后弹窗出现在可视区域外。

验证：

- `flutter test test/nlp_service_test.dart`
- `npm --prefix web_ui test -- --run`
- `npm --prefix web_ui test -- --run -t "full-size preview"`
- `npm --prefix web_ui test -- --run -t "confirms before overwriting"`
- `.\tools\build_windows.ps1 -Release`
- Release + `TOMATO_QA_REMOTE=true`：`pictureBook.pageImage` full 返回 `data:image/`，E10 听力与创作中心预览 `brokenImages=0`

## 2026-06-30

- 修复旧章节听力材料读取和播放卡住：`articles.sentences` 继续作为已保存文章的生成素材边界，按持久化句子文本复用历史 `listening_tts` / `follow_tts` 本地音频，不做重新分句兼容。
- `listening.audioStatus`、`listening.playSequence`、`listening.fullscreenReady` 和 `listening.recordingReady` 改为按文章一次性建立本地音频句柄索引，避免每句重复扫描缓存表导致页面长期显示“读取中”。
- 优化 `ApiCacheService.getEntriesForArticlePurpose`，直接使用已查询出的 `api_cache_entries` 行构造缓存对象，保留文件存在性检查和 legacy 路径迁移，避免列表查询后逐条再次查库。
- 发布目录数据修复：从当前库持久化的逐句翻译表恢复被写短的旧文章 `articles.sentences`；用 `Alice's Adventures in Wonderland.zip` 导出包补齐 `E01 - All In The Golden Afternoon` 的 22 句英文和中英对照，旧 E01/E02 导出包素材确认可作为保险备份。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\api_cache_service_test.dart --reporter expanded -j 1`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- Windows release QA：E07 `listening.audioStatus` 183ms 返回 `53/53 ready`，`listening.recordingReady` 约 2.5s 返回 ready，`listening.playSequence` 第 1 句约 4.1s 返回 success。

## 2026-06-28

- Dart `NlpService` 与 Web UI `sentenceSplitter` 统一朗读分句策略：按段落归一化正文，保留段落边界；最长朗读块上限放宽到 32 词，减少过碎停顿；新增连接词、直接引语、短逗号片段和悬空短语的合并/切分规则。
- 分句逻辑增强缩写和单字母句点保护，避免在 `W. RABBIT`、称谓缩写或引号闭合处切出一词碎片；新增 E10 / E11 / E12 Alice 真实章节回归样本，覆盖标题过滤、直接引语、破折号和低质量碎片检查。
- 标准中英对照导入译文回填改为收集同一句的多个候选中文段并去重合并；已有译文不足以覆盖新候选时才更新，避免跨段分句后漏译或把旧引号片段误并入当前句。
- 刷新 Web UI 打包产物，`app/assets/web/index.html` 指向新的 hash 资源。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\nlp_service_test.dart test\practice_input_parser_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `npm --prefix web_ui run build`
- `D:\PowerShell\7\pwsh.exe -Command ".\tools\build_windows.ps1 -Release"`
- `D:\PowerShell\7\pwsh.exe -Command ".\tools\build_android.ps1"`

## 2026-06-27

- 创作中心绘本面板新增“生成听力”按钮，位于“生成组图”后同一行；面板显示章节听力材料生成状态，缺失时可显式提交远程语音合成，完整时需确认覆盖后才重新生成。
- 新增 `listening.audioStatus` / `listening.audioGenerate` bridge 命令和 `listening.audioMaterial.progress` 事件；章节英文 TTS 统一作为 `listening_tts` 听力材料管理，`overwrite=false` 只补缺失，`overwrite=true` 清理当前文章 `listening_tts` 和旧 `follow_tts` 引用后全量重建。
- 听力打开、跟读打开、听力播放、全屏播放、视频导出 readiness 和跟读原音播放改为只检查本地听力材料缓存；缺失时明确提示“需要先在创作中心生成听力材料”，不再后台静默提交 TTS。
- 绘本提示词审核框重新打开时只读取本地持久化章节描述/章节计划；新建文章或缺失描述的已有文章显示空章节描述，用户可手动填写或点击“自动生成章节规划”显式触发文本 AI 刷新，不再本地伪造章节描述，也不在打开弹窗时隐藏提交 AI。
- 记录并测试无章节计划时审核框占位分镜行数规则：多段正文按段落生成并最多 12 行；单段正文按句子数生成，超过 12 句时均分为 12 行；占位行只提供原文范围，`sceneDescription` 保持为空。
- 绘本章节分镜规划 prompt 改为按“紧凑但完整的必要插画”和明确视觉边界理由拆分，不再给普通章节设置数字目标；12 只作为极端上限，只有存在对应数量的真实视觉 story beats 才使用。提示词继续强化通用的边界审核与 scene cohesion audit：同时避免过度合并和过度拆分；相邻内容如果能用同一前景/背景构图表达就合并，同一直接视觉结果下的叙述微阶段不拆成多个 scene；最终审核顺序改为先拆内部混场，再合并弱边界。
- 记录本轮绘本分镜 prompt 调优原则：`E10 - The Caucus Race` 只作为人工评审样例，不把故事特例词写入通用 prompt；后续调优继续围绕可迁移的视觉构图边界，而不是长度、固定数量或单篇故事事件。
- 歌曲字幕匹配补强低信息词处理，避免 ASR 跳过弱词时抢占后续歌词锚点造成字幕过长或过短；新增 E07 真实 ASR fixture 和回归用例，作为后续歌词匹配算法改动的固定素材。
- 发布目录运行数据恢复：确认 `release/windows/tomato_english_happy_talking` 空库后，从最近有书的 runtime backup 恢复 `.dart_tool` 数据库和 `tomato_api_cache`，真实 release App 默认数据根读取到 20 篇文章、3 本书和 20 个章节。
- Windows 发布脚本改为覆盖复制 EXE、DLL、Flutter assets 和 FFmpeg 等程序文件，不再清空整个发布目录或搬移运行数据；`.dart_tool` 数据库、缓存、导出文件和歌曲资产保持原位，降低构建时误删本机测试数据的风险。
- 章节列表正序/倒序改为 Web UI 全局偏好，使用 `localStorage` key `tomato.chapterOrder.v1` 记忆；书库首页、书籍详情、练习中心、创作中心和书籍播放器章节抽屉共享同一排序，非法值回退正序。
- 新增英文原文区本地提取规则文档和 Alice 课程稿回归样本：E01 卷首诗、E11 The Mouse's Sad Tale、E27 槌球场、E28 柴郡猫原始输入均固定为 parser 测试；解析器通用处理拓展说明、文化卡片、生词好句、音标和例句边界，不按单篇文章名特判。
- 修正标准中英对照和英文原文区解析：正文开始后遇到词汇/练习/翻译等学习材料 hard stop；`【拓展】`、背景、难句解析等 soft interruption 会跳过讲解，只在后续出现可信散文或诗歌正文时恢复，避免学习材料污染文章正文、导入译文和绘本分镜输入。
- 修正新建书籍章节的初始摘要：`ensureChapterForArticle` / `attachArticleToSeries` 不再把正文开头截断写入旧 `summary` 字段；`clearArticlePictureBookCache` 也不再重写旧 `summary`，避免正文片段再次污染章节描述。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\practice_input_parser_test.dart --reporter expanded -j 1`
- `D:\DevTools\flutter\bin\flutter.bat test test\api_cache_service_test.dart --reporter expanded -j 1`
- `D:\DevTools\flutter\bin\flutter.bat test test\tts_memory_cache_service_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test -- App.test.tsx --testTimeout=20000`
- `npm --prefix web_ui run build`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `D:\PowerShell\7\pwsh.exe -Command ".\tools\build_windows.ps1 -Release"`
- 真实 release QA 联调：ready 样本 `articleId=46` 听力材料 `46/46 ready`，prepare/fullscreen/recording/play/follow 均通过；missing 样本 `articleId=52` 为 `0/53 missing`，prepare/fullscreen/play/recording/follow 均明确提示需要先在创作中心生成听力材料；联调前后 `api_cache_entries` 和 `api_cache_article_refs` 计数不变，确认未触发隐式远程 TTS。
- 默认 release 数据根验证：`article.list` 返回 20 篇文章，包含 `E10 - The Caucus Race`、`E07 - Am I Still Alice` 和 `E03 - Alice's Long Fall`。

## 2026-06-26

- 重写公开仓库首页 `README.md`：从内部开发状态长文档调整为面向 GitHub 访客的项目介绍，突出应用用途、平台、架构、云服务配置、快速开始、构建脚本和发布数据安全边界。
- README 保留作者信息和项目由来，但改为更适合公开首页阅读的简短表达；同时保留 Apache License、API Key 不入库、本地运行数据不应公开打包等关键信息。

## 2026-06-25

- 录制导出目录按类型分类：无内置字幕视频和 SRT 写入 `recording-export/srt/`，内置字幕视频写入 `recording-export/subtitled/`，歌曲音频导出写入 `recording-export/mp3/`；录制前按当前字幕模式检查对应子目录可写。
- 视频库扫描同时覆盖旧根目录文件和新的 `srt/`、`subtitled/` 子目录；`mp3/` 只作为音频导出目录，不参与视频库扫描。
- Web UI 与 mock payload 同步展示分类导出路径，歌曲音频导出提示改为 `recording-export/mp3`。
- Suno Create / 下载自动化加强候选判断：保存本次 Create 后继续回 Library 扫描后续候选，遇到不匹配详情页时按是否已有新版本决定停止或继续，避免把旧歌或错歌保存到当前文章；Styles 魔法棒定位排除 `View saved style prompts`。
- 发布文档补充 Windows 干净 zip 打包规则：对外包不能直接压缩本机发布运行目录，必须排除日志、诊断、缓存、数据库、导出媒体、`security/`、旧 key/settings 等运行数据。
- 发布文档补充 Android Release 外层 15 分钟超时排查：本次实测 Gradle 在 APK 生成后成功返回，但外层命令超时中断发布目录复制；后续自动化应预留 25-30 分钟。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\tts_memory_cache_service_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `npm --prefix web_ui run build`
- `.\tools\build_windows.ps1 -Release`
- `.\tools\build_android.ps1` 生成 `app-release.apk` 和 `mapping.txt`；外层超时后已按脚本目标同步到 `release/android/` 并执行 APK 签名和内容审计。
- Windows 干净 zip 审计：包内无 runtime/cache/log/security/db/key/settings 路径，文本类文件未发现常见密钥形态。

## 2026-06-22

- 歌曲和听力视频导出支持区分 `srt` / `subtitled` 产物；选择“两版视频 + SRT”时会同时输出无内置字幕视频、同名 SRT 和内置字幕视频，并在完成报告中分开展示。
- 导出文件名增加 `listening` / `song` / `srt` / `subtitled` / `song-audio` 标记，保留旧版导出文件扫描兼容；同一批 `both` 产物共享冲突后缀，便于成对识别。
- 歌曲版本增加“导出音频文件”入口，可把当前本地歌曲音频复制到程序目录 `recording-export/`，不依赖歌曲字幕时间线。
- 歌曲字幕时间线升级到 `alignmentVersion=10`，补强局部 ASR 匹配、首尾/中间推断行的可读时长分配，并新增 E03 真实 ASR fixture 回归。
- 新增歌曲 ASR 诊断快照流程：真实 ASR 词级结果写入程序目录 `diagnostics/`，可从快照重建 timeline 复现对齐问题；Windows 发布脚本保留 `diagnostics/` 运行数据目录。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\song_subtitle_timeline_service_test.dart test\tts_memory_cache_service_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `npm --prefix web_ui run build`
- `git diff --check`

## 2026-06-16

- 云平台选择升级为平台级分流：选择阿里云百炼时，文本、绘本图片、TTS、ASR 走 DashScope/百炼能力；选择火山引擎时，文本、绘本图片、TTS、ASR 走火山方舟/火山语音能力，不在失败时自动回退到另一平台。
- 绘本组图支持阿里云万相异步连续组图和火山 Seedream 顺序组图，v4 分镜上限调整为 12；组图少图或失败会保存明确错误，重试仍回到审核确认流程。
- 阿里云语音接入 CosyVoice 与 Qwen-ASR，默认 `cosyvoice-v3-flash` / `loongabby_v3` / `qwen3-asr-flash`；无词级时间戳时歌曲字幕按歌词和音频时长插值。
- 歌曲生成保留独立来源选择：Suno 网页自动化或阿里云百聆（Fun-Music）；百聆复用百炼 Key，不复制一套 Key 输入框。
- 设置页重新分区：凭据、平台地址、模型与语音、歌曲生成配置分开显示；Key 清除按钮并入对应输入行，移除单独占位的“Key 操作”字段。
- TTS 声音角色按平台隔离：阿里云使用 CosyVoice voice，火山使用 Doubao speaker；切换云平台时设置页只展示当前平台可用声音。
- 练习中心章节行恢复“听力”按钮，点击进入书籍播放器 `mode=listening`；章节列表标题支持折叠/展开，折叠后隐藏章节行并显示“章节列表已折叠”。
- Windows 发布脚本兼容没有 `.NET Path.GetRelativePath` 的 PowerShell 环境，发布阶段使用 URI 相对路径计算，保证真实 Windows App 构建/运行验证可以完成。
- 已刷新 Web UI 打包产物，旧 hash 资源替换为新的 `app/assets/web/` 资源。
- E01 已保存提示词检查结论：章节连续性基本满足，但配角外观锚点不足；当前绘本 v4 提示词已收敛为 bookDescription/chapterDescription/scenes[].sceneDescription，角色外观锚点只放在书籍简介或章节描述中。
- 设置页模型字段改为候选下拉：阿里云百炼文本模型提供 Max/Plus/Flash 档位，火山方舟文本模型提供高效果/低成本档位；万相和 Seedream 图片候选只保留当前组图链路可用模型，不暴露不能完成连续组图的图片模型。
- 空书删除改为只按真实存在的文章章节判断；如果书籍只剩孤儿 `story_chapters` 关系，会先清理这些关系再删除书籍。
- 听力播放器顶部进度条缩短并改用更明显的蓝色进度，与章节导航按钮分组隔开，减少挤在一起的视觉问题。
- `change_list.md` 已按用户计划标记本轮 4 项完成状态；本文件继续作为项目修改日志单独维护。
- 绘本角色描述支持经典名著公开角色补全和章节角色累积：可识别经典会让 AI 基于公开常识列主要递归角色；未知书籍不编造全书角色；本章新增角色先进入审核草稿，保存/确认后合并进书籍描述供后续章节复用。
- 最终组图 prompt 去掉长度控制：按审核后的书籍简介、章节描述和每张图分镜描述完整提交，不再压缩或截断单图描述。

## 验证

- `npm --prefix web_ui test`
- `npm --prefix web_ui run build`
- `.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true","TOMATO_QA_PORT=39317"`
- Windows QA 连续实测：`#/practice?seriesId=2` 展开状态有“听力”按钮；折叠后显示“章节列表已折叠”且章节行隐藏；点击第一章“听力”进入 `#/books/2/player?articleId=42&mode=listening`，`activeListeningArticleId=42`。
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- 本轮后续提交按用户确认未重复运行测试，仅刷新必要构建产物并做提交前静态核对。
