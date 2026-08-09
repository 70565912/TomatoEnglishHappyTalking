# 火山 Doubao Lite 英文分句人工审核报告

审核日期：2026-08-09<br>
审核人：项目所有者<br>
模型：`volcengine/doubao-seed-2-0-lite-260215`<br>
任务：受约束英文朗读分句，仅允许从代码提供的候选 path ID 中选择

> **English abstract:** The project owner manually reviewed five disputed sentence-segmentation paths
> selected by Volcengine Doubao Lite. All five model choices were rejected, while the existing approved
> references were confirmed without adding or relaxing any accepted path. The failures involve
> predicate-object integrity, restrictive-relative-clause attachment, adverbial attachment, and
> `wait until` predicate-complement integrity.

## 最终结论

**5 种争议切法全部判定为模型错误。现有 approved reference 保持不变，不增加等价认可路径，
也不因人工复核而放宽 Lite 的通过标准。**

因此：

- P6 历史结果仍为 22/30，不通过且三轮不一致；
- P8 同协议复测仍为“协议失败、9/10、8/10”，不通过且三轮不一致；
- Doubao Lite 不进入自动分句 AI 白名单；用户选择该模型时继续使用本地确定性路径；
- 本次只固化人工判定，没有重新调用任何收费 API。

## 五项人工判定

### 1. 网关重试：拆开谓词和宾语

模型选择：

> The client retries the request when the gateway closes the connection before the server has returned<br>
> | a complete response to the original operation.

继续认可的参考：

> The client retries the request when the gateway closes the connection<br>
> | before the server has returned a complete response to the original operation.

判定：**模型错误。** `has returned` 与其必需宾语 `a complete response` 不应拆开；参考路径让
主句及 `when` 条件保持完整，右段也是完整的 `before` 状语从句。

### 2. 租户听证：拆开名词与限制性关系从句

模型选择：

> A tenant who receives a written notice may request a hearing before the authority begins any action<br>
> | that could terminate the tenancy.

继续认可的参考：

> A tenant who receives a written notice may request a hearing<br>
> | before the authority begins any action that could terminate the tenancy.

判定：**模型错误。** 模型把 `action` 与限定其含义的 `that could terminate the tenancy` 拆开；
参考路径保留完整 `before` 从句，语法和朗读单位都更自然。

### 3. 学习者演讲：改变 `several times` 的语义归属

模型选择：

> Although Maria had practiced the presentation<br>
> | several times she spoke slowly enough for every student in the crowded room to understand her main argument.

继续认可的参考：

> Although Maria had practiced the presentation several times<br>
> | she spoke slowly enough for every student in the crowded room to understand her main argument.

判定：**模型错误。** `several times` 应修饰 `had practiced`；模型切法会使其看起来修饰
`spoke`，改变原句的语义归属。

### 4. 更换过滤器：拆开 `wait until`

模型选择：

> Before replacing the filter disconnect the machine from its power supply and wait<br>
> | until every moving component has come to a complete stop.

继续认可的参考：

> Before replacing the filter disconnect the machine from its power supply<br>
> | and wait until every moving component has come to a complete stop.

判定：**模型错误。** `until` 从句给出 `wait` 动作的终点条件，应与 `wait` 保持在同一朗读
单元；参考路径同时把两个并列指令组织为完整单位。

### 5. 更换过滤器复合路径：短碎片加 `wait until` 拆分

模型选择：

> Before replacing the filter<br>
> | disconnect the machine from its power supply and wait<br>
> | until every moving component has come to a complete stop.

继续认可的参考：

> Before replacing the filter disconnect the machine from its power supply<br>
> | and wait until every moving component has come to a complete stop.

判定：**模型错误。** 完整路径既新增 4 词片段，又继续拆开 `wait | until`。此前提出“单独的
`Before replacing the filter | disconnect...` 或可作为次选”的建议在本固定评测中撤回；不把
4/19 路径加入 approved references，继续以现有 11/12 参考作为验收口径。

这项判定只冻结当前完整句子的人工金标，不创建“所有前置 `Before` 从句都禁止停顿”的生产词表
或句型特例。其它文章仍由通用候选、语法完整性和硬约束共同判断。

## 对测试与模型选型的影响

人工审核结果已经写入
[`sentence_split_v3_ai_tuning_cases.json`](../app/test/fixtures/sentence_split_v3_ai_tuning_cases.json)：

- 原有 `approvedChunks` 未修改；
- 新增 5 条 `humanRejectedChunks` 作为负向回归证据；
- 离线测试要求这 5 条路径能完整回拼原文，但不得与任何 approved path 重合；
- 未来模型即使重复选中这些路径，也必须继续判错，不能用“存在人工争议”提高通过率。

相关验收总览：
[英文朗读分句 V3.3 实施与验收报告](read_aloud_sentence_split_v3_3_implementation_report.md)。

## 审核边界

这是一组固定任务样本的人工自然度判定，不代表 Doubao Lite 在所有翻译、摘要或对话任务上的
总体能力；但它直接证明该模型在当前受约束英文分句协议上不能稳定满足生产门槛。模型名称、
协议、样本和日期变化后，应重新评测，不能沿用本报告推断其它版本。
