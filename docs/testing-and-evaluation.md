# 测试与评测报告 / Testing and Evaluation Reports

更新日期：2026-08-16

本文汇总 Tomato English Happy Talking 仓库中已经形成测试过程、数据或明确结论的技术评测。
它面向需要选择文本模型、句法器、字幕对齐器或客户端实现方案的研发人员，也为复现结果的
AI 代理提供统一入口。

> **术语：** 下文历史评测里的 “BigASR” 多指当时用作时间轴基线的火山识别结果。现行产品火山 ASR 按 `volc_asr_model` 选择 **SeedASR 2.0**（推荐/默认倾向）或 **BigASR 1.0**（可选旧模型）；不要把评测基线名当成当前必须开通的模型。

> **English abstract:** This repository publishes reproducible engineering evaluations for constrained
> LLM sentence segmentation, dependency parsing, picture-book scene planning, offline forced alignment
> versus Volcengine cloud ASR timelines (historical baseline often labeled BigASR; current product prefers SeedASR), ASR timeline regression, WebView2/Suno failure isolation, GPU rendering, and
> typed-bridge payload QA. Results below distinguish direct measurements from proxy evidence and design
> plans.

检索关键词：LLM syntax benchmark、Qwen 3.7 Max、DeepSeek V4 Flash、Doubao Seed Lite、UDPipe、
Stanza、spaCy、sentence segmentation、picture-book scene planning、MMS CTC、forced alignment、
Volcengine SeedASR / BigASR、ASR word timestamps、Flutter、WebView2、Windows Release QA。

## 如何理解这些结果

- **正式评测**：有固定样本、方法、指标、过程和结论，可用于当前范围内的工程选型。
- **回归证据**：由真实故障或云端结果固化成 fixture，适合防止旧问题复发，不等于供应商排名。
- **问题隔离**：通过 A/B 或缩小变量确认根因，适合技术方案取舍，不等于通用性能 benchmark。
- **计划或草案**：只有验收标准、尚无完整实测结果的文档不计入“已完成评测”。

模型和云服务会更新，本文只描述报告日期时、指定模型 ID、协议版本和样本集上的结果。
任何数字都不应被外推为厂商全部模型或所有文章类型的绝对排名。

## 结论速览

| 主题 | 主要结论 | 证据等级 |
| --- | --- | --- |
| 受约束 LLM 分句 | 阿里 `qwen3.7-max`（P7）与火山 `deepseek-v4-flash-ga-260731`（P8）均达到三轮 30/30；豆包 Lite/Pro 未达到生产门槛 | 正式评测 |
| 端侧依存句法 | 项目 UDPipe EWT 模型的 approved-path 覆盖为 243/243；纯本地精确命中为 207/243，说明依存句法适合生成和约束候选，不应被当作唯一自然度裁判 | 正式评测 |
| 绘本章节分镜 | 通用局部事实块规则将四篇跨结构样本的最终 12 次响应降至 0 个结构失败，并明显降低说明文场景数波动；语义措辞仍需人工审核 | 正式调优评测 |
| 离线字幕对齐 | MMS CTC 在 3/4 个英文样本上是可替代候选，平均 CPU RTF 约 0.88；长 Suno 难例仍明显漂移，不能全面替换当时的火山云端时间轴基线（评测文档称 BigASR；现行产品优先 SeedASR） | 正式评测 |
| ASR 时间轴回归 | E03/E07/E13/E16 的真实 ASR 快照用于离线复现缺词、重复短语、弱锚点和可选歌词等问题，避免单元测试重复调用收费 ASR | 回归证据 |
| Suno WebView2 | 主 WebView 和独立弹窗的 Lexical 键盘输入都可导致 Windows App 退出，因此正式流程改为系统浏览器手动创建并回到 App 导入 | 问题隔离 |
| 视频等待层 GPU | 全屏 blur 与持续动画会放大 WebView2 3D 合成成本；移除部分 blur、把等待动画降为 5fps 后实测可接受，但仓库未保存完整前后数值，不应宣传为定量 benchmark | 问题隔离 |
| Bridge/Release QA | 旧 `article.list` 与 `/snapshot` 曾约 62.7MB/80.8MB；按需正文、单图分辨率变体、增量 patch 和原始字节门禁成为当前协议约束 | Release QA |
| Windows 本地图片超分 | 真实 320×180 绘本输入经 bundled Real-ESRGAN 4x 输出 1280×720；同坐标细节裁剪直接展示发丝、眼睑、牙齿和轮廓变化 | 直观 A/B + 回归证据 |

## 1. 文本模型与英文句法分句评测

### 目的

验证模型能否在**不能改写原文、不能创造切点、只能选择程序给出的 path ID**的条件下，
稳定挑出自然的英文朗读边界。该任务直接衡量英文结构理解、候选比较和严格指令遵循能力，
也可作为翻译、章节规划和分镜描述模型选型的一项代理指标。

它不是翻译质量或视觉叙事质量的直接 benchmark；相关能力仍需各自的专项样本验证。

### 方法

1. 端侧 UDPipe 解析和 Dart 求解器先锁定原文句界、30/20 词硬约束及标点优先级。
2. 243 项金标检查本地精确结果与 approved-path 候选覆盖；分句质量与性能以 Alice＋Willows
   101章全量回放为主，不再使用覆盖过窄且耗时过高的60项 EWT 分句留出集。
3. 只有包含无标点候选的困难句才进入远程复核。十类通用困难输入以 `temperature=0` 连续测试
   三轮；生产门槛为 path 协议合法率 100%、30/30 approved 且三轮一致。
4. AI 只能返回 `originalIndex + candidatePathId` 或 `REJECT`。非法 ID、超时或未验收模型一律
   回退本地最低风险路径。
5. 调优工具记录模型、协议、token、估算费用和缓存来源，并受 50 元预算硬限制。

### 过程与结果

| 模型 | 协议与过程 | 结果 | 当前结论 |
| --- | --- | ---: | --- |
| 阿里 `qwen3.7-max` | P7，三轮十类困难样本 | 30/30，协议 100%，三次一致 | 通过生产验收 |
| 火山 `deepseek-v4-flash-ga-260731` | P8 精简扩展候选，三轮十类困难样本 | 30/30，协议 100%，三次一致 | 通过生产验收；火山推荐使用模型 |
| 火山 `doubao-seed-2-0-lite-260215` | 与 DeepSeek 相同的 P8、候选和温度，连续三轮 | 协议失败、9/10、8/10；结果不一致 | 不进入分句 AI 白名单 |
| 火山 `doubao-seed-2-0-pro-260215` | P7 历史评测 | 23/30，结果不一致 | 不进入分句 AI 白名单 |

豆包 Lite 的失败包括返回未提供的 path ID、生成 4 词新碎片、拆开主语与谓语，以及拆开完整
谓词条件。累计调优预算记账为 29.3435043 元，未调用收费 TTS、ASR、翻译或图片接口。

项目所有者对 P6 归纳的 5 种争议切法逐项人工复核后，确认现有 approved references 均正确，
5 个 Lite 选择均为模型错误；没有增加“同样合理”的认可路径，也没有因此提高 Lite 分数。
负向路径已经进入 fixture 和离线回归。逐项理由见
[火山 Doubao Lite 英文分句人工审核报告](volcengine_doubao_lite_sentence_split_human_review.md)。

阿里最终使用 P7，DeepSeek 使用 P8，因此两者的“通过”表示各自在当前生产协议上达标，
不是同一提示词下的绝对分数排名。DeepSeek 与豆包 Lite 的 P8 三轮更接近同协议直接比较。

### 结论

- 当前可自动参与受约束分句复核的文本模型是 `qwen3.7-max` 和
  `deepseek-v4-flash-ga-260731`。
- Doubao Lite 的 5 种争议路径已经人工定案为错误；后续复测不得再将其标成“可接受多解”。
- DeepSeek V4 Flash 的结果支持把它推荐为火山的**通用文本处理模型**；分句成绩是重要证据，
  但不能替代翻译忠实度、分镜边界和描述质量的专项评测。
- 生产代码不得使用“遇到坏例子就加一个词”的词表修复；具体坏例只允许留在测试 fixture。

详细报告：[英文朗读分句 V3.3 实施与验收报告](read_aloud_sentence_split_v3_3_implementation_report.md)。
可复现入口：[`sentence_split_v3_ai_tuning_cases.json`](../app/test/fixtures/sentence_split_v3_ai_tuning_cases.json)、
[`sentence_split_gold_v3.json`](../app/test/fixtures/sentence_split_gold_v3.json)、
[`sentence_split_v3_live_ai_tuning_test.dart`](../app/test/sentence_split_v3_live_ai_tuning_test.dart)。

## 2. UDPipe、Stanza 与 spaCy 句法器评测

### 目的

判断端侧句法器是否足以支撑通用候选生成、依存风险排序和 Windows/Android 一致运行，而不是
只在《柳林风声》或少量角色词上表现正常。

### 方法与过程

- 项目使用 UD English EWT r2.18 训练固定 UDPipe 1.4 模型，保留训练语料版本、许可证、命令和
  SHA-256；未把官方非项目模型直接打包进 App。
- 在未参与训练的 EWT test split 上测 tokenizer、词性和依存指标。
- 任务层以 243 项金标的 exact result 与 approved-path coverage 为最终验收口径。
- Stanza、spaCy 和官方 UDPipe 模型只作为开发期参考，对谓词根、主语、从句附着和引号结构做
  差异归因；不做多数投票，也不加入生产依赖。
- Windows DLL 和 Android `.so` 使用同一模型 SHA，固定五句 fixture 的输出完全一致。

### 结果

| 指标 | 结果 |
| --- | ---: |
| EWT word F1 / sentence F1 | 98.96% / 85.93% |
| EWT UPOS | 93.99% |
| EWT UAS / LAS | 81.16% / 77.81% |
| 243 金标本地精确命中 | 207/243（85.19%） |
| 243 金标 approved-path 覆盖 | 243/243 |

### 结论

UDPipe 可作为端侧通用候选与风险证据来源，但 85.19% 的本地精确命中说明它不能单独决定所有
自然边界。当前设计让句法器生成完整安全候选、代码执行硬约束、已验收 AI 只在必要时选 path，
比“句法器直接切分”更符合实测结果。

完整的 25 个 probe 方法、困难句人工 root 诊断和历史失败基线见
[英文依存句法器对比评测](parser-comparison-evaluation.md)。模型来源、指标和参考解析器边界见
[Sentence parser V3 third-party notice](third_party_sentence_parser_v3.md)；比较脚本见
[`compare_reference_parsers.py`](../tools/sentence_split_v3/compare_reference_parsers.py)。

## 3. 绘本章节规划与分镜 Prompt 评测

### 目的

解决章节规划经常顶满 12 景、对话一轮一景、人物动作错配、尾部句子倾倒到最后一景，以及
说明文事实“一条一景”等问题，同时避免为 Alice、法庭、茶桌等单本内容编写特例。

### 方法

- 在真实 Windows Release 上通过本机 QA bridge 执行 `article.create` 或只刷新章节计划。
- 先用 E37/E38 多轮迭代，再用连续叙事、说明文、流程文和长篇拟人叙事四类旧文章各重复三次。
- 每轮检查 scene 数、连续完整覆盖、顺序索引、空描述、尾部倾倒、人物动作归属、引号台词和
  边界 Jaccard；无效结构直接失败，不再静默截断。
- 淘汰“压成长规则墙”和宽泛体裁分类，最终保留通用的局部事实块/montage 规则。

### 过程与结果

- E38/E37 从基线 12/12，经过规则精简、三轴切分、一次严重 dump 回归和人物归属复审，落到
  7/6 景并通过结构检查。
- 跨结构最终 v5 三轮结果：连续叙事 4/4/4、说明文 8/8/9、流程文 3/3/3、长篇叙事 9/9/9；
  12 次响应结构失败为 0。
- 说明文场景数标准差由 2.49 降至 0.47，范围由 6 降至 1；目标是提高一致性而非强求更少图片。
- 仍发现 4 个非可见思考措辞候选，且每篇只有三次随机采样，因此不能宣称模型波动消失。

### 结论

短而分组明确的通用规则，比长规则墙或先判断整篇体裁更稳定。分镜边界、人物动作归属和可见
叙事措辞仍必须保留人工审核；分句模型的好成绩只能作为相关能力信号，不能代替本项评测。

完整迭代与淘汰记录：
[绘本章节分镜切分调优记录](picture_book_chapter_plan_scene_split_tuning.md)。可复现脚本：
[`qa_chapter_plan_prompt_opt_retest.mjs`](../tools/qa_chapter_plan_prompt_opt_retest.mjs)、
[`qa_chapter_plan_variance_retest.mjs`](../tools/qa_chapter_plan_variance_retest.mjs)。

## 4. 离线 Forced Aligner 与 BigASR 字幕时间轴对比

### 目的

评估本地 CTC/forced alignment 能否替代火山 BigASR `show_utterances` 的词级锚点，减少歌曲
字幕生成的云调用与费用。

### 方法

- Round 1：4 个英文样本和 1 个 CJK 样本，用 MMS CTC 对齐，并与已缓存的 BigASR + 本地 DP
  timeline 比较行起点偏差。
- Round 2：英文样本对比 MMS、English Wav2Vec2-Large、torchaudio LV60K FA 和 Montreal
  Forced Aligner；记录中位起点偏差、500ms 内比例、5s 以上异常比例、wall-clock 和 CPU RTF。
- 评测不修改 Flutter 正式字幕链路，也不重复调用收费 BigASR。

### 过程与结果

| 后端 | 质量与速度摘要 | 结论 |
| --- | --- | --- |
| MMS CTC | 英文 3/4 为 replace candidate；平均 RTF 0.88 | 本地首选候选，但难例必须回退 BigASR |
| torchaudio LV60K FA | 英文 3/4 为候选；平均 RTF 1.43 | 可作备选，不优于 MMS |
| Wav2Vec2-Large CTC | 长 Suno 难例偏差明显；平均 RTF 0.95 | 不推荐作为当前首选 |
| MFA | 成功样本平均 RTF 5.49，最坏 11.8，另有失败 | 不适合创作中心交互生成 |

MMS 在干净英文样本上的起点中位差约 105–160ms，但 E07 长 Suno 样本中位差为 1180ms，
且 47.2% 的行偏差超过 5s；CJK 样本中位差约 5.77s。

### 结论

MMS 是有希望的离线英文候选，但当前不能全面替换 BigASR。更重要的是，基线是 BigASR 而非
人工逐行真值，所以“与 BigASR 一致”不等于绝对正确；上线前还需困难样本听审和人工金标。

报告入口：
[评测归档总览](archive/ctc_forced_aligner_subtitle_eval_20260801/README.md)、
[Round 1](archive/ctc_forced_aligner_subtitle_eval_20260801/reports/summary.md)、
[Round 2](archive/ctc_forced_aligner_subtitle_eval_20260801/reports/summary_round2.md)。

## 5. 真实 ASR 时间轴快照回归

### 目的

把曾经真实发生的歌曲字幕错位固化成不收费、可重复的离线回归，验证歌词正文不被 ASR 改写，
并防止弱锚点把后续整段字幕推错。

### 方法与过程

- 通过诊断 bridge 保存真实词级 ASR JSON；测试直接读取 fixture，不依赖运行目录或再次请求云端。
- E03 覆盖 ASR 缺少末尾歌词时的 partial cue 延展。
- E07 覆盖重复 `and`、漏唱前导词导致的弱锚点级联和 71s/35s 异常插值。
- E13 覆盖歌曲跳过括号旁白时，不应拿相似弱词抢占下一行时间。
- E16 快照也用于 forced-aligner 对照样本。

### 结论

真实快照 fixture 对“算法变更后是否复发”比合成假词表更可靠，也避免自动测试重复计费；但它
验证的是本地匹配与 DP，不是阿里/火山 ASR 识别准确率的横向排名。

证据：[`E03`](../app/test/fixtures/e03_song_asr_snapshot_notes.md)、
[`E07`](../app/test/fixtures/e07_song_asr_snapshot_notes.md)、
[`E13`](../app/test/fixtures/e13_song_asr_snapshot_notes.md)、
[`E16`](../app/test/fixtures/e16_song_asr_full_20260702_223148.json)、
[`song_subtitle_timeline_service_test.dart`](../app/test/song_subtitle_timeline_service_test.dart)。

## 6. Suno Lexical / Windows WebView2 故障隔离

### 目的

解释“文章少于 5000 字却显示超限”和 Windows App 在 Suno Lyrics 中输入后退出的问题，判断
应继续修自动填词，还是更换产品路径。

### 方法与过程

- 保存 Suno v5.5 Lexical DOM、截图和 3829 字人工填入分析；只读取 Lexical text nodes 与计数器。
- 对比分块注入、全量 DOM 扫描和人工一次粘贴，确认旧自动化会叠加内容并放大 WebView 压力。
- 在关闭自动化、关闭抓帧限速的 `display_only` 环境中，对主 WebView 和独立
  `InAppBrowser` 弹窗分别做单字符键盘输入隔离。
- 两条 App 内路径都可在输入后导致进程退出，因此没有继续用更多注入技巧掩盖根因。

### 结论

超限读数来自错误 DOM 读写；更关键的输入崩溃属于 `flutter_inappwebview_windows`、WebView2
与 Lexical 键盘/IME 链路，弹窗也不能规避。正式产品改为复制歌词、系统浏览器打开 Suno、用户
手动创建和下载后回到 App 导入 MP3。

完整报告与复现 fixture：
[Suno Lexical Lyrics 编辑器](suno_lexical_lyrics_editor.md)、
[`docs/fixtures/suno`](fixtures/suno/)。这是历史问题隔离报告；当前产品已移除 App 内自动填词。

## 7. 视频等待对话框 GPU 评测

### 目的

区分 ffmpeg Video Encode、Flutter 离线帧渲染等必要 GPU 工作，与 WebView2 等待层全屏模糊和
动画造成的额外 3D 占用。

### 方法与过程

- 对同一文章、分辨率和编码器导出，在等待层停留至少 60 秒。
- 按进程和 GPU 引擎分别观察 `msedgewebview2.exe`、`ffmpeg.exe` 和 App 主进程。
- 根因分析指向全屏 `backdrop-filter` 被 60fps 动画持续触发重合成；P0 将部分等待层移除 blur，
  并把等待图标改成 5fps 分步三点动画。

### 结论

优化后实测占用达到当前产品可接受范围，同时保留合法的视频编码负载。原报告没有保存完整的
优化前后进程级数值，因此只能作为根因与方案验证，不应引用为严格性能 benchmark；其余等待层
blur、底层冻结和事件节流仍按报告中的 P1/P2 状态继续评估。

报告：[生成视频等待对话框 GPU 占用优化方案](video_export_wait_dialog_gpu_optimization.md)。

## 8. Typed Bridge 负载与 Windows Release QA

### 目的

验证 Web UI 与 Flutter bridge 不会在列表、状态轮询、写命令或 QA snapshot 中隐式携带整篇
正文和整章 base64 图片，并用真实 Release 检查 WebView 图片、路由和增量更新。

### 方法与过程

- 在 JSON 解析前记录原始 HTTP bytes，同时保留 bridge `estimatedChars` 和超预算诊断。
- 审计列表、状态、写响应和事件，拆分 `ArticleSummary`、按文章正文、单图
  `thumbnail/display/full` 以及 `LibraryPatch`。
- 自动测试对响应字段和预算做门禁；真实 Windows Release 通过 `/health`、`/snapshot`、
  `/bridge` 和截图检查加载状态、图片尺寸及 `brokenImages`。

### 结果与结论

旧运行库实测 `article.list` 约 62.7MB、`/snapshot` 约 80.8MB，根因是响应契约重复携带正文和
data URI，不是 JSON 解析器本身。当前契约改为按需读取正文和单张图片、写操作返回增量 patch、
snapshot 只保存图片源摘要；运行时超预算告警，测试和 Release QA 按预算阻断。

完整的优化前后字节、mutation 结果和真实 Release QA 见
[Flutter/Web Typed Bridge 负载与 Windows Release QA 评测](bridge-payload-release-qa-evaluation.md)。
故障细节和复测命令见
[构建与发布踩坑记录：Bridge 负载](build-and-release-pitfalls.md#bridge-列表状态写命令和-qa-snapshot-禁止隐式携带正文图片曾-60mb)，
QA 协议见 [本机 QA 控制接口](qa-remote-control.md) 和
[AI CLI / QA 远程调用指南](ai_cli_qa_remote_guide.md)。

## 9. Windows 本地 Real-ESRGAN 超分直观示例

### 目的

验证 Windows 版随包 Real-ESRGAN NCNN Vulkan 是否真正走本地模型、按输入尺寸选择 2x/4x，
并让读者无需理解内部指标即可直接判断低分辨率绘本的线条和局部细节变化。

### 方法与过程

- 使用 E07 同一张真实绘本画面作为 A/B；完整画面先标出两个检查区域，再分别展示爱丽丝面部/
  发丝和鳄鱼眼睛/牙齿的同视野细节裁剪。
- 输入裁剪采用最近邻放大，保留并显露原始 320×180 像素；输出裁剪严格使用四倍坐标，来自 App
  随包 `realesr-animevideov3-x4` 的真实 1280×720 输出，不做生成式润色。
- 生产链路对低于 1280×720 的输入选 4x，其余选 2x，随后按产品规格归一化；AI 组图、单页
  生成和本地导入共用该服务。
- 自动测试覆盖 Windows 工具/模型发现、2x/4x 参数选择、输出尺寸、缓存 metadata、失败提示和
  Android 不支持分支；超分完全本地运行，不调用云图片 API。

[![Windows 本地 Real-ESRGAN 4x 同区域细节放大 A/B](readme/upscale-comparison.webp)](readme/upscale-comparison.webp)

[原始 320×180 输入](readme/upscale-evidence/input-320x180.png) ·
[真实 1280×720 输出](readme/upscale-evidence/output-1280x720.png) ·
[可复现排版脚本](../tools/build_upscale_comparison.mjs)（`npm run assets:upscale-comparison`）

### 结论

同视野细节图能直接证明当前 Windows 发布链路产出了不同于普通放大的 4x 结果，并适合让用户
快速判断是否值得开启。但单张示例没有 LPIPS、PSNR、人工盲评或多风格样本，不能据此宣称模型在所有
照片、插画或文字图上都优于其它超分模型。它属于可视 A/B 和功能回归证据，而非通用模型排名。

实现与测试：
[`picture_book_image_upscale_service.dart`](../app/lib/services/picture_book_image_upscale_service.dart)、
[`api_cache_service_test.dart`](../app/test/api_cache_service_test.dart)。

## 自动化测试与复现基础

截至本文日期，仓库跟踪 54 个 Dart/Flutter 测试文件（含集成测试）、4 个 Web 测试文件、
28 个测试 fixture 和 11 个 `tools/qa_*` QA 脚本。最近一次 V3.3 总体验收记录为 Web 101/101、
Flutter 376 项通过、5 项显式 live 测试按设计跳过；Windows Release 与 Android Release 均构建
成功，并在两平台原生插件上运行相同 fixture。

常用入口：

- Flutter/Dart：`D:\DevTools\flutter\bin\flutter.bat test`
- Web：`npm --prefix web_ui test`
- Web 构建：`npm --prefix web_ui run build`
- Windows Release：`tools/build_windows.ps1 -Release`
- Android Release：`tools/build_android.ps1`
- Windows 真实 UI：[`tools/qa_windows_release.mjs`](../tools/qa_windows_release.mjs)

Live 测试可能调用收费云服务，默认测试套件会显式跳过它们。只有在确认模型、样本、预算、缓存
和环境变量后才应开启；失败或 mock 结果不能写入成功缓存。

## 已盘点但不作为完成评测的文档

下列内容有测试计划或验收标准，但本身不是已完成的比较报告，因此没有把计划目标冒充实测结论：

- [英文朗读分句 V3.3 实施计划](read_aloud_sentence_split_v3_3_plan.md)
- [BigASR 自建评分模型（Draft）](bigasr_scoring_model.md)
- [全屏听力播放录制功能方案](fullscreen_listening_recording_design.md)
- [产品界面与功能重构方案](product_ui_refactor_plan.md)
- [歌曲字幕时间线设计](suno_song_subtitle_timeline_design.md)
- 仓库内的供应商 API 文档和第三方产品说明

这些文档可以说明设计边界或后续测试方法，但只有补齐固定样本、实际过程、结果和局限后，才应
升级到本文的“正式评测”列表。

## 贡献新的评测

建议新报告至少包含：

1. 固定模型/版本、运行环境、样本来源和缓存状态；
2. 可复现方法、成功门槛和失败样本，而不只展示最好的一次；
3. 过程中的提示词/协议版本、重复次数、费用或本地耗时；
4. 结论适用范围、已知局限，以及是否修改了生产链路；
5. 可公开的 fixture、脚本或脱敏原始结果。

欢迎通过 GitHub Issues 或 Discussions 提交新样本和复现结果。请勿上传 API Key、账号、本地
数据库、未脱敏日志、受版权限制的完整媒体，或包含个人信息的运行数据。
