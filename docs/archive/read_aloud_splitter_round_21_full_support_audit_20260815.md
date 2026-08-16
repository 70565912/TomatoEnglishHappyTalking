# 分句 Round 21：全量支持性基线审计（2026-08-15）

## 结论

本轮不修改求解逻辑，只给冻结 parser 回放工具增加显式
`--include-boundary-candidates` 审计开关。不开启该开关时，既有输出、运行路径和文件体积均不变化。

以 Round 20 求解器和相同冻结正文/UDPipe 事实回放：

- Alice：39 章、2092 个最终句槽；
- Willows：62 章、4700 个最终句槽；
- 合计：6792 个最终句槽、3870 个被选局部边界；
- 与 Round 20 全量结果逐章完全相同；
- `>30`：0；最终 `21–24` 词块：8；`>24`：0；
- 规则复核确认的不支持项：**31 / 6792（0.456%）**；按被选边界规模计为 **0.801%**。

这里的“不支持”不等同于 UDPipe 报出 crossing。完整主语｜谓语、谓语｜完整宾语、共享主语的并列谓语
仍是合法无标点停顿，例如 `and robins | perched...` 不列为错误。只有切进紧密成分、固定连接、助动词谓语、
名词短语内部，或长度触发后错过可用原文标点，才计入。

## 已确认的 31 项

### Alice（9）

1. E01：`Lay it where | Childhood's dreams...`，切开关系标记与主语。
2. E06：`a pair of white kid gloves | in one hand...`，切进宾语名词短语。
3. E06：23 词块错过 `...say this), | "to go...` 的括号闭缘/原文逗号停顿。
4. E21：`much more like a snout | than a real nose`，切开比较结构。
5. E21：`when she was a little | startled by...`，切进表语。
6. E27：`got its neck | nicely straightened out`，切进宾语补足结构。
7. E34：22 词块错过 `...in a deep voice, | "are done...` 的原文逗号。
8. E38：先产生 1 词引语 `"Here!"`，随后错误并入前一个正字句，而不是与后续归属语保持一体。
9. E41：`to keep | back the wandering hair`，切开短语动词。

### Willows（22）

1. E01：`an animal | with few wants...`，切进名词短语。
2. E03：`the Rat pointed | out a fork...`，切开短语动词。
3. E04：`moorhens who were | sniggering...`，切开助动词与谓语。
4. E06：`the joys of the open life | and the roadside...`，切开并列名词宾语。
5. E08：`know anything | about that motor-car...`，切进宾语短语。
6. E17：`there are | hundreds and hundreds of you`，切开系词与表语。
7. E18：`a heated argument | on the subject of eels`，切进名词短语。
8. E26：`the stern unbending look | on the countenances...`，切进名词短语。
9. E30：`on the high road | through the open country,`，使用无标点点而错过四词后的原文逗号。
10. E30：`the stoutest castle | in all the length...`，切进名词短语。
11. E33：22 词块错过 `a marvellous green, | set round...` 的原文逗号，原点可形成 11/11。
12. E33：22 词块错过 `whispered the Rat, | as if in a trance` 的原文逗号，可形成 17/5。
13. E35：`world of sunshine | and well-metalled high roads...`，切开并列名词短语。
14. E37：`you can chaff | back a bit`，切开短语动词。
15. E38：`a view of the line | behind them...`，切进名词短语。
16. E40：`the furniture and baggage | and stores moved...`，切开并列名词主语/宾语。
17. E51：`tried to grasp the reeds | and the rushes...`，切开并列宾语。
18. E52：`happy and high-spirited | as of old`，切进表语短语。
19. E52：`to have | ever mistaken him...`，切开助动词谓语。
20. E59：`the way he had | gone for the Chief Weasel`，切开助动词谓语。
21. E59：`as soon | as the stoats...`，切开固定连接。
22. E59：`heard the shrieks and the yells | and the uproar...`，切开并列宾语。

## 21–24 词弹性区判定

8 个最终长块不机械判错。以下 4 个保留：

- Willows E30 的 21 词 `because...crime;`：块内无原文标点；
- Willows E33 的 23 词 `that the kindly demi-god...: the gift...`：唯一冒号会产生 19/4，保留可避免短尾；
- Willows E43 的 24 词 `and what sort of harvest...memories`：块内无原文标点，现边界不切进紧密成分；
- Willows E60 的 24 词 `Through the French windows...lawn,`：块内无原文标点，末尾逗号已被使用。

另外 4 个因存在更自然标点列入上面的不支持项：Alice E06、Alice E34、Willows E33 两处。

## 性能与范围

- AOT、含全部候选事实的全量回放：Alice 53.743 秒；Willows 144.740 秒。
- 该时间包含大量候选 JSON 序列化，不与默认回放性能门禁混用。
- 产品求解器 0 行变化；离线回放工具净增 7 行。
- 本轮没有数据库迁移、TTS 重建或云 API 调用。

## 下一轮约束

从 31 项基线开始，每个被接受的求解轮次必须使不支持数严格下降；新增不支持项即拒绝。
修复必须按通用结构类别实施，不得按书名、章节或词面写特例。优先顺序为：

1. 长度触发后恢复原文标点/括号或引语结构边缘；
2. 阻止固定连接、助动词谓语和短语动词内部切分；
3. 阻止名词、宾语和表语短语内部切分；
4. 保留完整主语｜谓语、谓语｜完整宾语及共享主语并列谓语等合法边界。
