# 英文朗读分句 V3

生产版本标识继续使用 `read_aloud_dp_v3`；经端侧句法、确定性求解及候选路径复核后保存为
`reviewed_dp_v3`。版本号没有升级为 V4。

当前候选与引号保护规则的内部求解器子版本为 `syntax_solver_v3_3`；子版本参与缓存和运行审计，
但不改变文章级 V3 标识，也不会迁移旧文章。

V3.3 的完整候选格、软句法证据与受约束 AI 扩展已经实现。端侧和本地回归已通过；阿里
`qwen3.7-max` 和火山 `deepseek-v4-flash-ga-260731` 已达到受约束路径选择门槛。柳林风声迁移仍须
在独立的全量文章、图片和媒体发布验收阶段执行。实施证据与阻断项见
`docs/read_aloud_sentence_split_v3_3_implementation_report.md`。

已有文章继续读取 `articles.sentences`。算法升级不会自动重分旧文章，也不会使旧翻译、听力、绘本、
字幕或视频失效；只有新建文章和用户显式重建才使用 V3。柳林风声数据库和媒体迁移必须等待全部
通用回归门槛通过。

## 唯一生产入口

1. Windows DLL 与 Android `.so` 使用同一份 UDPipe 1.4 C++ 引擎和同一英语模型。
2. 原生插件返回保留原文字符区间的 token、POS 和依存树；Dart 在后台 isolate 中解析并校验模型
   SHA-256、token offset 和原文回拼。
   原始 UDPipe 句界不直接作为文章句界：Dart 先按独立终止标点、引号和段落结构生成正字句，
   再用 `presegmented` 复解析。疑似引语归属结构先暂时合并，再结合原文引号方向、段落、相邻
   引语协调关系、闭引号后小写依存片段，以及复解析树中的 `ccomp/parataxis/conj` 或合法祖先链
   确认；整个过程不使用说话动词、角色名或固定短语词表。生产服务、原生评估测试和全书审计
   共用纯 Dart `UdpipeRawPipelineV3`，不维护另一套离线边界算法。
3. `ArticleSegmentationServiceV3` 调用唯一的 Dart 求解器 `ReadAloudSplitterV3`。Web UI 不分句，
   只通过 typed bridge 提交原文并接收最终句子、译文和诊断。
4. 分句冻结后才翻译；导入中英对照和完全相同的旧人工译文优先，仅补译缺失的新句。

UDPipe 引擎自身不包含英语知识，必须加载语言模型。官方预训练模型以 CC BY-NC-SA 发布，不随本
App 打包；项目模型使用固定版 UD English EWT 通用树库训练，不使用柳林风声、角色名、坏例单词
或项目语义词表。模型训练命令、来源、许可、版本与 SHA-256 见
`docs/third_party_sentence_parser_v3.md`。

## 硬约束和路径搜索

- 只切分、不合并：原文句号、问号、感叹号形成的正字句界不可跨越，短句保持原样。
- 同时满足 30 词输出上限和 20 词最长无标点跨度的原句保持原样，包括不足 8 词的短句。
- 需要切分时先只建立 `; : — –` 和依存树确认的从句逗号候选，求解纯标点完整路径。
- 纯标点无解时建立所有原文安全词间间隙组成的完整候选格；字符/token 内部、多词 token
  内部、数字/小数/缩写内部、clitic 和 offset 异常才是硬阻断。
- UD 子树、跨越弧和 `det/case/aux/cop/mark/cc/compound/compound:prt/fixed/flat/amod`
  等紧密关系是软风险证据，不能删除安全路径。解析器错树不得使正确边界从候选集中消失。
- 明显主谓或谓语不定式表面分离写入 `softWarnings` 供 AI 审核，不改变本地路径风险和排序。
- 句末标点的 `punct` 依存弧只负责排版归属，不参与切点评估；否则根节点句末句点会虚假跨越
  句内所有候选，把合法从句边界错误降级为应急切点。
- 从句逗号除单一完整子树外，还可由逗号右侧最近的跨界谓词及其显式主语确认；这避免远端错误
  依存弧否定明显的并列主谓结构。逗号后立即开始引语时，该间隙视为受保护的说话/引语归属，
  不作为普通标点或句法切点。
- 每个超限原句初轮最多 8 条、扩展轮最多 24 条完整可行路径；每条含稳定
  `candidatePathId`、片段、词数、依存理由、软警告与风险。

完整路径使用严格字典序比较：30/20 硬约束、原文句界、标点路径优先、依存完整性、最少切点、
避免新增不足 8 词片段、无标点跨度接近 8–16、长度均衡最后。不得为了均衡长度牺牲语法自然性。

## 受约束 AI

- 纯标点路径不调用 AI；只有最终候选含无标点切点时才允许复核。
- AI 请求只包含原句与程序已经生成的完整路径；响应只能包含
  `originalIndex + candidatePathId`。
- AI 不能返回 `endToken`、token 锚点、改写文本、翻译或自行增加切点。旧自由切点协议已从生产
  Dart 删除，旧 Web Wink/Compromise 实现和脚本已移入 `web_ui/legacy_sentence_split/`，不可编译或调用。
- AI 可为每个原句返回现有 path ID 或 `REJECT`；合法拒绝触发唯一一次扩展轮，非法响应或超时
  重试同轮。整篇文章最多两次远程分句请求，之后采用本地路径并明确记录诊断。
- 阿里 `aliyun_bailian/qwen3.7-max` 使用已验收的 `article_split_v3_candidate_path_p7`；
  火山 `volcengine/deepseek-v4-flash-ga-260731` 使用 `article_split_v3_candidate_path_p8` 和首轮精简
  扩展候选。两者均通过 30/30 approved、协议合法率与重复一致性门槛；火山 Lite/Pro 仍使用
  本地确定性路径且不发送分句 AI 请求。Lite 在同一 P8 精简扩展协议下复测三轮仍为协议失败、
  9/10、8/10，未达到生产门槛。
- 调优调用必须显式启用 50 元硬预算。预算器在下一次请求可能越限前停止，失败请求也按最坏预留
  计费，报告记录厂家、模型、调用数、token、缓存来源和估算费用。

分句缓存键包含原句哈希、候选路径哈希、解析器版本、模型 SHA、提示词版本、AI 厂家和模型；翻译
使用独立逐句缓存。失败、mock 与非法结果不写成功缓存。每次保存同时写入
`article_segmentation_runs`，保留候选、最终路径、模型信息、应急原因、usage 和费用。

## 回归与发布门槛

- `app/test/fixtures/sentence_split_gold_v3.json` 保留 243 个金标项目。
- 同一批 243 项的直接基线为退役 V2 精确匹配 112 项（46.09%）。项目 EWT 模型配合 V3.3
  确定性流程精确命中 207 项（85.19%），且 243/243 的人工认可路径都存在于候选集；十类困难
  输入为 10/10，冻结 EWT 留出集为 60/60。候选召回达标不等于所有 AI 厂家已经达到发布标准。
- `read_aloud_splitter_v3_cases.json`、`historical_web_sentence_cases_v3.json` 和
  `legacy_freeform_split_contract_v3.json` 保留既有 Web、历史文章和旧自由 AI 协议案例；不得静默删除。
- 开发期使用官方 UDPipe 模型、Stanza 与 spaCy 作独立参考，只比较依存关系和分句结果，不进入 App。
- 官方 UDPipe English-EWT 2.5 在当前 EWT r2.18 test 上的同机开发基线为：token F1 98.86%、
  sentence F1 88.14%、UPOS 92.71%、UAS 79.66%、LAS 75.94%。该 CC BY-NC-SA 模型只放在忽略的
  `build/udpipe-reference/`，绝不随 App 发布。项目模型必须用同一命令和同一 test 集比较。
- `tools/sentence_split_v3/compare_reference_parsers.py` 对通用对话、新闻、学术、技术、法律、
  学习者英语和诗性片段生成 UDPipe/spaCy/Stanza 逐 token 依存报告；解析器分歧必须人工归因，
  不进行简单多数投票，也不得据此新增词条例外。
- 通用 AI 调优夹具在任何付费请求前先执行候选预检。官方 UDPipe 在首轮 10 类通用输入中只为
  7 类生成了人工认可路径；最近一次通用结构修复后仍为 7/10。其余学术、技术、法律句分别
  出现错误谓词根、错误主语和错误从句
  依附，而 spaCy/Stanza 在对应结构上更合理。因此模型即使 aggregate UAS/LAS 合格，也必须通过
  任务级候选覆盖和解析健康度门槛；AI 不得用于掩盖“正确路径根本不存在”的解析失败。
- 原生桥保留 Parsito 的 `parseCost/parseCostPerToken` 供审计，但不得单独据此宣布树健康。对上述
  错树的实测表明，模型可能以较高分且 beam/greedy 一致地解析错误；重复解析稳定性也不能替代
  多类型金标和任务级候选覆盖。
- 必须验证小说、对话、新闻、学术、技术、法律、说明文、学习者英语、诗歌、引号、缩写、小数、
  专名、异常标点、全部历史 TTS/听力文章、Alice 案例和柳林风声 62 章。
- 所有输出必须完整回拼、不丢词重词、不跨正字句、每段不超过 30 词、无标点段不超过 20 词、
  有纯标点方案时不用无标点切点、受保护依存关系零违规。
- Windows/Android 必须使用同一模型 SHA 且共享 fixtures 输出一致；全量验收前不迁移柳林风声数据库，
  不生成新 TTS，不替换本地或网盘视频。

`app/tool/split_willows_sentences.dart` 是只读全书审计入口：它按 E01–E62 读取语料和旧
`sentences.json`，调用同一纯 Dart/原生 V3 管线，并把逐章句子、候选路径、token/POS/依存树、
解析成本和风险聚合写入项目 `output/`。它不写柳林风声源目录、数据库、TTS、字幕、视频或网盘。
