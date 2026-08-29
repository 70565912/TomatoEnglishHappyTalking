# 《爱丽丝镜中奇遇记》C14–C53 现有句槽补充审核 · Tomato 交接（2026-08-29）

## 证据边界

- 范围：C14–C53，2,530 个当前持久化 `reviewed_dp_v3` 句槽。
- 按用户要求没有重新运行 v3.9；本文件复核当前既有句槽。
- 本轮不修改生产算法。中文问题和源正文错误只留在绘本工作区。


## 数据库应用状态

- 已按本次审核结论写入 Tomato：C14–C53 为 2,530 槽，全书为 3,252 槽。
- 已纠正旧报告对 C32/C52 的规则误判：2,527 → 2,530 槽，只回退这两项错误决定。
- C26 最终：`but I'll tell you what—’ she added, as a sudden thought struck her. | ‘I'll follow it up ...`
- 精确回读 40/40 章；SQLite 完整性 `ok`；非目标逻辑数据变化 0。
- 本次仍未修改生产算法；下列内容是后续算法会话的回归输入。

## 1. quote-edge 规则确认

审核快照在 C14、C16、C24、C30、C31、C32、C33、C43、C44 发现右引号落到右槽或左引号落到左槽的实例。本书决定统一为：右引号随左侧内容，左引号随后续引语。书籍侧数据库现已应用这些决定。

- 本书决定：采用建议切分。
- 生产算法处置：评估最小修正；复用 `docs/alice_looking_glass_existing_sentence_audit_20260829.md` 的 `ALG-EDGE-001`，不新增书名白名单。
- 回归要求：覆盖嵌套引号、相邻两个说话人、`’Twas`、缩写和所有格；字符不得重复或丢失。

## 2. 相邻说话人边界

### C14-024/C14-025

- 当前：`saying ‘She must go by post, | as she's got a head on her’ ‘She must be sent as a message by the telegraph’`
- 建议：`saying ‘She must go by post, as she's got a head on her’ | ‘She must be sent as a message by the telegraph’`
- 本书决定：采用建议切分。
- 生产算法处置：评估通用可行性；先合并同一说话回合的尾部，再在 close/open 引号之间切开。

### C32-050/C32-051

- 当前：`It's called “wabe,” ... before it, | and a long way behind it’‘And a long way beyond it on each side,’ Alice added.`
- 正确：`It's called “wabe,” ... before it, | and a long way behind it’ | ‘And a long way beyond it on each side,’ Alice added.`
- 正确词数：`13 | 6 | 12`，不得移除 `before it, |` 这一现有逗号边界。
- 本书决定：保留逗号后的边界，并在 Alice 的新说话回合前再切开。
- 生产算法处置：统一 delimiter scanner 必须保留现有逗号边界，并新增 close/open 说话回合边界。
  6 词完整尾部不属于 1–3 词禁区；旧审核把它误判成碎片。

C29-067/C29-068 的同类问题在旧本地结果中已经标成 `manual_review`，只做本书边界修正，不单独作为生产算法证据。

## 3. C52 长度与标点规则的负向回归例

- 当前：`just in time to see ... grinning at her for a moment | over the edge of the tureen, | before she disappeared into the soup.`
- 正确：保持现有 `16 | 6 | 6` 三槽不变。
- 本书决定：保留当前切分。
- 生产算法处置：不修改算法。28 词合并块虽然未超过 30 词硬上限，但有逗号且超过 20 词，违反 `R-LENGTH-ZONES` 和 `R-PUNCT-FIRST`；该例用于防止审核层错误绕过既有规则。

## 4. 不属于算法缺陷

- C23/C24 的 `adressing`、C26 的 `what'she`、C31 的 `glory”doesn't`、C44 的重复左引号属于源正文保真问题。
- 116 组中文右引号归属和 18 组中文语义/双关问题属于翻译对齐，不进入英文分句算法。
- 34 个短对白、说话人提示或诗歌节奏块复核后保留，不因“短”自动合并。

## 5. 书籍侧证据

- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\later-unmodified-chapters-audit-20260829\后续章节规则审核报告.md`
- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\later-unmodified-chapters-audit-20260829\后续章节建议修改对照.md`
- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\later-unmodified-chapters-audit-20260829\later-audit-candidates.json`
- `F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3\later-unmodified-chapters-audit-20260829\数据库应用结果.md`
