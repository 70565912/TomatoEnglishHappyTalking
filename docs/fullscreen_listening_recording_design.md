# 全屏听力播放录制功能方案

## 背景与目标

听力全屏播放已经具备以下前置条件：

- 当前播放模式所需的英文/中文 TTS 已在内存热缓存中。
- 绘本页图片已生成、下载并预解码。
- `listening.playSequence(..., strictPreloaded: true)` 可以保证播放中不再临时合成语音或读盘等待。

录制功能目标是在这个基础上导出一套可复现的学习视频：

- 输出视频支持 `2560x1440` / `1920x1080` / `1280x720` 三档，`25fps`、MP4。
- 视频编码支持 `H.264` / `H.265(HEVC)`，用户在点击“录制视频”后的录制设置框中选择。
- 编码使用 VBR 动态码率、高质量参数；优先硬件编码，软件兜底。
- 音频直接复用已有 MP3 缓存，不做实时录音/重编码。
- 同步生成中英对照 `.srt` 字幕文件。
- 性能不足时允许丢帧；有丢帧时录制结束弹出报告，正常时只提示录制完成。
- 固定保存到程序运行目录下的 `recording-export` 文件夹。

## 推荐架构

推荐不要做传统意义上的“屏幕录制”，而是做“全屏播放内容导出”：

1. Web UI 仍负责用户入口、准备状态展示、进度展示和完成报告。
2. Flutter bridge 新增录制命令，读取当前文章的绘本页、字幕、TTS 缓存和设置。
3. Flutter native service 负责把同一套全屏播放数据按用户选择的分辨率离屏渲染为临时帧/片段。
4. 外部 `ffmpeg.exe` 负责把帧序列编码为 H.264/H.265，并写入 MP4。
5. MP3 缓存按播放顺序生成 concat 列表，由 FFmpeg 以 copy 方式复用到 MP4 音频轨。
6. 根据每句英文/中文开始结束时间写出 SRT；视频画面本身不烧录字幕。

这样做比直接捕获屏幕窗口更稳：

- 不受窗口缩放、系统 DPI、鼠标、遮挡、WebView 合成层和截图接口限制影响。
- 输出永远是用户选择的准确分辨率。
- 图片帧、句子时长和音频时间轴由程序控制，便于复现；字幕交给同名 SRT 文件。
- 可以在不真实播放出声的情况下导出视频，避免录制时外部音频混入。

真实窗口采集可以作为后续高级模式，但不建议作为 v1 主链路。

## FFmpeg v1 路线

本功能 v1 只依赖发布包内置的 FFmpeg，不集成 `F:\RedClawDesktop` 代码。

原因：

- 当前需求可以由 `ffmpeg.exe` 完成：图片序列输入、H.264/H.265 编码、VBR 参数、长 GOP、MP3 音频 copy 复用、MP4 mux。
- Tomato 侧不需要维护 Windows 原生编码器、D3D11 帧输入或 MP4 muxer 代码，调试成本更低。
- 后续如果需要实时窗口采集、GPU 纹理零拷贝或更细的硬件编码诊断，再评估 RedClaw 或独立 media helper。

运行时 FFmpeg 固定解析为程序当前目录下的 `ffmpeg.exe`，不读取设置项、环境变量或系统 `PATH`。Windows 构建脚本从 `VCPKG_ROOT` 或 `E:\SDK\vcpkg\installed\x64-windows\tools\ffmpeg` 打包 `ffmpeg.exe` 和同目录依赖 DLL 到 `release\windows\tomato_english_happy_talking\`；Debug/Release 都应从这个目录启动，不直接运行 `app\build\windows\x64\runner\Debug\` 下的 EXE。

如果程序目录缺少 `ffmpeg.exe` 或依赖 DLL，录制按钮保持禁用并显示明确原因，提示重新发布程序或把 FFmpeg 放到程序目录。

## 功能入口与配置

### 录制设置框

设置页不再展示视频录制设置。用户在听力页点击“录制视频”后弹出录制设置框，确认后立即开始录制：

- 视频编码：`H.264` / `H.265(HEVC)`，默认 `H.264`。
- 导出分辨率：`2560x1440` / `1920x1080` / `1280x720`，默认 `1920x1080`。
- 绘本页转场：默认 `none`，可选 `crossFade`、`panZoomFade`、`slide`，后续可增加 `pageCurl`。
- 保存文件夹：固定为程序运行目录下的 `recording-export`，不提供设置项。
- FFmpeg 路径：固定为程序运行目录下的 `ffmpeg.exe`，不提供设置项。
- 质量档位：默认“高质量”，v1 可先不暴露细档，只内部固定参数。
- 硬件编码：默认自动，内部优先 `NVENC -> QuickSync -> AMF -> software`。

建议 bridge 配置形状：

```ts
interface RecordingSettings {
  codec: 'h264' | 'h265';
  resolution: '2560x1440' | '1920x1080' | '1280x720';
  pageTransition: 'none' | 'crossFade' | 'panZoomFade' | 'slide';
  outputDirectory: string; // read-only, programDir/recording-export
  ffmpegPath: string; // read-only, programDir/ffmpeg.exe
  quality: 'high';
  hardwareBackend: 'auto';
}
```

Native 只保存编码、分辨率、转场三个偏好；输出目录和 FFmpeg 路径每次按程序目录实时计算，不放云端，也不写入文章数据。

### 听力页

全屏播放按钮旁新增“录制视频”按钮，或者在全屏播放层里新增录制入口。

进入录制前必须满足：

- 全屏播放 readiness 已通过。
- 当前模式所需 TTS 全部在内存或磁盘缓存可定位。
- 绘本页全部 ready，且覆盖全部句子。
- 程序目录下的 `recording-export` 可创建并可写。
- 程序目录下的 `ffmpeg.exe` 可用，且目标 H.264/H.265 编码器可用。

如果任一条件不满足，显示明确原因，不开始录制。

## Bridge / Native 接口

建议新增 bridge 命令：

- `recording.settings.load`
- `recording.settings.save`
- `listening.recordingReady`
- `listening.recordVideo`
- `listening.cancelRecording`

建议新增 native event：

- `listening.recording.progress`
- `listening.recording.completed`
- `listening.recording.error`

`listening.recordVideo` payload：

```ts
interface ListeningRecordVideoRequest {
  articleId: number;
  mode: 'english' | 'bilingual';
  codec: 'h264' | 'h265';
  resolution: '2560x1440' | '1920x1080' | '1280x720';
  pageTransition: 'none' | 'crossFade' | 'panZoomFade' | 'slide';
  width: 2560 | 1920 | 1280;
  height: 1440 | 1080 | 720;
  fps: 25;
}
```

完成 payload：

```ts
interface ListeningRecordVideoResult {
  ok: boolean;
  videoPath: string;
  subtitlePath: string;
  durationMs: number;
  frameCount: number;
  droppedFrameCount: number;
  encoderName: string;
  codec: 'h264' | 'h265';
  resolution: '2560x1440' | '1920x1080' | '1280x720';
  pageTransition: 'none' | 'crossFade' | 'panZoomFade' | 'slide';
  warnings: string[];
}
```

UI 行为：

- `droppedFrameCount === 0 && warnings.isEmpty`：toast “录制完成”。
- 有丢帧或 warning：弹出报告，展示丢帧数、编码器、输出路径和建议。
- error：弹出错误，保留“重新录制”按钮。

## 录制流水线

### 1. 数据准备

Native 根据 `articleId` 和 `mode` 收集：

- `ListeningItem[]`：英文句子、中文翻译、句子 index。
- `PictureBookPage[]`：句子范围 -> 图片路径/URI。
- 英文 TTS MP3 缓存路径或 bytes。
- 中英对照模式下的中文 TTS MP3 缓存路径或 bytes。

如果中文翻译为空，则中英对照模式只为有中文的句子生成中文字幕和中文音频片段；没有中文的句子只输出英文。

### 2. 时间轴生成

时间轴不能依赖实时播放事件，必须离线计算：

- 读取每个 MP3 片段时长。
- 英文模式：每句时间段 = 英文 MP3 时长。
- 中英对照模式：每句时间段 = 英文 MP3 时长 + 中文 MP3 时长；中文为空则只用英文时长。
- 每句可加很短静默间隔，建议 v1 默认 `0ms`，保持与连续播放一致。

输出：

- `sentenceStartMs`
- `englishStartMs/endMs`
- `chineseStartMs/endMs`
- `sentenceEndMs`
- `picturePageIndex`
- `transitionWindowStartMs/endMs`

### 3. 音频复用

用户要求“音频直接复用 mp3 文件不必实时录制编码”，因此不要录系统声卡。

推荐 v1：

- 为每个句子的 MP3 缓存生成 FFmpeg concat 列表。
- 先用 FFmpeg concat demuxer 拼接为临时 MP3，避免程序内处理 packet 时间戳。
- 最终 FFmpeg 编码命令读取图片帧序列和临时 MP3，音频轨使用 `-c:a copy` 复用到 MP4；临时文件在成功后删除。

注意：

- MP4 容器可放 MP3 音频，但兼容性弱于 AAC；由于需求明确为复用 MP3，v1 坚持 MP3 轨，不做 AAC 转码。
- 如果目标播放器兼容性出现问题，后续可增加“音频转 AAC”选项，但默认不启用。

### 4. 视频帧渲染

推荐 Flutter `dart:ui` 离屏渲染到用户选择的分辨率，并写出临时图片帧或静态片段：

- 背景绘本图按全屏播放一致的 `object-fit: contain` 规则绘制。
- 不绘制字幕、底部控制条、鼠标、进度 UI；字幕仅写入同名 SRT。
- 每个视频帧根据时间戳选择当前句子和绘本页。
- 画面切到新绘本页时可按设置渲染转场。

v1 路线：

- 使用 Flutter Canvas 绘制图片，不依赖 WebView 截图。
- 有转场时可按帧写出临时图片序列；无转场时优先写每句静态片段，降低写盘量和编码时间。
- 视频帧不包含字幕，字幕样式由播放器加载 SRT 后决定。
- `2560x1440` 的临时图片和编码压力较高，导出允许慢于实时完成。

### 5. 绘本页转场

转场是视频画面的渲染效果，不占用额外视频时间，也不改变音频时间轴。

规则：

- 当当前句子映射的绘本页从 `A` 切到 `B` 时，在切换点附近使用一段固定时长的视觉混合窗口。
- 转场窗口从既有时间轴中“借用”时间，例如默认 `500ms`：
  - 如果切换点前后句子都有足够时长，则 `250ms` 覆盖在上一页末尾，`250ms` 覆盖在下一页开头。
  - 如果前后句子太短，则按可用时长自动缩短，最低可为 `0ms`。
- 音频照常连续播放，字幕时间不额外延后，视频总时长不增加。
- SRT 时间轴仍按句子音频时间生成，不因为转场改变。

转场选项：

- `none`：无转场，切换点直接换图，默认选项。
- `crossFade`：上一页淡出、下一页淡入，最稳定。
- `panZoomFade`：轻微推拉/平移 + 淡入淡出，绘本感更强。
- `slide`：水平滑动切页，清晰但运动更明显。
- `pageCurl`：纸张卷页效果，建议作为 v2；需要更复杂的 GPU shader 或 mesh 变形，不进入 v1。

### 6. 编码与丢帧策略

视频编码参数：

- 分辨率：`2560x1440` / `1920x1080` / `1280x720`
- 帧率：`25fps`
- 码率控制：`VBR`
- 质量：绘本低运动高质量 VBR。
- GOP：默认 5 秒，即 `125` 帧；允许配置为 4-8 秒。绘本画面静态多，长 GOP 可明显降低码率。
- 关键帧：首帧必须是关键帧；无转场直接换页时建议在新页第一帧强制关键帧；有转场时可在转场结束后第一帧强制关键帧，避免长 GOP 下页面大变化恢复慢。
- B 帧：硬件后端可用 2-3；录制导出不是低延迟场景，可允许 B 帧提高压缩效率。
- 低运动目标码率建议：
  - `1280x720` H.264：`2500 kbps` target，`4500 kbps` max。
  - `1280x720` H.265：`1600 kbps` target，`3200 kbps` max。
  - `1920x1080` H.264：`5000 kbps` target，`9000 kbps` max。
  - `1920x1080` H.265：`3200 kbps` target，`6500 kbps` max。
  - `2560x1440` H.264：`9000 kbps` target，`15000 kbps` max。
  - `2560x1440` H.265：`5500 kbps` target，`10000 kbps` max。
- 如果编码器支持质量约束模式，优先使用 VBR + CQ/ICQ 类参数，并以上述 max bitrate 作为上限；否则使用 target/max VBR。

丢帧规则：

- 录制是离线导出时，理论上不需要按墙钟实时跑，可以慢一点但不丢帧，画质最稳。
- 如果产品坚持“实时录制”，则用 25fps 时钟调度，渲染/编码超时时丢弃当前视频帧，但音频时间轴不变。
- 丢帧计数来自编码队列背压、渲染超时和 capture timeout 三类。

建议 v1 采用“尽量实时，但允许慢于实时完成，不主动丢帧”的导出模式；只有用户打开“实时录制优先”时才启用丢帧。这样更符合学习视频导出场景。

## SRT 生成

每句生成一条中英对照字幕：

```text
1
00:00:00,000 --> 00:00:02,840
"Well, it must be removed," said the King very decidedly,
好吧，必须把它除掉，“国王斩钉截铁地说道，
```

规则：

- 时间段使用整句 `sentenceStartMs -> sentenceEndMs`。
- 英文在第一行，中文在第二行。
- 中文为空时只写英文。
- 文本中的换行、HTML 标记、连续空白统一清理。
- 文件名与 MP4 同名：`<series-title> - <article-title> - YYYYMMDD-HHMMSS.srt`。

如果未来要更精细，可拆成英文和中文两个独立 cue，但 v1 保持一条双语 cue，播放器兼容性最好。

## 文件命名与输出

默认输出目录：

```text
<program-dir>\recording-export
```

文件名：

```text
<series-title> - <article-title> - YYYYMMDD-HHMMSS.mp4
<series-title> - <article-title> - YYYYMMDD-HHMMSS.srt
```

需要做 Windows 文件名清理：

- 替换 `<>:"/\|?*`。
- 长度控制在 160 字符以内。
- 同名冲突追加 `-2`、`-3`。

## 失败与报告

录制开始前失败：

- 输出目录不可写。
- 编码器不可用。
- MP3 缓存缺失。
- 绘本页未 ready 或有 error。
- 图片无法解码。

录制中失败：

- FFmpeg 写文件失败。
- 编码器初始化后崩溃/返回错误。
- 临时 MP3 拼接失败。
- 用户取消。

完成报告：

- 正常：只显示“录制完成”，可提供“打开文件夹”按钮。
- 有丢帧/警告：弹出报告，包含：
  - 视频路径
  - 字幕路径
  - 编码器名称
  - codec
  - 总帧数
  - 丢帧数
  - 平均编码耗时
  - 建议：切 H.264、降低并行任务、改用软件/硬件后端等

## 实施阶段

### Phase 1：确定性离线导出 MVP

- 听力页录制入口弹出 codec、分辨率、转场效果设置框。
- 听力页增加“录制视频”入口。
- Native 新增 `RecordingExportService`。
- 实现三档分辨率 Flutter 离屏渲染。
- 调用程序目录下的 `ffmpeg.exe` 选择 H.264/H.265 编码器并输出 MP4。
- 用 FFmpeg concat/copy 复用 MP3 音频轨。
- 生成 SRT。
- 输出完成/错误报告。

验收：

- E28 可导出 MP4 + SRT。
- 三档分辨率均可导出，默认 `1920x1080`，帧率 `25fps`。
- 音频与字幕基本同步。
- 无转场模式不增加视频时间；转场模式不改变音频和字幕时间轴。
- H.264 可播放。
- H.265 在本机可编码时可播放或明确提示不可用。

### Phase 2：FFmpeg 后端与质量完善

- 完善 FFmpeg `-encoders` 检测，优先 NVENC/QSV/AMF/MediaFoundation，软件兜底。
- 高质量 VBR 参数按 encoder 适配。
- 输出编码诊断和 FFmpeg stderr 摘要。
- 对 H.265 可用性做 UI 提示。

验收：

- NVIDIA/Intel/AMD/无硬编环境均有明确后端选择结果。
- 软件兜底可用。
- 有异常时错误可读。

### Phase 3：真实窗口录屏模式（可选）

- 如果确实需要“录屏当前窗口看到的一切”，再另行评估窗口采集实现。
- 捕获对象优先选 Tomato App 窗口或当前显示器区域。
- 仍用 MP3 缓存做音频轨，不录系统声卡。
- 该模式会记录鼠标/控制条等真实画面，因此作为高级选项，不作为默认。

## 测试计划

### Dart / Native

- 录制 readiness：缺图片、缺 TTS、目录不可写、编码器不可用时拒绝开始。
- 时间轴：英文模式、中英对照模式、中文为空句子的 duration 计算。
- SRT：双语、纯英文、特殊字符、长句换行。
- 文件名清理和同名冲突。
- 丢帧报告：模拟渲染/编码超时后报告非零丢帧。
- 编码后端：H.264/H.265 profile 参数和 fallback。

### Web UI

- 录制设置框 codec、分辨率、转场选择与保存。
- 设置页不显示视频录制设置。
- 录制按钮 disabled reason。
- 录制进度、取消、完成、警告报告、失败重试。
- 正常完成只提示录制完成。

### Windows 联调

- E28 英文模式导出 MP4 + SRT。
- E28 中英对照模式导出 MP4 + SRT。
- MediaInfo/ffprobe 检查：
  - `1280x720` / `1920x1080` / `2560x1440`
  - `25fps`
  - H.264/H.265
  - MP3 audio track
  - duration 接近句子音频总和
- 本地播放器打开 MP4，字幕文件手动加载可显示双语。
- 有意压低编码性能或注入延迟，确认丢帧报告出现。

## 关键风险

- MP4 内 MP3 轨的播放器兼容性不如 AAC，但用户要求复用 MP3，v1 按 MP3 实现。
- 程序目录 `ffmpeg.exe` 不存在、依赖 DLL 缺失或编码器不可用时，需要明确提示用户重新发布程序或补齐文件。
- 临时帧/片段会产生磁盘 IO；导出结束必须清理临时目录。
- 如果采用真实窗口采集，WebView、DPI、窗口遮挡、鼠标和控制层都会影响结果，不适合作为默认导出。
- H.265 编码和播放在不同机器上支持差异更大，需要 UI 提示 fallback 或不可用原因。

## 推荐默认决策

- 默认导出方式：确定性离线导出，不录屏幕。
- 默认 codec：H.264。
- 默认分辨率/帧率：`1920x1080` / `25fps`。
- 默认转场：`none`，转场不占用额外视频时间。
- 默认音频：MP3 packet remux，不重编码。
- 默认字幕：同名 SRT，中英对照一条 cue 两行。
- 默认后端：自动硬件优先，软件兜底。
- 默认完成提示：无警告只 toast，有丢帧/警告才弹报告。
