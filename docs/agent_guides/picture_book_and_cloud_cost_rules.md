# 绘本与云 API 成本专项规则

> 处理绘本规划、组图、图片缓存、审核或付费 API 调用时必读。

## API 成本、缓存与内容解析优先级

火山语音（TTS / Realtime / 当前所选 ASR 模型）、图片生成等云 API 都会产生费用。新增或修改任何会触发云调用的功能时，必须优先考虑“本地解析、本地缓存、复用已有结果”，不要把 AI 请求作为第一选择。不要把火山 ASR 笼统写成 BigASR（BigASR 只是可选旧模型）。

总体原则：

- 所有云 API 调用必须先查本地持久缓存或已有业务数据；只有缓存未命中且本地无法确定结果时，才请求远程。
- 只缓存成功的真实远程结果；不要缓存 API Key、请求 Header、失败响应、异常文本或 mock fallback。
- 同一输入、同一模型/声音/资源 ID/尺寸/提示词版本应生成稳定缓存 key，避免同内容重复计费。
- 删除文章时只清理文章独占缓存和引用；全局声音预览、共享 TTS、已确认的组图缓存等不要误删。
- 新增测试时要覆盖二次调用命中缓存、不重复远程请求、删除文章不误删共享缓存。
- “省 API”约束主要针对正式运行流程和重复调用：正式功能必须最大化复用本地解析、数据库、文件缓存和成功远程结果。
- 开发验证不能为了省一次测试调用而跳过关键链路；涉及新增文章、方舟提取/翻译、标题、绘本生成、TTS/听力、跟读录音/识别等端到端改动时，必须做足够完整的回归测试。绘本验证要跑全量文章流程，不能只测第一页或只测 prompt 预览。
- 绘本生成策略为“每篇文章/每章一组连续分镜图”：用户确认 `picture_book_chapter_scene_plan_v2` 的 `scenes[]` 后，按 scene 创建多条 `picture_book_pages`；第 1 张对应第 1 个 scene，第 N 张对应第 N 个 scene，不做候选图筛选。
- 正常 scene 数：**AI 文本规划与 AI 组图**最多 12 段（对齐万相连续组图上限）；`confirmPromptReview` / 整章组图在超过 12 景时必须明确拒绝，不得静默截断。`pictureBook.replaceChapterPlan` 与本地 `importPageImage` **可以超过 12 景**；`replaceChapterPlan` 会按分镜同步 `picture_book_pages` 骨架（保留同 pageIndex 已有 ready 图），便于 QA 逐页导入。`picture_book_pages` 必须覆盖完整句子范围；AI 规划阶段对超长章节合并相邻场景，不拆成多组图片请求。
- 章节组图 prompt 只使用 `bookDescription` / `chapterDescription` / `scenes[].sceneDescription`，适配任意书籍；不要把 Alice、Wonderland 或其它单本书的角色/场景/时代风格固化到通用模板。当前章节内容优先于旧章节历史，避免把上一章角色或场景误带入本章。角色外观锚点优先只放在书籍简介；章节中新出现且书籍简介没有覆盖的视觉角色，可在章节描述里简短补充，不要在每个分镜里重复角色外貌。
- 章节规划 AI 使用完整原文作为可见细节来源；`chapterDescription` / `scenes[].sceneDescription` 必须把直接引语、对话内容、歌词/喊话文本和内心独白转成第三人称可见画面叙事，保留其中的情节与场景信息，但不得出现引号台词、气泡文案、谜面/歌词原文，或可被生图画进图里的对话文本；优先写动作、姿态、物件与空间关系，少用 ask/explain/tell/reply/say 串场。不要新增本地对话剔除器，也不要为转写对话额外增加一次文本 AI 调用；通过 `picture_book_chapter_scene_plan_v2` 的同一次规划 prompt 约束完成。分镜按通用「插画情况」三轴切分（地点/时间、主视觉焦点人物组、中心进行中活动=焦点人物的主任务及目标，而非每个可见节拍），不因 dialogue turns / 反应 / 情绪 / 同类型重复微动作 / 同一事故的直接结果与收拾余波拆分；连续事实、例子、列表项或一般陈述若属于同一主题与时间/地点框架，应作为同一主题块用一张 montage 表达，不得一事实一景，但该局部规则不能覆盖顺序移动、物件操作、发现、事故或其它因果动作；每个 `sceneDescription` 只能使用自身句子区间内的事件并保持人物动作归属，返回前逐对审核相邻边界；不要把茶桌、厨房、法庭等场景名写成合并特例。新生成的 AI 计划若超过 12 景、索引不连续、区间不连续或未完整覆盖句子槽，必须报错重试，不得静默截断后把余量塞进最后一景；旧持久化计划仍按既有兼容读取规则处理。调优过程与结论见 `docs/picture_book_chapter_plan_scene_split_tuning.md`。
- Web UI 中“书籍”就是 `story_series`；书籍模型只保留 `title` / `description` / `cover_image_path`。新增章节在 `article.create`（绘本开启）时会先生成并写入首次 `picture_book_chapter_scene_plan_v2` 到 `summary_json`，保存返回后必须打开 `pictureBook.promptReview` 审核弹窗；用户确认 `pictureBook.confirmPromptReview` 后才提交顺序组图；`pictureBook.generate` / `retryPage` 只能作为打开审核流程的兼容入口，不得绕过审核直接消耗图片 API。
- 取消“图片中不能出现文字”的旧限制。自然文字可以出现，例如书名、标牌、扑克牌数字/花色、地图标注、标签、手写便条或装饰字样；但不要让文字成为理解画面的唯一方式，因为 App 会另行显示字幕。
- 绘本图片 prompt 使用 `picture_book_group_prompt_scene_description_v2` / `picture_book_chapter_scene_plan_v2`：最终提交图片模型的 `groupPrompt` 只拼接书籍描述、章节描述和每张图的分镜描述。不要重新引入 series Bible、角色卡、参考图、`styleGuide`、`audience`、`safety`、`negativePrompt`、字幕留白字段或旧分镜标题/视觉方向字段。
- `pictureBook.pageImage` 支持 `variant: "full" | "display" | "thumbnail"`；创作中心和书籍封面应优先请求 `thumbnail`（`640x360`，`picture_book_thumbnails`），不要在列表页一次性把整章原图作为 data URI 加载。WebView 内所有大图展示（听力/跟读/对话内嵌场景图、全屏播放、创作中心大图预览）一律请求 `display`（`1280x720`，`picture_book_display`，本地缩放缓存已下载原图，不重新调用生成 API），这也是产品定义的用户侧体验分辨率；`full`（`2560x1440` 远程原图）**永远不要**交给 WebView `<img>` 渲染——WebView2 部分 Windows GPU 驱动在把大纹理降采样进窗口尺寸时会出现彩色小方块花屏（坑位见 `docs/build-and-release-pitfalls.md`），原图只保留在磁盘供视频导出等原生链路使用。图片一律通过 bridge 返回 data URI（不要把缓存目录 `file://` 路径直接交给 WebView `<img>`）。创作中心绘本组图缩略图可点击预览大图：预览层通过 portal 固定在视口中央，遮罩阻挡其它操作，仅点击大图关闭；预览层不要用 `backdrop-filter` 叠在大图上，可先把 data URI 转成 Blob URL 再显示；预览请求 display 时不要覆盖列表中的 thumbnail URI（变体按 `thumbnail < display < full` 分级，低分辨率不覆盖高分辨率）。
- 创作中心「生成听力」在材料已完整时会弹出覆盖确认框；该对话框与其它阻塞弹窗一样应 `createPortal` 到 `document.body`，避免在长页面滚动后出现在可视区域外。
- `pictureBook.promptReview` 只读取本地已持久化的章节场景规划（含 `article.create` 首次写入的计划），不调用图片 API、不删除旧 `picture_book_pages` 或图片缓存；刷新按钮只可重建书籍简介，或同次重建章节描述和 `scenes[]`。`pictureBook.savePromptReview` 只保存审核草稿和书籍简介，仍不调用图片 API、不删除旧图。`pictureBook.confirmPromptReview` 才保存审核后的章节场景计划，确认后删除旧页/旧缓存引用并提交顺序组图。不要恢复 `TOMATO_PICTURE_BOOK_AI_PAGE_PROMPTS`、`TOMATO_PICTURE_BOOK_AI_SERIES_BIBLE` 或 `TOMATO_PICTURE_BOOK_REFERENCE_IMAGES` 旧开关。
- 「Relevant characters」匹配只在 Flutter `PictureBookService` 实现：按文章标题/正文/`articles.sentences` 做首字母大写整词人名命中；Web UI 不得本地重算。编辑书籍角色时走 `pictureBook.resolveRelevantCharacters`。小写普通名词（如 `bill`）不得匹配角色名 `Bill`。
- 绘本章节分镜持久化规则：`story_chapters.summary_json` 在 `article.create`（绘本开启）时写入首次章节规划供审核展示，之后以用户保存/确认的审核内容为准；不要为绘本分镜引入 `contentHash`、正文指纹或“输入变更即自动作废”机制。下列操作不得自动让已保存分镜失效：`article.rename`、绘本审核里改书籍简介/角色、听力页 `listening.updateSentence` 的字幕微调（含**软隐藏**：清空英文字幕存空槽，不重排 index、不 invalidate 分镜）。绘本分镜、prompt 审核、`summary_json.scenes[]` 与 `picture_book_pages` 的 `sentenceStartIndex` / `sentenceEndIndex` 必须始终使用 `articles.sentences` 原始槽位下标；允许拼接 prompt 文本时跳过空字符串，但绝不能过滤空槽后重排编号，否则后续可见句会落到错误图片范围。当前产品没有整篇正文编辑，改变分句边界只能删文重建。首次规划之后需要新分镜时，只能由用户显式点 `pictureBook.refreshPromptReview(target: chapterPlan)`（可选 `targetSceneCount`）、QA `pictureBook.replaceChapterPlan` 整表重设，或删文后重新走审核。打开 `pictureBook.promptReview` 时优先读取 `summary_json` 中非空 `scenes[].sceneDescription`；读不到才回退空占位草稿。不要在计划不可用时只保留 `chapterDescription` 却清空分镜并允许直接确认出图。对话练习提纲（`ChatChapterGuideService`）仍可使用自己的 `contentHash`，不要复用到绘本分镜。
- 听力字幕软隐藏：`listening.updateSentence` 允许清空英文，DB 保留 `""` 空槽与原始 index；听力/跟读/导出/TTS 跳过隐藏句，歌曲仍用 metadata `submittedLyrics`。规则见 `docs/listening_sentence_hide_rules.md`。
- 顺序组图是正式绘本链路：`PictureBookService` 通过 `PictureBookImageService.generatePictureBookImageGroup(...)` 按当前 `ai_provider` 分流，阿里云走万相异步连续组图（`enable_sequential: true`，`n` 等于已确认 scene 数），火山走 Seedream `sequential_image_generation`（`max_images` 等于已确认 scene 数）。组图失败不自动回退到另一平台或单图；失败页保存错误原因，重试按钮重新打开审核并在确认后重建整章组图。
- 单页重生成（`pictureBook.pagePromptReview` / `confirmPagePromptReview`）分两种 mode：目标页 `ready` 且本地图可用时走 `singlePageEdit`（用户只填「修改说明」，默认强制选中当前页作参考图；Flutter 用指令编辑模板包装说明，不写回 `summary_json`、不改书籍简介/角色）；失败页 / 无可用图时走 `singlePage`（仍审核书籍/章节/分镜与组合 prompt，参考图默认最近邻 1 张）。两种都可多选参考图（至少 1 张、最多 14 张）；确认时提交 `referencePageIndexes`，服务端按 `pageIndex` 升序解析为 `referenceImagePaths`。整章组图不传参考图。不要恢复 `TOMATO_PICTURE_BOOK_REFERENCE_IMAGES` 或固定全局参考图资产。
- 创作中心每页可「导入图片」（`pictureBook.importPageImage`）：FilePicker 选择本地 png/jpg/jpeg/webp；已是 16:9 `2560x1440` 则原样写入缓存，否则 Flutter 原生 cover-crop + 双线性（`FilterQuality.medium`）重编码为该尺寸 PNG（`source: import`）并替换该页为 `ready`；不调用图片 API、不打开审核、不改 `summary_json` / 句子区间。
- 创作中心可「导出组图」（`pictureBook.exportChapterImages`）：导出本章 `ready` 且本地图可用的页到选定目录，文件名为两位场景序号（`01.png`…）；同目录顺带写出 `chapter-english.txt`（章节英文原文）与 `group-prompt.txt`（组图总 Prompt，优先页内已确认 `groupPrompt`，否则按书籍/章节分镜重拼）；自定义前缀会一并加到图片与这两个文本文件名上。遇同名文件先返回冲突，由 UI 选择覆盖或自定义前缀改名后再写。
- QA 可用 `pictureBook.replaceChapterPlan` 整表重设 `chapterDescription` + `scenes[]`（含句子区间），不调文本 AI、不出图；写入后同步页骨架，可直接 `importPageImage`。场景数量标签、数字输入框和「按此数量匹配分镜」按钮在审核框标题行保持单行横排，Windows 窄窗口不得换行或溢出。AI「按数量匹配分镜」与确认组图仍受 12 景上限约束。
- 整章组图 HTTP 返回可能按每张图耗时数分钟，不能再用固定 120 秒判定失败。火山 `VolcImageService` 按请求图片数动态设置接收超时，默认每张 150 秒、最小 180 秒、最大 2700 秒；可通过 `TOMATO_VOLC_IMAGE_SECONDS_PER_IMAGE`、`TOMATO_VOLC_IMAGE_MIN_RECEIVE_TIMEOUT_SECONDS`、`TOMATO_VOLC_IMAGE_MAX_RECEIVE_TIMEOUT_SECONDS` 调整。阿里云 `AliyunWanxImageService` 使用 DashScope 异步任务轮询。最终组图 prompt 按审核内容完整提交，不做压缩或上限截断；如平台限制导致失败，先暴露真实提示词再处理。
- 绘本保存/生成/听力模式的最终联调必须跑真实 Windows App UI。`tools/build_windows.ps1` 默认开启本机 QA 控制接口（`127.0.0.1:39317`）；手动 Flutter 启动时再显式开启 `TOMATO_QA_REMOTE=true`。用 `npm run qa:picture-book-live` 通过 QA 控制接口填表保存、打开听力、轮询异步绘本状态、检查 loading/error/ready UI、字幕和播放；不要只用 service/test harness 作为最终结论。
- 对话练习提纲由 `ChatChapterGuideService` 单独生成紧凑教学覆盖点；程序内部 fallback 只在无 key/远程失败时本地生成最多 8 个覆盖点，后续聊天轮次只复用提纲，不重复提交完整章节。
