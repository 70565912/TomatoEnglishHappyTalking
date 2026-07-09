# 生成视频等待对话框 GPU 占用优化方案

状态：P0 第 2 项（等待图标 5fps 降频，先后落地过 `steps(12)` 旋转和三点跳动两版视觉）已实施并经实测 GPU 占用可接受；P0 第 1 项已对 `AiBlockingOverlay` 移除 `backdrop-filter` 并加深底色（`rgba(15, 23, 42, 0.55)`），`RecordingProgressOverlay` / `.audio-material-progress-overlay` 仍保留 blur；创作中心的听力视频和歌曲视频导出已统一改用 `RecordingProgressOverlay`，与练习中心共享实时进度、取消和完成报告；P1、P2 视后续需要再评估。

## 1. 背景与现象

生成视频（听力视频 / 歌曲视频）期间，App 会显示阻塞式等待对话框。用户观察到此期间 GPU 占用非常严重，且直觉上“一个进度对话框不应该消耗这么多 GPU”。

视频导出本身确实有两块合法的 GPU 工作量：

- `ffmpeg` 硬件编码（NVENC / QSV / AMF），主要占用 GPU 的 **Video Encode** 引擎；
- Flutter 侧离线渲染视频帧（`ui.Image` 栅格化到 BMP），占用部分 3D/Copy 引擎。

问题在于：除此之外，**WebView2（msedgewebview2.exe）的 3D 引擎在整个导出期间也被打满**，这部分完全来自等待对话框的渲染方式，是纯浪费，也是本方案要消除的部分。

## 2. 现状梳理

生成视频相关的等待对话框有两套实现，共享同类 CSS 问题：

| 入口 | 组件 | 关键样式 | 持续动画 / 更新 |
| --- | --- | --- | --- |
| 创作中心「生成组图」、百聆/其它阻塞式歌曲提交等 | `AiBlockingOverlay`（`web_ui/src/App.tsx`） | `.ai-blocking-backdrop`：全屏半透明底色（已移除 `backdrop-filter`） | `.blocking-dots` 三点 5fps 分步跳动；倒计时每 1s `setState` 重渲染 |
| 书籍播放器（练习中心听力/歌曲模式）和创作中心（视频标签导出听力视频、歌曲标签导出歌曲视频） | `RecordingProgressOverlay`（`web_ui/src/App.tsx`） | `.recording-progress-overlay`：全屏 `backdrop-filter: blur(3px)` | `listening.recording.progress` 事件驱动重渲染（编码阶段 ffmpeg `-progress pipe:1` 约 2Hz；渲染阶段每句/每段一次），支持取消与完成报告 |

同一 CSS 规则还覆盖 `.audio-material-progress-overlay`（生成听力材料等待框），同样受益于本方案。

进度事件链路（Flutter → Web）：

- `RecordingExportService.exportVideo / exportSongVideo` 的 `onProgress` 回调在 `web_shell_screen.dart` 中逐条 `_pushEvent('listening.recording.progress', ...)`，Web 侧 `setRecordingProgress(payload)` 直接触发 React 重渲染，无节流。

## 3. GPU 消耗根因分析

按影响从大到小：

1. **全屏 `backdrop-filter: blur` + 模糊层上的无限动画（主因）**。
   `backdrop-filter` 要求合成器先把遮罩下方的全部内容渲染出来，再对整个视口做模糊。只要模糊层之上有任何逐帧变化（`AiBlockingOverlay` 的 spinner 以 60fps 旋转），WebView2 就必须**每一帧重做整窗口模糊重合成**。在 2K/4K 窗口下，这相当于导出期间持续跑一个全屏后处理特效，长达数分钟到十几分钟。
2. **模糊层上的低频更新也被放大**。
   `RecordingProgressOverlay` 没有 spinner，但每次进度事件（约 2Hz）和 `AiBlockingOverlay` 每秒倒计时都会触发模糊层重合成；单次成本同样是“全屏模糊”。
3. **遮罩下方页面继续渲染**。
   对话框只是覆盖，底层书籍播放器/创作中心仍在树上：大尺寸绘本 `display` 图、其它 `picture-spin` / `shimmer` / `wave` 等 infinite 动画（如有正在 loading 的区块）继续消耗合成资源，并成为每帧模糊的输入。
4. **进度条更新走 layout 路径**。
   `ProgressLine` 用内联 `width: N%` 更新，触发 layout + paint；影响小，但可顺手改为 compositor-only。
5. **合法 GPU 工作量（不属于本问题）**：ffmpeg 编码与 Flutter 离线帧渲染。测量时必须与 WebView2 区分，避免误判优化效果。

## 4. 优化方案

### P0（必做，低风险，预期消除绝大部分浪费）

1. **移除等待对话框的 `backdrop-filter`（`AiBlockingOverlay` 已实施）**。
   `.ai-blocking-backdrop` 已删除 `backdrop-filter: blur(...)`，底色改为 `rgba(15, 23, 42, 0.55)`。`.recording-progress-overlay`、`.audio-material-progress-overlay` 仍待同步移除 blur。
2. **等待图标改为三点跳动，并降频到 5fps（已实施）**。
   `AiBlockingOverlay` 不再使用旋转的 `Icon name="refresh"`；改为 `.blocking-dots` 三个圆点，通过 `blocking-dot-bounce`（`1s steps(5, end) infinite`，即 5 步 × 200ms = 1s → **5fps** 分步跳动）配合 `animation-delay`（0.2s / 0.4s）错开三个点，视觉上更像常见的“加载中”样式，也比旋转图标更耐看；`prefers-reduced-motion: reduce` 下停止动画、固定为半透明静止圆点。其它 `.icon-refresh`（歌曲按钮 loading、绘本 placeholder 等）不受影响，仍保持原 `linear` 旋转。

### P1（建议同批实施）

3. **对话框打开时冻结底层页面**。
   阻塞式等待对话框（`AiBlockingOverlay` / `RecordingProgressOverlay`）挂载时给 app 根容器加 `app-frozen` class：
   - `visibility: hidden`（或 `content-visibility: hidden`）隐藏底层内容——遮罩本来就是不透明度较高的阻塞层，底层不需要可见；
   - 兜底规则 `.app-frozen *, .app-frozen *::before, .app-frozen *::after { animation-play-state: paused; }` 暂停底层 infinite 动画。
   卸载时移除 class。注意与既有 `createPortal(document.body)` 结构配合：冻结目标是 app 根节点，不是 portal 容器。
4. **倒计时文本降频渲染**。
   `AiBlockingOverlay` 倒计时保持每秒一次即可（P0 落地后成本已很低）；仅需确认剩余时间为 0 后不再继续 `setState`。

### P2（可选，进一步压低更新频率）

5. **Flutter 侧进度事件节流**。
   在 `web_shell_screen.dart` 推送 `listening.recording.progress` 前合并：间隔 <500ms 且整数百分比未变化时丢弃中间事件（`phase` 变化和 `completed` 必推）。ffmpeg 编码阶段本身约 2Hz，此项主要防御渲染阶段短句密集回调。
6. **进度条改 transform**。
   `ProgressLine` 内条改为 `transform: scaleX(ratio)` + `transform-origin: left`，避免 layout；纯锦上添花。

### 明确不做

- 不改 ffmpeg 编码参数、编码器选择和离线帧渲染链路——那部分 GPU 占用是导出本身的工作量。
- 不为等待对话框引入新的动画库或 Lottie/Rive 资源。
- 不动非阻塞的小卡片（`RecordingResultCard` 等，无持续动画、无全屏模糊）。

## 5. 测量与验收标准

测量方法（优化前后各测一次，同一篇文章、同一分辨率/编码器导出）：

1. 任务管理器 → 性能 → GPU，展开引擎分解；或「详细信息」页给 `msedgewebview2.exe`、`ffmpeg.exe`、`tomato_english_happy_talking.exe` 各加 GPU / GPU 引擎列。
2. 触发听力视频导出，等待对话框停留 ≥60 秒，记录三个进程的 GPU 占用。

验收标准：

- 等待对话框显示期间，`msedgewebview2.exe` 的 GPU 3D 占用接近空闲（目标 <5%，允许秒级进度更新的短脉冲）；
- `ffmpeg.exe` 的 Video Encode 占用不受影响（导出速度不变或更快）；
- 导出总时长不劣化。

## 6. 回归检查项

- `web_ui`：`npm test` 或 `npx vitest run src/App.test.tsx -t "导出|recording|progress"` 相关用例通过；等待/进度对话框仍渲染在 `document.body` portal 且阻挡底层操作。
- 视觉：无模糊后遮罩仍能清晰区分前后层级（Windows / Android 各看一次）；取消按钮可点击；`AiBlockingOverlay` 等待图标为三点 5fps 分步跳动（非平滑），`prefers-reduced-motion` 下静止。
- 冻结底层（P1）后：导出完成/取消能正确恢复底层页面可见性与动画；导出期间收到的其它 native 事件（如 notice）不被冻结逻辑吞掉。
- `AiBlockingOverlay` 其它使用点（绘本组图提交、保存章节、百聆歌曲提交等）同样生效且无副作用。
