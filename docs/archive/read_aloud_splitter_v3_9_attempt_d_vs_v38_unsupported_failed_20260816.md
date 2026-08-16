# 失败记录：Attempt D 尾随后修饰豁免 + 相对 v3.8 不支持切法门禁（未接受，已撤回 D）

日期：2026-08-16  
基线：**已确认** `syntax_solver_v3_9`（版本号保持；不升 v3.10）  
对照：已提交全书 `syntax_solver_v3_8`（R8n16）

## 触发

相对 v3.8 全书差异裁决：新侧是否含规范不支持切法。  
产物：`output/sentence-split-v3/current-v39-patches-vs-v38-r8n16-20260816/UNSUPPORTED_CUT_ADJUDICATION.md`

## 裁决（门禁 FAIL）

启发式可疑池 45（右缘 to/about/up/… 且 v3.8 无同刀）中：

| 类 | 数量 | 处理 |
|---|---:|---|
| 左块以原文停顿收尾（多为 `R-PUNCT-FIRST`） | 19 | 不按紧密附着误切计 |
| 无标点切入 to/about/up/… | 12 | 进入 `R-SYNTAX-LOCATION` |
| 截断视图无法定位 | 14 | 未升格 |

**已确认不支持（必须否决本轮候选）：**

1. Alice E17 `bend | about` — `R-SYNTAX-LOCATION`；人工已裁 DB KEEP；v3.8 亦 KEEP  
2. Willows E16 `legs | up` — 同上  

**高置信可疑：** Willows E62 `used | to`（`used to be` 固定附着）

说明：上述误切主要来自 **v3.9 相对 v3.8 的整包差异**，不是 candle 单独引入。  
candle（`closesAtCommaPause` 免除 17–20 弹性加罚）使 Alice E05 与 v3.8 对齐，且曾按标点优先做过代表章审核，**保留**。

## Attempt D（已撤回）

### 假设

§8.2 把句末逗号后 4–5 词后修饰当作完整功能块豁免，即可让 Willows E13 选中 `door, | painted`。

### 做法

用 `isTrailingPunctBoundedPostModifier` 替换基线 `isFlexibleSourceCompleteShortTail`。

### 结果

- E13 门边逗号可对齐 v3.8/DB，但 **E17 / E16 仍为不支持切法**  
- 相对 v3.8 的不支持切法门禁未过 → 整轮候选失败  
- 按工程规则撤回 D，恢复 `isFlexibleSourceCompleteShortTail`  
- 撤回后定点：`punct_first_candle` 仍过；`trailing_postmod_door` 在当前 candle+v3.9 状态下仍过（说明对本夹具 D 非必要，但不能证明 E16/E17 已修）

## 禁令（避免重试同类手法）

- 禁止再靠「仅放宽句末 4–5 词短块豁免 / 替换 flexible short tail」指望顺带消掉 `bend | about` / `legs | up`  
- 禁止再试：紧密附着硬拦层叠（见 `read_aloud_splitter_v3_9_tight_constituent_hardblock_failed_20260816.md`）  
- 禁止再试：Attempt A 右侧短袋 `skippedPunctuation` 反逃逸  
- 禁止未接受就递增 `solverVersion`

## 仍保留

- `closesAtCommaPause` → 免除逗号收尾块的 `elasticOverload`（candle / `R-PUNCT-FIRST`）  
- 版本字符串：`syntax_solver_v3_9`  
- 试验夹具可留作下一轮定点：`read_aloud_splitter_v3_trailing_postmod_door.json`（当前期望在撤回 D 后会再次失败，属预期）

## 下一轮必须先定点说明

在不动硬拦 / Attempt A / Attempt D 的前提下，如何让：

1. E17 末段 KEEP（或等价 DB，且无 `bend | about`）  
2. E16 无 `legs | up`，并回到 DB 的 `study |` / `face, |` 路径  
3. E13 仍选中 `door, | painted`（需新机制，不再用 D）

代表句回归通过后再扩范围，并相对 **v3.9 干净基线** 查扩散，相对 **v3.8** 复核不支持切法是否减少。
