# 英文朗读分句 V3.3 实施与验收报告

> 本文是 2026-08-09 的历史验收快照。当前长度触发和路径排序已由
> `docs/read_aloud_sentence_split_v3_5_readability_rules.md` 取代；本文中的“安全原句保持原样”及
> 207/243 指标不得作为 V3.5 的当前验收结论。

日期：2026-08-09
文章版本：`read_aloud_dp_v3` / `reviewed_dp_v3`
内部求解器：`syntax_solver_v3_3`
AI 协议：阿里 `article_split_v3_candidate_path_p7`；火山 DeepSeek `article_split_v3_candidate_path_p8`

## 结论

端侧依存解析、完整安全候选格、确定性求解、受约束 AI、缓存、费用控制、审计、Web typed
bridge 及 Windows/Android 原生集成已经完成。通用候选召回、留出集、全量本地测试与双平台构建
通过。

阿里 `qwen3.7-max` 与火山 `deepseek-v4-flash-ga-260731` 均达到 30/30 approved、协议 100%
且三次一致，已经分别进入生产白名单。火山 Lite 和 Pro 仍未达到 100%，选择它们时继续使用
本地确定性路径。柳林风声数据库、TTS、字幕、视频和网盘资产未在本次模型验证中迁移。

## 核心实现

- 正字句界锁定，只切分不合并；安全原句保持原样。
- 30 词输出和 20 词无标点跨度为硬约束；8–16 词为偏好，不强迫短原句变长。
- 先求纯标点路径；无解时枚举所有原文安全词间间隙。UD 关系只作软风险，不删除安全路径。
- 初轮最多 8 条、扩展轮最多 24 条稳定路径；AI 只能返回已有 ID 或 `REJECT`。
- 整篇最多两次分句远程请求。成功缓存、非法响应、扩展直达缓存、模型白名单和失败回退均有测试。
- 审计记录包含 parser/model SHA、两轮候选、选择轨迹、软警告、usage、估算费用和应急原因。

## 解析器与语料指标

| 指标 | 结果 |
|---|---:|
| 模型 SHA-256 | `b71fb73473bedbca575bfc927fceb0f6dd53f74493bb9c58a9e77bd28d24a71f` |
| EWT word F1 / UPOS | 98.96% / 93.99% |
| EWT UAS / LAS | 81.16% / 77.81% |
| 243 金标本地精确命中 | 207/243（85.19%） |
| 243 金标 approved path 覆盖 | 243/243 |
| 十类困难输入候选覆盖 | 10/10 |
| 冻结 EWT 留出集 | 60/60，远程 0 |

## AI 调优与费用

| 模型 | 最终结果 | 生产状态 |
|---|---:|---|
| `aliyun_bailian/qwen3.7-max` | p7 30/30，协议 100%，三次一致 | 已验收 |
| `volcengine/deepseek-v4-flash-ga-260731` | p8 精简扩展候选 30/30，协议 100%，三次一致 | 已验收、火山推荐使用模型 |
| `volcengine/doubao-seed-2-0-lite-260215` | p8 同协议三轮：协议失败、9/10、8/10；不一致（历史 p6 最好 22/30） | 未验收 |
| `volcengine/doubao-seed-2-0-pro-260215` | p7 23/30，不一致 | 未验收 |

原有落盘调优报告和中断批次按 23.0793433 元计入预算；DeepSeek 本轮模型 ID 探测与四组能力
对照再计 0.663872 元；阿里 P8 复核因账号启用“仅免费额度”且额度耗尽而中断，再按预算器
保守计 5.419584 元；豆包 Lite 同协议 P8 三轮再保守计 0.180705 元。累计 29.3435043 元，
低于 50 元。阿里继续使用已完成 30/30 的 P7，
没有把未完成的 P8 记为验收。没有调用收费 TTS、ASR、翻译或图片接口。

豆包 Lite 的 P8 复测使用与 DeepSeek 相同的通用 P8 提示词、首轮最多 24 条精简扩展候选、
相同 10 个困难样本和 `temperature=0`。三个逻辑重复均已执行：第 1 次连续两次返回
`originalIndex=2` 的未提供 path ID，协议校验失败并按设计回退本地路径；第 2 次为 9/10，
错误地把 `Before replacing the filter` 独立成 4 词碎片；第 3 次为 8/10，分别把
`A tenant ... before the authority | begins ...` 的主语和谓语拆开，以及在
`... and wait | until every moving component ...` 处拆开完整谓词条件。三轮结果不一致，
因此不能进入自动分句白名单。完整报告：
`output/sentence-split-v3/live-ai-path-tuning-v3-3-p8-doubao-seed-2-0-lite-260215-expanded-compact.json`。

项目所有者随后对 P6 中归纳出的 5 种争议路径完成逐项人工审核：现有 approved references
全部确认，5 个 Lite 模型选择全部判错，不新增或放宽任何认可路径；此前关于过滤器句 4/19
短片段“可作次选”的建议在该固定评测中撤回。结论已写入 fixture 的 5 条
`humanRejectedChunks` 并由离线测试锁定。详见
[火山 Doubao Lite 英文分句人工审核报告](volcengine_doubao_lite_sentence_split_human_review.md)。

## 工程验证

- Web：101/101 测试通过，生产构建通过。
- Flutter：376 项通过，5 项显式 live 测试按设计跳过。
- 静态分析：无错误；保留 3 个提交基线已存在的 Suno/歌曲字幕未引用私有函数警告。
- Windows Release：构建通过，DLL 与固定模型均进入发布目录，模型 SHA 一致。
- Android Release：APK 构建通过，包含 arm64-v8a、armeabi-v7a、x86_64 的
  `libudpipe_parser_v3.so`，模型 SHA 一致。
- `integration_test/udpipe_parser_v3_integration_test.dart` 已分别在 Windows DLL 和 Android
  API 35 x86_64 `.so` 上实际运行；固定 fixture 的五句输出完全一致。

## 保持未执行

- 柳林风声 E01-E62 全书只读审计。
- 正式数据库替换和 782 页图片映射复核。
- TTS、字幕、124 个视频及 `\\Memospace\家庭共享\动画` 发布。

火山模型门槛已经由 DeepSeek V4 Flash 正式版满足；上述步骤仍需作为独立迁移发布阶段逐项
验收，不能只因模型小样本通过就直接覆盖正式数据库或媒体资产。

## 后续状态（2026-08-10）

本节只更新上述历史“保持未执行”清单的状态，不改变 V3.3 的历史指标。项目所有者确认 V3.5
可读性规则后，E01-E62 已使用既有 UDPipe 全书解析结果重新求解并完成人工复核；62 章共生成
4,995 个中英文一一对应句槽，其中 843 条旧译文检查后复用、4,152 条按童话叙事风格重译。

Release 数据库已经通过仓库外层一次性工具离线迁移，782 个既有绘本页的句子区间已重对齐；
图片和媒体字段未变，未重新合成 TTS，未调用远程 API。完整规则、统计和迁移证据以
`docs/read_aloud_sentence_split_v3_5_readability_rules.md` 为准。
