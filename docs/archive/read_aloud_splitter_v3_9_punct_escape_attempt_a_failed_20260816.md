# 失败记录：Attempt A 标点逃逸计费（未接受，已撤回）

日期：2026-08-16  
基线：**已确认** `syntax_solver_v3_9`  
**未升版本号**（试验代码已撤回；其间曾误用 v3.10 标签，已废弃）

## 目标

Willows E13 对齐 DB：`…little door, | painted a dark green.`  
拒绝：`seemed | to be` 及任何未回到门边逗号的切法。

## 假设（已证伪为可合入方案）

对「句法收尾且右侧 ≤17 词袋内埋着可用逗号」的段加 `skippedPunctuation`（反逃逸），
即可在不硬拦紧密词隙的前提下落实 `R-PUNCT-FIRST`，并让 E13 选中门边逗号。

## 实际做法

在 `_additiveSegmentScoreV3` 增加 `_escapedPunctuationAfterSyntaxCutV3`：

- 仅句法收尾；
- `sourceWordCount - start > 17`；
- 右侧袋长 `<=17`；
- 只看袋内**最近**一处停顿，且仅 `clause/phrase/ambiguous` 逗号（忽略 `;`/:` 以免误伤 E43 `memories | by`）；
- 切点后右侧 `<4` 词视为不可用标点，不计费。

曾试左侧长度门限（`<8` / `<=8`）以压扩散：E13 会改切到 `seemed to | be` 或 `snow-bank | stood`，门边逗号仍达不到，已放弃。

## 代表集对比（相对当时工作区回放，基线仍为 v3.9）

| 范围 | 结果 |
|---|---|
| Alice 10 章 | 0 原句变化（相对 candle 试验态）时有过扩散变体 |
| Willows 10 章 | 曾出现 **E26 `seemed to \| be`** 等不可接受扩散 |

### 不可接受的扩散

Willows E26 开篇第三刀变为 `…seemed to | be pulling…`，与要消灭的 `R-SYNTAX-LOCATION` 同类，**不支持切法未降反升**，按工程规则直接否决。

## 夹具保留

- `app/test/fixtures/read_aloud_splitter_v3_trailing_postmod_door.json`（E13 定点，属 v3.9 试验夹具）

## 结论与禁令

- **拒绝** Attempt A；版本号保持 **`syntax_solver_v3_9`**。
- **禁止**再靠「右侧短袋埋逗号 → 段级 skippedPunctuation 加罚」修 E13。
- **禁止**未确认接受就递增 `solverVersion`（勿再误标 v3.10 / v3.11）。
