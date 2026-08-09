# 英文依存句法器对比评测：UDPipe、Stanza 与 spaCy

日期：2026-08-09

本文把此前保存在本地评测输出、实现报告和会话记录中的句法器对比整理为可公开引用的报告。
目标不是寻找一个“永远正确”的 parser，而是判断哪类工具适合端侧朗读分句，以及生产算法应当
如何处理 parser 之间的分歧。

> **English abstract:** We compared UDPipe 1.4 with spaCy 3.8.15 and Stanza 1.14.0 on 15
> mixed-structure probes and 10 difficult unpunctuated English sentences. On a manually reviewed
> main-predicate-root probe, Stanza scored 10/10, the official UDPipe English-EWT reference 8/10,
> and spaCy 7/10. This is a task diagnostic rather than a standard LAS benchmark. Production uses a
> separately trained, pinned UDPipe model as soft structural evidence because it is native, offline,
> reproducible on Windows/Android, and its candidate lattice reaches 243/243 approved-path coverage.

## 目的

评估三个问题：

1. 不同英文依存句法器在对话、文学长句、说明文、技术文、法律文、学习者英语和异常标点上，
   是否能稳定找到主谓结构与从句附着；
2. 更高的独立句法质量是否足以抵消移动端部署体积、Python/PyTorch 依赖和跨平台一致性成本；
3. 生产分句应直接服从单一 parser，还是只把依存关系作为候选与风险证据。

## 评测对象

| 解析器 | 本次角色 | 特点 |
| --- | --- | --- |
| UDPipe 1.4 + 官方 English-EWT 2.5 参考模型 | 开发期横向对比 | 原生、离线、小模型、CoNLL-U；不是 App 最终打包模型 |
| spaCy 3.8.15 + `en_core_web_sm` | Python 参考 | 工程生态成熟；默认句子切分会影响引号/多正字句比较 |
| Stanza 1.14.0 English pipeline | Python/PyTorch 参考 | 神经 UD pipeline；准确性优先但端侧部署较重 |
| 项目 UDPipe EWT r2.18 固定模型 | App 生产模型 | Windows DLL/Android `.so` 共用，SHA 固定；用独立 EWT 与任务金标验收 |

横向 probe 使用官方 UDPipe 参考模型，是为了回答“现成预训练解析器表现如何”；项目生产模型的
结果由独立 EWT test split 和 243 项任务金标另行评估。两部分不能混成同一排行榜。

## 方法

### 样本

- 15 个广覆盖 probe：引号与说话人归属、缩写和小数、文学并列、技术、法律、学术、学习者
  英语、片段和异常标点。
- 10 个分句困难 probe：新闻/研究、技术重试、法律通知、演讲、文学叙述、操作说明、备份、
  政策和设备保护；多数刻意去掉可直接依赖的逗号。
- 243 项朗读分句金标与 60 项冻结 EWT 留出集，用于生产模型和候选求解器的任务级验收。

### 运行与判定

- 同一输入分别保存 token、UPOS、head 和 dependency relation，不做多数投票。
- Stanza 关闭内部句子切分；spaCy 保留默认行为，因此含多个正字句的引号样本只用于结构观察，
  不纳入简单根节点计分。
- 10 个困难句由人工按“完整主句的中心谓词应为 root”复核。这个 10/10 指标是任务诊断，
  不是 UD 官方 LAS/UAS，也没有假装成大规模统计显著性结论。
- 对存在合理多分析的分号并列、诗性片段和不规范英语，不强行指定唯一赢家。

复现程序：[`compare_reference_parsers.py`](../tools/sentence_split_v3/compare_reference_parsers.py)。
固定输入：[`reference_parser_cases_v3.txt`](../tools/sentence_split_v3/reference_parser_cases_v3.txt)、
[`ai_tuning_reference_cases_v3.txt`](../tools/sentence_split_v3/ai_tuning_reference_cases_v3.txt)。

## 十个困难句的主谓根节点结果

| # | 句子摘要 | 正确主句 root | UDPipe | spaCy | Stanza |
| ---: | --- | --- | --- | --- | --- |
| 1 | committee released ... after investigators reviewed ... | `released` | ✅ | ✅ | ✅ |
| 2 | Because earlier studies measured ... researchers designed ... | `designed` | `effects` | `measured` | ✅ |
| 3 | client retries ... when gateway closes ... | `retries` | ✅ | ✅ | ✅ |
| 4 | tenant ... may request a hearing before authority begins ... | `request` | ✅ | ✅ | ✅ |
| 5 | Although Maria practiced ... she spoke slowly ... | `spoke` | ✅ | ✅ | ✅ |
| 6 | lantern ... continued to burn after travelers reached ... | `continued` | ✅ | ✅ | ✅ |
| 7 | Before replacing ... disconnect ... and wait ... | `disconnect` | ✅ | `Before` | ✅ |
| 8 | Users ... can restore ... when edit synchronized ... | `restore` | ✅ | ✅ | ✅ |
| 9 | policy applies ... even when duties ... | `applies` | ✅ | ✅ | ✅ |
| 10 | If temperature rises ... controller shuts down ... | `shuts` | `.` | `rises` | ✅ |
| **人工 root 诊断** |  |  | **8/10** | **7/10** | **10/10** |

这组结果支持把 Stanza 作为开发期独立参考，但样本只有 10 个，而且只检查中心谓词，不代表整棵
依存树准确率。它也没有解决 Flutter Windows/Android 统一打包 Python/PyTorch pipeline 的成本。

## 直观分歧案例

| 输入 | UDPipe 参考模型 | spaCy | Stanza | 工程含义 |
| --- | --- | --- | --- | --- |
| `"Go!" Alice ran toward the gate.` | 以 `Go` 为 root，把 `Alice` 误接为宾语 | 切成 `Go` / `ran` 两个 roots | 以 `ran` 为 root、`Go` 作引语补语 | 引号终止符与说话/叙述归属不能只听单一 parser |
| `Because earlier studies ... researchers designed ...` | root=`effects` | root=`measured` | root=`designed` | 无逗号前置状语从句是 parser 健康度难例 |
| `Before replacing ... disconnect ... and wait ...` | root=`disconnect` | root=`Before` | root=`disconnect` | 操作说明中的完整谓词不能被前置 marker 抢走 |
| `If the temperature rises ... controller shuts down ...` | root=`.` | root=`rises` | root=`shuts` | parser 异常必须降低健康度，不能据此生成唯一切点 |
| `"Wait." she said quietly.` | `said` 为总 root | `Wait`、`said` 分成两个 roots | `said` 为总 root | spaCy 默认分句策略与“说话人归属锁定”目标不同 |

## 标准语料指标：项目模型与官方参考

| raw-text 指标 | 项目 UDPipe EWT r2.18 模型 | UDPipe 官方 English-EWT 2.5 公布值 |
| --- | ---: | ---: |
| Word F1 | 98.96% | 98.9% |
| Sentence F1 | 85.93% | 77.4% |
| UPOS | 93.99% | 93.3% |
| UAS | 81.16% | 80.2% |
| LAS | 77.81% | 77.0% |

两列来自不同 EWT 发布版本和训练配置，只能说明项目模型没有因可再分发、自训练和端侧打包而
出现明显整体退化，不能宣传成严格击败官方模型。项目模型的文件、SHA、训练命令和 test split
均在仓库固定；详见 [Sentence parser V3 third-party notice](third_party_sentence_parser_v3.md)。

## 从历史失败基线到当前候选策略

本地历史 v3 审计曾记录：243 项固定金标仅 202 项精确一致（83.13%），41 项失败；《柳林风声》
62 章有 122 个切点需 AI/人工复核、600 个 parser 诊断问题，发布门槛为 FAIL。该报告的价值在于
证明“依存句法器直接决定切点”不可接受，而不是证明 UDPipe 没有作用。

当前 V3.3 的任务结果为：

- 本地精确命中 207/243（85.19%）；
- approved path 覆盖 243/243；
- 冻结 EWT 留出集 60/60；
- 十类困难输入候选覆盖 10/10；
- 已验收 AI 只能从候选 path ID 中选择，不能修改原文或创造切点。

改进的关键不是把本地 exact 从 202 提到 207，而是把**正确方案召回率**做到 243/243，再让硬约束
和受约束复核处理多解自然度。历史失败结果没有被删除，而是成为当前架构的反证。

## 结论与选型建议

- **追求独立句法参考质量：** Stanza 在这组困难 root probe 上最好，适合开发期对照与错误归因。
- **Python 工程管道：** spaCy 集成方便，但默认分句与引号结构需要针对任务额外处理；本组
  无标点 root probe 也并非最佳。
- **Windows/Android 统一端侧运行：** UDPipe 的原生、离线、模型可固定和低部署复杂度仍最适合
  当前 App，但只能作为软结构证据。
- **生产分句策略：** 正字句界与硬上限由代码掌握，parser 生成完整候选并标风险，AI 仅在纯标点
  无解且模型已验收时选择 path。任何 parser/AI 失败都保留可审计 fallback。
- **规则约束：** 不得把坏例词、书名、角色名或语义词表写进生产决策；这些只能作为回归样本。

因此，本项目没有把“哪个 parser 的平均分最高”误当成完整产品答案。最终选型同时考虑任务
召回、自然度、可审计性、Windows/Android 一致性、模型许可、包体和离线延迟。
