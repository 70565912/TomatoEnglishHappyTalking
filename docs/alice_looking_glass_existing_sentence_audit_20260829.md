# 已作废：《爱丽丝镜中奇遇记》现有分句复核 · Tomato 算法交接（2026-08-29）

> 本文档及其算法建议已作废。C14–C53 应以
> `docs/alice_looking_glass_later_unmodified_audit_20260829.md` 为准；不得再以本文档作为算法修改或
> 人工裁决依据。保留本文档仅用于追溯历史审核过程。

## 范围和证据边界

- 书籍：Tomato `story_series.id=33`，C01–C53，3,252 个当前持久化句槽。
- 当前版本：53 章均为 `reviewed_dp_v3`。
- 本轮按用户要求没有重新运行 UDPipe 或 v3.9；证据来自当前数据库、2026-08-22 本地定稿、保存的 v3.9 报告和后续数据库人工修改。
- 本轮不修改生产算法。这里同时记录“本书采用什么边界”和“生产算法如何处置”，两者不可互相替代。
- 2026-08-22 的 17 个既有案例继续见 `docs/alice_looking_glass_v39_sentence_split_audit_20260822.md`；本文件只补充当前数据库人工修正带来的新证据和状态变化。

## 1. 重复短感叹句被切进同一个引语内部

### 复现 A · C07-054/C07-055

- 原切分：`‘I never saw such a house for getting in the way! | Never!’However, there was the hill full in sight,`
- 当前人工修正：`‘I never saw such a house for getting in the way! Never!’ | However, there was the hill full in sight,`
- 规则：`R-PUNCT-FIRST`、`R-DELIMITER-EDGE`、`R-SHORT-FRAGMENT`
- 本书决定：采用当前数据库修正。
- 算法处置：评估通用修正；完整引语以重复的短感叹结尾时，不能只因第一个 `!` 是强标点就切开引语，并把第二个感叹句粘到后续叙述。

### 复现 B · C11 两处 Faster

- 原切分 1：`and still the Queen kept crying ‘Faster! | Faster!’, but Alice felt she could not go faster,`
- 建议切分 1：`and still the Queen kept crying ‘Faster! Faster!’, | but Alice felt she could not go faster,`
- 原切分 2：`and still the Queen cried ‘Faster! | Faster!’, and dragged her along.`
- 建议切分 2：`and still the Queen cried ‘Faster! Faster!’, | and dragged her along.`
- 本书决定：采用当前数据库修正。
- 算法处置：与 C07 使用同一通用机制，不增加 `Never`、`Faster` 或书名白名单。

### 最小正反例

- 正例：`she cried ‘Run! Run!’, | but he did not move.` 应保留完整重复引语。
- 正例：`‘Never! Never!’ | Then she turned away.` 应在右引号后切。
- 负例：两个独立说话人的 `‘Stop!’ | ‘Run!’` 仍允许在引语之间切。
- 负例：长引语超过长度区间时，仍须按真实标点和结构边缘继续求解，不能一律整段 KEEP。

## 2. 左右引号被分配到错误句槽

### 当前数据库人工修正证据 · C11-026 至 C11-030

- 原有结构把下一个说话人的左引号留在前槽。
- 建议结构：`and dragged her along. | ‘Are we nearly there?’ | Alice managed to pant out at last. | ‘Nearly there!’ the Queen repeated. | ‘Why, we passed it ten minutes ago! Faster!’`
- 当前人工修正大体采用了建议结构，但 C11-029 末尾仍保留一个左单引号，而 C11-030 已经以左单引号开始，造成重复字符。
- 规则：`R-FIDELITY`、`R-DELIMITER-EDGE`、`R-SYNTAX-LOCATION`。
- 本书决定：保留当前结构，另行删除 C11-029 末尾多余的左单引号。
- 算法处置：边界移动必须保持字符只出现一次；右引号归左侧内容，左引号归后续引语，新增/删除边界不得复制或吞掉 delimiter。

### 同机制复现窗

以下句槽均由 2026-08-22 本地定稿标记为 `tomato_v3_local`，不是本轮凭空构造：

- 右引号落到右槽：C08-030、C14-036、C16-020、C24-011、C30-036、C32-033、C33-032、C43-042、C44-015。
- 左引号落到左槽：C08-030、C09-006、C10-029、C26-047、C31-051、C32-058、C33-032、C33-043。
- C10-029 与旧案例 V39-010 机制重叠；合并回归即可，不应重复制造书籍专用规则。

### 最小回归要求

1. `... words.’ | ‘Next speaker ...`：右引号只在左槽，左引号只在右槽。
2. `... words.’ she said. | ‘Next sentence ...`：提示语与前一引语可同槽，但下一左引号不得留在左槽。
3. `... word.’‘Next ...`：即使源文本两个弯引号相邻且无空格，也能识别 close/open 两个方向，不把它们配成同一 delimiter。
4. `’Twas brillig`：词首省略号不是未配对的右引号，不能误移。
5. 英文缩写和所有格（`don't`、`King's`）不得参与引号配对。
6. 边界重排前后，正文字符序列必须完全一致；每个 delimiter 恰好出现一次。

## 3. C12 既有案例 V39-003 的本书决定更新

- 旧切分：`Alice thought it would not be civil to say | ‘No,’ though it wasn't at all what she wanted.`
- 当前数据库：`Alice thought it would not be civil to say ‘No,’ | though it wasn't at all what she wanted.`
- 规则：`R-PUNCT-FIRST`、`R-SYNTAX-LOCATION`。
- 变化：2026-08-22 审核表曾选择保留 v3.9；用户后来在数据库中采用了建议切分，因此本书最终决定应以当前数据库为准。
- 算法处置：本文件只更新书籍决定状态，不在本轮授权修改生产算法。

## 4. 相邻独立说话人 · C32-051

- 当前：`and a long way behind it’‘And a long way beyond it on each side,’ Alice added.`
- 建议：`and a long way behind it’ | ‘And a long way beyond it on each side,’ Alice added.`
- 规则：`R-DELIMITER-EDGE`、`R-LENGTH-ZONES`。
- 本书决定：倾向按说话人分开。
- 算法处置：作为通用可行性候选；先验证相邻独立引语识别，不增加章节或角色白名单。

## 5. 不应升级为算法缺陷的项目

- C10-004/C10-005：当前切在 `directions, | and explained`，比旧切法更自然，但两个位置都有原文逗号，本例只记本书偏好。
- C05-001：补回章首左引号属于源正文保真修正，不是分句算法修正。
- 全章字符级检查召回 114 个“16 词以内引号内有边界”提示，但该检测跨越 Tomato 的正字句阶段，不能与 solver 的 `shortQuoteInternalSelectedCount` 直接等同；保存的 v3.9 报告该值为 0。因此 114 只用于召回，不计为 114 个缺陷。
- 中文标点、语义重分配和 `brillig` 译名一致性只记录在绘本工作区，不进入生产分句缺陷清单。

## 6. 建议回归集合

- 覆盖 C07、C11 的同说话人重复感叹；C08/C09/C16/C24/C26/C30/C31/C32/C33/C43/C44 的左右引号归属；C12 的短直接引语宾语；C32 的相邻说话人。
- 必须同时包含普通单句对白、嵌套双引号术语、相邻独立对白、词首省略号、英文缩写、未闭合引号和长引语负例。
- 验收至少包括：正文字符序列不变、无重复/遗漏 delimiter、无 `>30` 词句槽、本书决定与算法处置字段不缺失。

## 7. 书籍侧证据

- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\database-current-audit-20260829\algorithm-defect-review.json`
- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\database-current-audit-20260829\分句审计报告.md`
- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\database-current-audit-20260829\source\manual-correction-candidates.json`
- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\database-current-audit-20260829\reviewed\sentence-risk-dispositions.json`
