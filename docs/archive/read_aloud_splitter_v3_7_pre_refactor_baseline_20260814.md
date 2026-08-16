# ReadAloudSplitter V3.7 重构前 Git、行为与性能基线

日期：2026-08-14

用途：为完整重构提供可恢复的代码快照、逐句行为金标和同机性能对照。

禁止用途：本文件不授权数据库迁移、TTS 重建或媒体替换。

## 1. 两类基线必须分开

### 1.1 代码与性能回退基线

- 起点：`origin/main` / `v1.5.0`，commit `e264eaef76991b2a7b5199381fb0d1613aa65005`。
- 快照分支：`codex/splitter-v3-7-pre-refactor-snapshot`。
- 快照 tag：`splitter-v3.7-pre-refactor-20260814`。
- 快照 commit：以该 tag 指向的 commit 为准。
- 当前求解器源码 SHA-256：
  `6262e7ae7eaeff465b6951821e96ec7a30d88b613dd16ae3daf9f434156603d2`。
- 当前 AOT 审计程序 SHA-256：
  `59c1419d0cd057a22d5d9d5ac70b2b1938159df65125d20b2b533efb04a8f9d4`。

该快照保存重构前现有实现，包括当前括号、引语、句法闭合、1词合并、趣配音导出兼容、测试和
审计工具。重构性能回退或实现失败时，必须能直接切回该 tag；不得依赖手工反向修改。

### 1.2 代码求解金标与发布持久化金标

重构不是重新设计全书分句，但必须区分两类结果：

- 纯代码求解金标：直接从快照 commit `4c290bc` 编译 AOT 回放，同一正文和 parser 文档得到
  Alice 39章/2,081句、Willows 62章/4,668句，合计101章/6,749句；
- 发布持久化金标：Alice 与 Willows 合计101章/6,757个已发布或已审核句槽。

固定夹具分别为：

- `app/test/fixtures/read_aloud_splitter_v3_solver_oracle.json`；
- `app/test/fixtures/read_aloud_splitter_v3_published_behavior.json`。

代码求解 oracle SHA-256：`dd9fdc4dd979c9d4a996f825c329ccbf8898b17b95695ea84bc58e4a42ce4c27`；
发布持久化夹具 SHA-256：`facb55c35d2b42aa02260f307e999bf784a2596a2b2c4e210df14c48c2295c3b`。

前者用于证明新代码逐章、逐句、逐规范化边界完全匹配原求解器；后者用于证明旧文章继续读取原句槽，
不自动迁移或重做TTS。两者相差8个句槽，原因是历史审核/持久化结果与纯代码首选路径不同，不能用
发布夹具冒充代码 oracle，也不能为追平代码 oracle 而改写旧文章。

## 2. 重构前验证结果

当前快照已完成：

- `read_aloud_syntax_solver_v3_test.dart`：59/59；
- `read_aloud_splitter_v3_test.dart`：29/29，含 243 项固定 Web V3 金标；
- 分句服务、事务持久化、UDPipe 映射和正字句边界：36/36；
- TTS 内存缓存、录制导出和趣配音 singleton cue：15/15；
- 原生完整金标：243/243；
- EWT 留出集：60/60；
- Windows 原生 UDPipe 集成：通过；
- Alice/Willows 当前候选报告：101/101 章完整候选对象与缓存优化前严格等价；
- 代码求解 oracle：101章、6,749句槽已冻结；
- 发布持久化夹具：101章、6,757句槽已冻结。

全项目 `flutter analyze` 没有错误；存在 3 个与分句无关的既有 `unused_element` warning：

- `web_shell_screen.dart::_saveSunoMetadataForVersions`；
- `web_shell_screen.dart::_sunoSongUrlsForOtherArticles`；
- `song_subtitle_timeline_service.dart::_previousLineMatch`。

重构不得新增 warning。

## 3. AOT 端到端性能基线

命令使用同一 AOT 程序、同一 Alice source bundle、同一 UDPipe parser cache，串行运行；计时包含候选
生成、求解和完整 JSON 报告写出。2026-08-14 五次结果：

| 场景 | 5次耗时 ms | 中位数 | 最小 | 最大 |
|---|---|---:|---:|---:|
| Alice E02 长括号 | 30758, 18102, 22265, 37239, 33245 | 30758 | 18102 | 37239 |
| Alice E30 长引语/多候选 | 26435, 30523, 39598, 29517, 31977 | 30523 | 26435 | 39598 |

机器当时存在其它构建负载，因此绝对值只作记录。最终性能门禁必须在同一时段交替运行：

1. 本 tag 的 AOT 程序；
2. 重构后 AOT 程序；
3. 相同输入、parser cache、输出磁盘和迭代次数；
4. 比较中位数和 P95，不比较单次最好成绩。

发布条件：重构后 E02、E30 中位数均不得高于同轮旧程序中位数；若环境波动导致差异在 5% 内，
增加到 9 次复测。任一场景确认回退即阻止切换。

### 3.1 2026-08-14 整书同输入回放

独立编译快照程序与共享-DAG实验程序，串行回放同一历史 parser 文档：

| 书 | 快照 | 共享-DAG实验 | 差异 | 逐句结果 |
|---|---:|---:|---:|---|
| Alice 39章 | 281.887 s | 271.065 s | 快3.84% | 2,081/2,081完全一致 |
| Willows 62章 | 710.517 s | 716.400 s | 慢0.83% | 4,668/4,668完全一致 |
| 合计 | 992.404 s | 987.466 s | 快0.50% | 101章零差异 |

该实验在一本书回退、总收益不足1%，且增加新的状态实现，未达到“性能和简洁性同时改善”的门槛，
因此已从生产候选撤销。后续性能优化继续以本快照与6,749句代码 oracle 为门禁。

### 3.2 2026-08-14 直接删除局部修复实验（拒绝）

为验证旧引擎的约 680 行 pre-closure / 局部窗口重求解是否可以直接由现有统一评分替代，曾在隔离分支
删除第二套候选和 `_localizeIncompleteConstituentRepairs`，保留同一边界候选、路径上限与评分规则进行
全书 AOT 回放。该实验净删约697行核心代码，但不满足行为和性能门槛：

| 项目 | Alice | Willows | 合计 |
|---|---:|---:|---:|
| 与6,749句代码 oracle 不同的章节 | 7 | 22 | 29 |
| 消失的旧边界 | 12 | 37 | 49 |
| 新增边界 | 9 | 37 | 46 |
| 边界变化总数 | 21 | 74 | 95 |
| 句槽数 | 2,078（基线2,081） | 4,668（基线4,668） | 6,746（基线6,749） |

同次串行回放耗时为 Alice 269.694 秒、Willows 745.792 秒，合计1,015.486秒；相对快照记录的
992.404秒总耗时慢约2.33%，其中 Willows 慢约4.96%。这还不是严格交错基准，但行为门禁已失败，
无需继续放行。实验代码已全部撤销，生产候选仍保持 V3.7 快照行为。

结论：不能用“删除局部修复后对整句启用另一套排序”换取代码缩短；这会把局部缺陷优先级扩散到
整句。后续只能在保持相同局部语义的前提下，用一次 `SentenceFacts` 和单一 DAG 等价表达现有选择，
并同时满足逐边界 oracle 与交错性能门禁。

## 4. 全书机器报告哈希

以下大型报告保留在忽略的 `output/`，不提交 Git；哈希用于证明重构前候选对象：

| 报告 | bytes | SHA-256 |
|---|---:|---|
| Alice g1 | 13,856,374 | `34748400afcb45d9f24bc551f8c3b345781a9d326a06f3b151e057128a70ae92` |
| Alice g2 | 15,656,940 | `8191ce48d1d51f711a8fd57990655f7142b3a0e1222844258ccfbe712fad8695` |
| Alice g3 | 15,288,997 | `bc39aef7507c5ff8a8664c8d1104dbbf56f71378881718e14c88995f32a5b565` |
| Alice g4 | 13,373,647 | `04512caaf547f6fd948c738bab86cd50e59b9889ad31ca9af6b2ea1fb97382be` |
| Willows g1 | 36,356,877 | `ff83f324ae1be9319dd9f57765d1d43c8a94423e3b13ed04597ea013473a8cb3` |
| Willows g2 | 35,189,958 | `168440107256af40026956114218386bdc6605e174242ac0539b9efee6f07282` |
| Willows g3 | 37,036,037 | `ba1cd543c63de30aec932f6c2902f0848207f315e5cece1dc9f53a4e05593c8c` |
| Willows g4 | 36,875,948 | `0392d7ef0d57de53b7fa894d662e097a598240adb8e00f3182253cae8c297cdb` |

## 5. 回退方式

仅查看快照：

```powershell
git show splitter-v3.7-pre-refactor-20260814
```

在独立分支恢复整个快照：

```powershell
git switch -c codex/splitter-v3-7-rollback splitter-v3.7-pre-refactor-20260814
```

不得在含未保存工作的分支上使用 `git reset --hard`。需要放弃重构时，应新建回退分支或对重构 commit
做有审计记录的 revert。

## 6. 2026-08-15 迭代门禁与第0轮基线

项目所有者允许后续通用规则改变全书边界，但每轮必须同时报告人工不支持结果、速度和代码规模；
质量轮的不支持数量不得高于上一轮，纯性能轮必须保持切法不退化。每轮使用独立 Git 分支，失败路径
也记录在本文，禁止反复尝试。

第0轮分支为 `codex/splitter-quality-round-01-baseline`，未修改生产分句代码：

- 专项 Flutter 测试：124/124，通过率100%；其中固定历史金标243/243；
- Alice＋Willows：101章、6,749句，与V3.7代码 oracle 逐章零差异；
- 已冻结测试范围内不支持用例：0/243（0%）；这不是对6,749句的全量人工质量声明；
- 生产分句链路7个文件共6,238行；
- 删除覆盖过窄、运行接近5分钟的EWT 60句短句 holdout，并同步退出当前发布门禁；保留EWT parser
  原始精度评测与训练来源；按提交统计本轮仓库净减少165行，分句结果不变。

后续速度与质量主门禁使用 Alice＋Willows 全量回放。全书人工不支持清单必须单独建立，不能把风险
筛选数量或旧版 `unexpected` 影响分类冒充人工否决数量。

### 第2轮：评分缓存身份键（通过）

分支：`codex/splitter-quality-round-02-segment-facts-cache`。

旧实现每次比较 draft 都拼接 `ends`、boundary id 和评分开关为长字符串缓存键。新实现以 draft 对象
身份分组，并用一个整数编码 `startWord` 与三个评分开关；评分函数、候选、beam和路径排序均未改变。

- E02 三次中位数：10.514秒 → 3.276秒，提升68.8%，39句完全一致；
- E30 三次中位数：14.370秒 → 4.695秒，提升67.3%，51句完全一致；
- Willows E01＋E09：39.736秒 → 12.623秒，提升68.2%；
- Willows E30＋E32：50.028秒 → 15.555秒，提升68.9%；
- Willows E37：34.168秒 → 11.017秒，提升67.8%；
- 上述5章共366句逐句完全一致；专项测试124/124、历史金标243/243；
- 已冻结测试范围不支持用例仍为0/243（0%），本轮新增不支持切法为0；
- solver 4,081行 → 4,068行，净减13行；生产分句链路6,238行 → 6,225行。

本轮达到“切法不退化、速度显著提升、代码同时缩短”门禁，保留。全书回放延后到多项优化累计后的
候选版本，避免每次微小改动重复运行两本书。

### 第3轮：DP memo 整数状态键（拒绝）

分支：`codex/splitter-quality-round-03-integer-dp-state`。

实验把 `solve(start, hasRequiredBoundary)` 的字符串 memo key 改为整数位编码，不改变候选、评分或
路径排序。使用第2轮 AOT 程序与实验 AOT 程序交错各跑5次：

| 章节 | 第2轮中位数 | 实验中位数 | 变化 | 逐句结果 |
|---|---:|---:|---:|---|
| Alice E02 | 3.336秒 | 3.304秒 | 快0.97% | 39/39完全一致 |
| Alice E30 | 4.659秒 | 4.663秒 | 慢0.10% | 51/51完全一致 |

90句无新增不支持切法；已冻结测试范围仍为0/243（0%）。但一快一慢且幅度不足1%，无法区别于计时
噪声，也没有减少代码行，因此不满足保留门槛。生产代码已撤回到第2轮实现，本分支只保存失败记录，
禁止以后把“字符串 key 改整数 key”作为独立性能优化重复尝试。

### 第4轮：预计算区间朗读负载事实表（拒绝）

分支：`codex/splitter-quality-round-04-range-facts-table`。

实验在构造 `_SentenceScoringCacheV3` 时一次性预计算同一句内所有 `[start, end)` 区间的最大连续
无停顿词数，用扁平数组查询替代按需散列缓存。候选、评分和路径排序均未改变。使用第2轮 AOT 程序
与实验 AOT 程序交错各跑5次：

| 章节 | 第2轮中位数 | 实验中位数 | 提升 | 逐句结果 |
|---|---:|---:|---:|---|
| Alice E02 | 3.194秒 | 3.129秒 | 2.05% | 39/39完全一致 |
| Alice E30 | 4.516秒 | 4.435秒 | 1.79% | 51/51完全一致 |

90句无新增不支持切法；已冻结测试范围仍为0/243（0%）。实验使 solver 净增2行，两个压力章节的
收益均不足3%，不符合“小幅增量必须换取显著速度提升”的门禁。生产代码已撤回到第2轮实现；禁止
以后再次用完整二维区间表替代当前按需区间缓存。若未来已有单次事实构建架构，可重新测量其自然
产物，但不能把本实验原样叠加回来。

### 第5轮：短谓语/主语跨界局部守卫（拒绝）

分支：`codex/splitter-quality-round-05-short-predicate-guard`。

本轮针对 Willows E32 的错误 `18/5` 主谓断裂：

```text
Mole, who ... scanned the banks with care, | looked at him with curiosity.
```

根因是5词短尾以 `VERB` 开头，被短片段豁免误认为完整祈使句，而逗号边界审计已经记录跨越
`nsubj`。依次验证三条路径：

1. 全局删除祈使句豁免：能修复 E32，但改变 Willows E36 等正常候选；E02 中位数慢约28.9%，E30
   慢约6.25%，拒绝；
2. 把所有 `nsubj/csubj` crossing 提升为全路径不完整边界：造成 `She said | this last word`、
   `broke | on him` 等新断裂，并移动强标点结果，拒绝；
3. 仅当短尾入口恰好跨越 `nsubj/csubj` 时取消祈使句豁免：Alice E16/E35/E36/E37/E38 与 Willows
   E22/E25/E32/E36/E49/E52 代表集只改变 E32 一处，已批准的
   `Breathless and transfixed, | ... wave, | caught him ...` 保持不变；专项测试60/60通过。

第三条路径在11项已知不支持问题中修复1项，未解决数 `11/11 → 10/11`，下降9.09%；求解器净减2行。
但使用第2轮 AOT 基线与候选交错各跑3次后：

| 章节 | 第2轮中位数 | 候选中位数 | 变化 | 逐句结果 |
|---|---:|---:|---:|---|
| Alice E02 | 4.040秒 | 3.870秒 | 快4.20% | 39/39完全一致 |
| Willows E30 | 7.989秒 | 8.801秒 | 慢10.16% | 51/51完全一致 |

E30 已构成显著性能回退；同时把判定内联进现有大函数虽机械净减2行，但没有改善模块职责。按质量、
速度和结构同级门槛，本轮拒绝，生产代码撤回到第2轮。以后不得再次采用“在短片段评分时扫描整条
draft boundary 列表”的局部补丁；应在一次事实构建中直接提供边界两侧的完整性事实，再由统一评分
消费。

### Flutter 锁预检基础设施（通过）

Flutter 3.41 的 Windows 批处理在无法独占创建 `bin/cache/flutter.bat.lock` 时会无提示循环；受限环境
又不能写 SDK cache，旧命令可一直等到外层超时。现已增加公共 `tools/flutter_tool_guard.ps1` 和
`tools/run_flutter.ps1`，并让 Windows/Android 构建脚本复用同一检查：

- 每次调用前同时独占探测 `flutter.bat.lock` 与 `lockfile`，也由此验证 cache 可写；
- 检查失败约1.8秒内明确退出，不再进入无输出循环；
- 沙箱外 `--version` 约3秒成功，分句专项测试通过统一入口约20秒完成；
- 不把删除锁文件作为默认处理方式。

### 第6轮：入口边界事实与短谓语尾（拒绝）

分支：`codex/splitter-quality-round-06-fact-boundaries`。

本轮继续处理 Willows E32，但避免第5轮逐短片段扫描整条 draft 的实现。先后验证：

1. 直接按 segment index 以 O(1) 取得入口边界，把主语 crossing 传给短谓语完整性函数；代表11章仅改变
   E32，专项测试60/60通过，但3次基准 E30 中位数慢约9.9%，拒绝；
2. 在一次 `_boundaryCandidates` 构建中，使用已经计算的 `crossings` 标记“右尾不超过5词、`nsubj` /
   `csubj` 从左跨到右侧谓语”的 `incomplete_detached_short_predicate`，统一评分直接消费
   `incomplete_constituent_boundary`；不再修改短片段评分函数的入口语义。

第二条路径在 Alice E16/E35/E36/E37/E38 与 Willows E22/E25/E32/E36/E49/E52 中仍只改变 E32，
已知不支持问题 `11/11 → 10/11`，下降9.09%；求解器净增25行，专项测试60/60通过。第2轮 AOT
基线与候选交错9次的完整中位数为：

| 章节 | 第2轮中位数 | 候选中位数 | 变化 | 逐句结果 |
|---|---:|---:|---:|---|
| Alice E02 | 3.379秒 | 3.444秒 | 慢1.93% | 39/39完全一致 |
| Willows E30 | 7.861秒 | 8.240秒 | 慢4.82% | 51/51完全一致 |

两章中位数均回退，未达到“不得慢于最近接受版本”的门槛，因此拒绝并撤回生产代码。后续不得在现有
多路径/局部重求解框架上直接叠加该事实；应先缩短统一求解路径或缓存跨上下文共享的 segment facts，
再重新评估该通用边界事实是否能在总耗时不回退的前提下进入生产。

### 第7轮：评分热路径精简与短谓语边界事实复核（质量路径拒绝）

分支：`codex/splitter-quality-round-07-shared-segment-facts`。

本轮先从 `_draftScore` 热路径回收开销，再复核第6轮当时认为质量正确、但性能不合格的边界事实：

- 不再为每条 draft 分配完整 `lengths` 列表，单次遍历维护首段、最短段和最长段；
- 每句只计算一次是否存在括号上下文；
- 仅在确需括号长度修正时计算 overlap，并以首尾 anchor 直接比较，去掉每段临时 `Set`；
- 曾尝试在已有 `_boundaryCandidates` 遍历中把“右尾不超过5词且主语依存弧从左跨向右侧谓语”标为
  不完整事实；最终人工复核否定该规则，已从生产代码撤回。

拒绝并记录的中间路径：共享短片段 `Map` cache 使 E02 慢约6.6%；用 `getRange` 代替索引遍历使 E02
慢约11.1%、E30慢约7.8%。两者均已撤回，不再重复尝试。

第2轮 AOT 基线与最终候选交错各跑9次，保留全部样本和异常值，中位数如下：

| 章节 | 第2轮中位数 | 候选中位数 | 变化 | 性能门禁 |
|---|---:|---:|---:|---|
| Alice E02 | 8.544603秒 | 2.475695秒 | 快71.03% | 通过 |
| Willows E30 | 20.757094秒 | 5.411042秒 | 快73.93% | 通过 |

规则影响面不是按书全跑猜测，而是从冻结事实筛选“旧选中路径含1–5词右尾、且 crossing 含
`nsubj/csubj`”的全部位置，再用基线/候选重放命中章节。共命中 Alice E13、Willows E15/E32；Alice
E13输出不变，实际只有两处变化：

| 章节 | 旧路径 | 新路径 | 审核 |
|---|---|---|---|
| Willows E15 | `19 / 5`，尾块 `tried to look properly mournful.` | 合并为24词 | 拒绝；原逗号是自然朗读停顿，尾块允许沿用前文主语 |
| Willows E32 | `18 / 5`，尾块 `looked at him with curiosity.` | 合并为23词 | 拒绝；逗号关闭非限制性关系从句，标点切法应优先 |

这里不把“每个块都是独立语法句”设为硬目标，也不把21词以上设为强制切分。`21–24` 词按长度迫切度
与句法割裂程度共同选择，但合格原文标点可以形成共享前文主语的连续朗读块。短谓语事实造成两处错误
合并，质量路径因此拒绝，不得以性能收益掩盖规则错误。

Willows E32 经重新阅读原文后从“不支持”改判为支持旧版逗号切法，因此已知问题基数由11项校正为10项；
这属于审核口径纠正，不冒充算法修复。最终第7轮只保留零分句变化的热路径精简，并增加 E32 原文逗号
回归测试：

- Alice/Willows 代表章及规则触发章共901句，与第2轮逐句完全一致；E02/E30的9次基准样本也全部一致；
- 已知审核集合不支持数为 `10/11`，占90.91%，较此前记录的 `11/11` 少1项；减少来自规则审核纠正；
- solver 为 `+36/-17`，净增19行，以约0.47%的体积增量换取71%–74%的稳定加速；测试净增37行，
  用于钉死 E32 标点优先行为；
- 完整分句门禁132项通过、1项既有跳过；本轮两个文件定向 `flutter analyze` 零问题；全 app analyze
  仅有3个与本轮无关的既有 `unused_element` warning。

本轮性能路径通过。下一质量轮必须按最新规则把 dependency crossing 区分为“成分内部”与“完整成分
之间”；不得继续把 `nsubj/obj` 关系名本身当作不合格边界，也不得改变本轮已经验证的标点输出。

### 第8轮：终止标点引语与较长归属尾句（通过）

分支：`codex/splitter-quality-round-08-constituent-boundaries`。

本轮先验证三条更宽路径，均因扩散而撤回：

1. 把 `>20` 长度罚分整体提前到结构 warning 之前，代表集改变10处，仅3处支持，7处产生
   `fell | on his`、`able | to give`、`deep | in her` 等成分内部断裂；
2. 全局移除 `surface_nominal_coordinator_separation`，改变5处且5处均不支持，拆开
   `river | and riverside`、`shafts | and spots` 等并列名词；
3. 对所有终止标点引语无条件释放超过5词的归属尾句，虽然修复 Alice E16，但 Willows E27 先产生
   单词块 `"No!"`，再被通用1词合并错误并到 `At last he spoke.`；Willows E48 还把既有
   `too! |` 强标点改成较弱的 `barge, |`。两处均不支持。

最终通用规则只释放 `.!?…` 结束、长度为2–20词的完整引语与超过5词的单谓语归属/叙述尾句。单词
引语继续保护，避免短块合并向前扩散；超过20词的长引语继续保护既有内部边界，等待稳定局部修复窗，
不得在本轮借全窗重排处理。

从冻结边界事实筛出的44个触发章节全部回放后，实际改变10个区域：Alice E08/E11/E16/E17/E18/
E20/E24/E27/E32 与 Willows E03。10处都改为在原文问号或感叹号后的右引号处切分，没有无标点切点
或非目标边界移动；Willows E27、E48 与第7轮逐句完全一致。已知12个残留 `>20` 审核块中，Alice
E16 被修复，未支持数 `10/12 → 9/12`，占比 `83.33% → 75.00%`；本轮变化集不支持数 `0/10`。

第7轮 AOT 与本轮 AOT 交错各跑5次，中位数及逐句结果为：

| 章节 | 第7轮中位数 | 第8轮中位数 | 变化 | 逐句结果 |
|---|---:|---:|---:|---|
| Alice E02 | 2.153034秒 | 2.141255秒 | 快0.55% | 39/39完全一致 |
| Willows E30 | 4.687444秒 | 4.671659秒 | 快0.34% | 66/66完全一致 |

两项变化均在计时噪声范围，但没有性能回退。生产实现只收窄现有 attribution warning 条件，没有新增
扫描、递归、候选路径或章节特例，solver 净增4行；测试净增50行，同时覆盖2–20词释放、单词引语
保护、长引语保护和短归属尾句。完整分句门禁152项通过，两个改动 Dart 文件定向 `flutter analyze`
零问题。

### 第9轮：终止标点不受所有格表面 warning 压制（通过）

分支：`codex/splitter-quality-round-09-punctuation-windows`。

Willows E49 的已选21词块内部已有 `world! My enemies ...`，候选也已正确标为 `strongPunctuation`；但
下一词的所有格/限定结构触发 `surface_possible_antecedent_possessive_separation`，结构罚分反而让较弱的
`prison, |` 胜出。修复只让 `.!?…` 终止标点忽略这一条表面 warning；逗号、列表、归属尾句、依存
crossing、短块和其它 warning 均不改变。warning 事实仍保留在候选中供审计，不为评分重复构建事实。

冻结 Alice＋Willows 事实中共有11个同类强标点候选，分布在9章；基线/候选逐章回放仅改变3处：

| 章节 | 第8轮 | 第9轮 | 审核 |
|---|---|---|---|
| Willows E23 | `passage? Your cellar, | of course! ...` | `passage? | Your cellar, of course! ...` | 支持，问号优先 |
| Willows E49 | `world! My enemies ... prison, | encircled ...` | `world! | My enemies ... warders;` | 支持，14/15词 |
| Willows E61 | `different Toad. My friends ...` | `different Toad. | My friends ...` | 支持，恢复两个完整正字句 |

Alice 与其它6个命中章节逐句不变。本轮变化集不支持数 `0/3`；E49 修复后，已知12个残留 `>20` 审核
块的不支持数 `9/12 → 8/12`，占比 `75.00% → 66.67%`。

第8轮 AOT 与第9轮 AOT 交错各跑5次：Alice E02 中位数 `2.162750 → 2.102623` 秒，快2.78%；
Willows E30 中位数 `4.651978 → 4.588129` 秒，快1.37%；两章分别39/39、66/66逐句一致。变化在小幅
噪声区间但没有性能回退。solver 净增4行，没有新增扫描、递归或候选路径；通用回归测试保留 warning
事实，并钉死终止标点胜过该表面罚分。完整分句门禁153项通过，两个改动 Dart 文件定向
`flutter analyze` 零问题。

### 第10轮：全局提升括号开缘（拒绝）

分支：`codex/splitter-quality-round-10-parenthetical-edge`。

实验把已经存在的 `paren_edge:before_opening` 从 `emergency` 提升为短语标点，希望把 Alice E36 的
`8 / 22 / 13` 修成在完整括号前停顿。目标22词块确实消失，但全章同时发生两处不支持重排：

- 目标句删除了已合规的 `King, |`，变成17词外层片段后再切括号，违反“只修缺陷块、保留相邻边界”；
- 另一句从 `... juror (it was Bill, the Lizard) could not make out | ...` 改成
  `... juror | (it was Bill, the Lizard) could not make out ...`，把括号与外层谓语错误粘成新块。

变化集不支持数为 `2/2`，高于第9轮，实验立即失败；生产代码已完全撤回，已知残留仍为 `8/12`
（66.67%）。后续若处理该问题，必须以第9轮已选路径为稳定框架，只在22词缺陷段内部增补括号开缘，
不得让全句 DAG 重新排序；在现有局部修复函数继续堆规则也不满足结构门禁，应等待稳定窗职责模块化。

### 第11轮：单切点长句的4–5词完整 clauseComma（通过）

分支：`codex/splitter-quality-round-11-short-clause-comma`。

Willows E10 的21词句已有 `He quickened his pace,` 这一4词 `clauseComma`，但短块评分把所有4–5词逗号
块一律处罚，迫使整句 KEEP。第一版全局豁免4–5词 `clauseComma`，代表集改变16处；虽然多数切法本身
可接受，却把已钉死的 `"Onion-sauce! Onion-sauce!" |` 强标点改成较弱的5词逗号，并在 Alice E08
等多边界长窗移动原有冒号/逗号，违反稳定边界约束，故撤回。

最终规则只在原正字句总长超过20词、候选路径恰好只有一个切点时，豁免4–5词完整 `clauseComma` 的
短块罚分。17–20词句、多边界长窗、歧义/列表逗号、2–3词块和无标点边界不变。实现直接消费 draft
已有边界事实，未增加扫描、递归、修复窗或第二套评分。

按精确可触发条件筛出 Alice 6章、Willows 16章回放，实际改变8处且全部支持：Alice E18；Willows
E05/E09/E10/E38/E45/E51/E61。每处都以原文 `clauseComma` 替换既有无标点切点；Alice 其余5章、
Willows 其余9章逐句不变，Onion 强标点负例也由专项测试钉死。本轮变化集不支持数 `0/8`；E10 修复
后，已知12个残留 `>20` 审核块的不支持数 `8/12 → 7/12`，占比 `66.67% → 58.33%`。

第9轮 AOT 与第11轮最终 AOT 交错各跑5次：Alice E02 中位数 `2.120889 → 2.107487` 秒，快0.63%；
Willows E30 中位数 `4.698377 → 4.686954` 秒，快0.24%；两章分别39/39、66/66逐句一致，计时在噪声
区间但没有回退。solver 净增8行，新增通用正例测试32行。
完整分句门禁154项通过，两个改动 Dart 文件定向 `flutter analyze` 零问题。

### 第12轮：稳定标点框架内的4–5词 clauseComma（通过）

分支：`codex/splitter-quality-round-12-punctuation-replacement`。

本轮处理 Alice E11：旧路径在无标点的 `mind | and was coming` 切分；原文更自然的停顿是
`and she looked up eagerly, | half hoping ...`。规则把第11轮“单切点长句”的4–5词完整
`clauseComma` 豁免扩展到多边界长窗，但只允许入口已经是已选原文标点、当前短块也结束于
`clauseComma` 的局部情况。

第一版扩展在 Willows E46 把 `ma'am; | and I've lost ...` 的分号边界移到后续逗号，属于标点强度
降级，未通过。最终实现增加通用护栏：若入口标点至当前逗号之间跨过句号、分号、冒号或破折号，短块
豁免失效。E46 因此与第11轮逐句一致；没有书名、章节号、单词或完整句子特例。

代表集和按触发事实抽取的扩展压力集共34章，最终只改变7处，全部使用原文标点且均支持：Alice
E11/E38；Willows E10/E19/E43/E44/E57。Alice E11 明确缺陷由1项降为0项；既有12个长块审核集合
仍为 `7/12`，因此合并口径的已知不支持项由8项降为7项。本轮未改变括号残留集合，也没有影响
Willows E01 Onion 强标点和 E46 分号负例。

实现只在现有短片段评分中、确实命中多边界4–5词 `clauseComma` 时定位相邻边界；强标点前缀事实按需
构建一次并缓存，不在每条路径重复扫描。它不增加递归、候选路径、UDPipe 调用或第二套求解。最初把
文本正则扫描放进热循环的版本造成 E02/E30 约32%/11%回退，已拒绝并替换；最终与第11轮交错5次，
Alice E02 中位数 `2.150465 → 2.152566` 秒（慢0.10%），Willows E30 `4.600663 → 4.687305` 秒
（慢1.88%），属于小幅噪声区间。新增正例钉死稳定标点框架内的 E11 型切法，负例钉死不得跨越更强
标点；完整分句门禁156项通过，两个改动 Dart 文件定向 `flutter analyze` 零问题。

### 第13轮：共享主语并列谓语 crossing 全局降级（拒绝）

分支：`codex/splitter-quality-round-13-unpunctuated-constituents`。

目标是把 Willows E22 的22词块在 `... beguile his spirits back | and make ...` 处分开。冻结 UDPipe
事实把 `make` 错接到后方 `seem`，同时让 `who` 的 `nsubj` 跨过目标边界；实验尝试在“右侧明确为
`and + VERB`、没有自有主语、左侧16词内已有谓语”时，把继承主语 crossing 从紧密成分处罚中扣除。

仅降低 crossing 风险不能改变 E22 目标路径；进一步取消旧回退路径对 subjectless coordinated
predicate 的统一降级后，目标仍未改变，却在同章新增：

`Poor Mole ... between the upheavals | of his chest ...`

这切开名词与介词补语，并把原2块重排成3块，违反“不能切进主语/谓语/宾语/表语及其紧密补语内部”
和“只修目标缺陷边界”。因此本轮变化集不支持数为 `1/1`，实验 solver 与临时诊断报告字段全部撤回；
生产结果、已知不支持项和第12轮性能均不变。后续若处理共享主语并列谓语，必须把许可建模为单个边界
事实，而不能放宽 pre-closure 回退窗的整体候选分类。

### 第14轮：共享主语并列谓语单边界提升（拒绝）

分支：`codex/splitter-quality-round-14-shared-predicate-boundary`。

本轮遵循第13轮结论，不再放宽整个 pre-closure 窗，而只把满足下列事实的单个无标点边界提升为
`dependencyClause`：右侧由 `CCONJ` 的依存 head 指向5词内 `VERB/conj`，右谓语没有自有主语，
左侧16词内已有谓语；评分只扣除该边界继承的 `nsubj/csubj` crossing，其它保护关系不变。

Willows E22/E25 定向重放表明两处目标均未改善；E22 反而把原来的2块重排为：

`Poor Mole ... between the upheavals | of his chest ... held back speech | and choked it as it came.`

新增 `upheavals | of his chest` 明确切开名词及其介词补语。本轮变化1处，不支持数 `1/1（100%）`；
最近接受基线仍为 `7/12（58.33%）`，因此失败。实验代码全部撤回。结论是：仅把正确单边界加入旧全局
排序仍会触发相邻边界重排；处理这类问题必须先让求解器在稳定段内“只增补一个切点”，不能继续扩大
候选分类或复用会重排整窗的 `_rankRangeDrafts`。

### 第15轮：长开引语前归属语逗号全局释放（拒绝）

分支：`codex/splitter-quality-round-15-attribution-opening-quote`。

目标是 Willows E30 的 `observed ... cheerfully, | "the only difficulty ...`。实验把“前置归属语至少6词、
后方引语超过20词”的 `quote_edge:before_opening` 原文逗号从保护 gap 提升为 `phraseComma`，并尝试在
含该候选的路径中阻止较弱边界跨过已有强标点。称谓缩写 `Mr.` 一度被当成强标点产生
`Mr. | Clerk`，复用既有 `_nonTerminalTitleAbbreviation` 后已消除。

23个长开引语压力章节中实际改变8章。E30 目标修复，分号/句号层级也更合理；但 Alice E03 把已合规
的 `Australia?" | (and she tried ...)` 问号边界移到后方破折号。变化集至少 `1/8（12.5%）` 不支持；
修复1项同时新增1项，整体已知不支持仍为7，没有严格少于最近接受版本 `7/12（58.33%）`，因此失败，
实验代码全部撤回。

结论：候选一旦进入旧全局 DAG，即使增加“强标点不得被弱标点越过”仍可能在两个强标点之间重排整段。
后续应先用最近接受路径固定所有边界，只在其 `>20` 的单个稳定段内部插入新标点；不能让新候选参与
原句全局初次排序。

### 第16轮：稳定段内增补长开引语前归属语逗号（通过）

分支：`codex/splitter-quality-round-16-stable-segment-punctuation`。

本轮继续处理 Willows E30，但不再把新逗号送入整句全局 DAG。长开引语前的归属语逗号先保持旧
`emergency` 身份，旧候选格和旧路径完全不变；只有最近接受路径的某一段仍 `>20` 词、逗号两侧均
至少6词时，才把该候选局部提升为 `phraseComma` 并只增加这一个边界。实现用
`, + opening quote` 句面事实预筛，普通原句不进入局部检查，空候选使用惰性 iterable，不分配 List。
这是统一 DAG 重构前的受控兼容机制，最终必须吸收到一次事实构建和一次有界求解，不能长期并存为
第二套求解器。

按可触发事实和历史压力输入回放 Alice 11章、Willows 12章，最终只改变 Willows E30 一处：

```text
旧：observed the Chairman of the Bench of Magistrates cheerfully, "the only difficulty ... case is,
新：observed the Chairman of the Bench of Magistrates cheerfully, |
    "the only difficulty ... case is,
```

其余22章逐句一致，E30 其它边界不动。变化集不支持数 `0/1（0%）`；已知12个残留 `>20` 审核块
由 `7/12（58.33%）` 降为 `6/12（50.00%）`。删除延迟候选再求全局路径的精简实验曾造成5章重排，
已拒绝；这证明未选中的候选也是旧闭包修复的稳定事实，不能为省代码直接删格点。

与第12轮接受 AOT 交错5次：Alice E02 中位数 `2.112810 → 2.158030` 秒（慢2.14%），Willows E30
`4.710549 → 4.650947` 秒（快1.27%）；两项合计中位数快约0.21%，方向不一致且样本区间重叠，
判为无显著回退。生产 solver 净增约103行，主要是后续共享谓语等缺陷可复用的稳定段只增边界机制；
该结构增量只有在继续降低不支持数并最终被统一 DAG 吸收的前提下接受。

### 第17轮：稳定段内增补共享主语并列谓语边界（通过）

分支：`codex/splitter-quality-round-17-stable-shared-predicate`。

第13/14轮已证明，把共享主语 crossing 全局降级或把单候选直接送入全句 DAG 都会诱发
`upheavals | of his chest`。本轮复用第16轮的稳定段只增边界机制：初次求解完全不变；仅当旧路径仍
留下 `>20` 词段、协调连词的 dependency `cc` head 在右侧5词内落到 `VERB/AUX`、右谓语没有自身
主语、左侧16词内已有谓语且两侧均至少6词时，局部增加协调连词前边界。UDPipe 把 E22 的 `make`
错误接到后方 `seem`，因此兼容事实以协调连词的 head 定位右谓语，不要求该谓语的 head 必须在左侧；
E25 的 `and could always be counted` 同样由 `and -> counted` 的依存事实覆盖。没有书名、章节号、
完整句子或词语白名单。

23章压力集加 Willows E37 固定回归共24章，只改变三处，均受支持：

```text
Willows E22: ... endeavoured to beguile his spirits back | and make the weary way seem shorter.
Willows E25: these things which were so glad to see him again | and could always be counted upon ...
Willows E37: that Toad ... practically completed the matter | and left little further to discuss.
```

E22 为15/7，E25 为11/10，E37 为15/6；旧错误邻域仍保持
`upheavals of his chest that followed one | upon another`，没有出现 `upheavals | of his chest`。变化集
不支持数 `0/3（0%）`；已知12个残留 `>20` 审核块由 `6/12（50.00%）` 降为
`4/12（33.33%）`，并另行修复此前被过时单测错误钉成 KEEP 的 E37 共享谓语尾段。

与第16轮 AOT 交错5次：Alice E02 `2.132782 → 2.163879` 秒（慢1.46%），Willows E30
`4.685680 → 4.669340` 秒（快0.35%），Willows E22 `1.769963 → 1.817413` 秒（慢2.68%）；三项
合计中位数慢约0.72%，各样本区间重叠且方向不一致，无显著回退。生产 solver 净增约80行，新增
依存事实判断，同时把第16轮专用候选提升重构为共用重分类函数，未增加递归、第二次整句 DAG 或书本
特例。

### 第18轮：稳定段内增补左括号开缘（通过）

分支：`codex/splitter-quality-round-18-parenthetical-stable-edge`。

第10轮已经证明，全局提升 `paren_edge:before_opening` 会删除 Alice E36 前方已经合规的 `King, |`，
并把短括号错误剥离为 `juror | (it was Bill, the Lizard) could not make out ...`。本轮不改变初次
候选排序，只复用第16轮以来的稳定段单边界增补：既有路径仍留下 `>20` 词块、括号 span 至少6词且
左括号前切分后两侧均至少6词时，才把该开缘提升为 `phraseComma`。短括号不进入该路径。

Alice 11章与 Willows 12章压力集共23章，仅 Alice E36 改变一处：

```text
旧（22词）：and as he wore his crown over the wig (look at the frontispiece if you want to see how he did it),
新（9/13）：and as he wore his crown over the wig |
           (look at the frontispiece if you want to see how he did it),
```

前方 `The judge, by the way, was the King, |`、后方13词块以及 `Bill, the Lizard` 句全部不动；Willows
12章逐句完全一致。变化集不支持数 `0/1（0%）`，已知12个残留 `>20` 审核块由
`4/12（33.33%）` 降为 `3/12（25.00%）`。生产求解器净增17行，没有新增扫描、递归、第二次整句
DAG、书名或句子特例；该兼容路径仍须在统一事实表和单次有界求解重构中吸收。

与第17轮 AOT 交错5次：Alice E02 `2.236 → 2.135` 秒（快4.53%），Alice E36
`2.751 → 2.731` 秒（快0.73%），Willows E30 `4.749 → 4.669` 秒（快1.69%）。三项均无回退，
其中非目标 E02/E30 逐句完全一致；完整分句门禁139项执行通过、2项按环境开关跳过，两个改动 Dart
文件定向 `flutter analyze` 零问题。

### 第19轮：稳定段右侧完整从句与单候选裁决（通过）

分支：`codex/splitter-quality-round-19-long-coordinate-comma`。

本轮处理两个无原文标点残留：Willows E10 的21词时间从句块，以及 E36 的23词时间修饰块。通用事实
要求边界右侧入口 token 为 `mark/advmod`，其 dependency head 在5词内指向 `VERB/AUX`，或带
`cop` 的 `ADJ/NOUN/PROPN` 谓语，并且该谓语拥有右侧显式主语。只有既有稳定块仍 `>20` 且两侧
至少6词时才局部增补，不让新候选参与全句初次排序。

首版压力回放发现 Alice E36 的同一22词稳定块同时加入左括号和括号内 `if` 两个候选，产生4词碎片。
这暴露的是第16轮以来稳定段机制的通用缺口。最终实现规定每个 `21–30` 词稳定块只选一个新增边界：
原文标点/括号开缘优先，句法边界次之，同级按两侧长度均衡选择。Alice E36 因此继续保持 Round 18
的9/13括号边界，括号内部不再变化。

Alice 11章、Willows 13章共24章压力集最终仅改变两个已知残留：

```text
Willows E10（21 → 13/8）:
and so intimately into the insides of things as on that winter day |
when Nature was deep in her annual slumber

Willows E36（23 → 6/17）:
and the fun they had there |
when the other animals were gathered round the table and Toad was at his best, singing songs,
```

变化集不支持数 `0/2（0%）`；已知12个残留 `>20` 审核块由 `3/12（25.00%）` 降为
`1/12（8.33%）`。新增检查复用既有右侧主谓从句判断，只在入口确有 `mark/advmod` 时读取谓语事实；
没有新增递归、第二次整句 DAG、书名或句子特例。完整分句门禁140项执行通过、2项按环境开关跳过，
两个改动 Dart 文件定向 `flutter analyze` 零问题。

性能试验同时拒绝了两种实现：多次扫描依存列表的首版，以及把可选参数塞入所有普通边界都会调用的
既有 helper 的精简版；后者代码少约20行，但 E02/E30 中位数慢约2.5%。最终把延迟从句事实隔离到
冷路径，普通 helper 保持原样。与第18轮 AOT 交错5次：Alice E02 `2.141 → 2.131` 秒（快0.45%），
Willows E10 `2.795 → 2.792` 秒（快0.11%），Willows E30 `4.630 → 4.675` 秒（慢0.96%）；区间
重叠且合计无显著回退。生产 solver 净增79行，其中包含“每稳定块只选一个候选”的通用缺陷修复，
不是第二套求解器。

### 第20轮：稳定段关系从句前缘（通过）

分支：`codex/splitter-quality-round-20-relative-clause-front`。

最后一个已知残留是 Willows E30 的24词无标点块。UDPipe 把 `whom` 错挂为左侧 `ruffian` 的
`nsubj`，但紧邻下一词位又把 `see` 标为以 `whom` 为 head 的完整 `acl:relcl`。现有候选因此同时
给出“名词｜关系代词”软事实和下一词位的完整关系从句事实。本轮只在两者相邻共现时，把关系代词前缘
加入稳定段候选；不新增关系词表、不重新扫描依存树，也不让候选进入全句初次排序。

结果：

```text
旧（24词）：how we can possibly make it sufficiently hot for the incorrigible rogue and hardened ruffian whom we see cowering in the dock before us.
新（15/9）：how we can possibly make it sufficiently hot for the incorrigible rogue and hardened ruffian |
            whom we see cowering in the dock before us.
```

24章压力集仅此一处变化，变化集不支持数 `0/1（0%）`；已知12个残留 `>20` 审核块由
`1/12（8.33%）` 降为 `0/12（0%）`。随后用完全相同的冻结源分别回放 Round 19 与 Round 20：
Alice 39章 `0/39` 变化，Willows 62章仅 E30 `1/62` 变化，证明规则没有扩散到其它章节。旧 V3.7
金标对部分 Willows 章节使用不同文本版本，故只用于累计历史差异清单，不把 source hash 不同的 offset
漂移计作本轮算法回归。

最终 AOT 与 Round 19 交错5次：Alice E02 `2.180 → 2.127` 秒（快2.43%），Willows E30
`4.605 → 4.593` 秒（快0.26%），均无性能回退。完整分句门禁141项执行通过、2项按环境开关跳过，
两个改动 Dart 文件定向 `flutter analyze` 零问题，`git diff --check` 通过。生产 solver 净增25行，
只复用相邻候选事实和既有稳定段单候选裁决，没有增加 dependency 扫描、递归或第二套 DAG。
