# 分句 Round 24：邻近原文标点一对一修复（2026-08-15）

## 结论

**接受。** 规则复核确认的不支持数由 **30 / 6792（0.442%）** 降为
**27 / 6792（0.398%）**，相对减少 10%；没有新增不支持项。

## 通用规则

稳定路径若选中了带 `incomplete_attached_*` 事实的非标点切点，而该点右侧五词内已有未被硬阻止的
原文标点候选，则只在满足以下条件时进行一对一迁移：

- 删除这个已确认有附着缺陷的切点；
- 插入邻近的既有原文标点候选；
- 迁移后左右相邻朗读块都不少于 6 词；
- 其它稳定边界不参与重排。

这实现的是“长度需要切分时，原文标点优先于无标点句法切点”，不是对书名、章节或具体词面的特判。

## 实际变化

共 5 个原句发生一对一边界迁移，最终句槽数量均不变。

### Alice E21

```text
旧：...much more like a snout | than a real nose; also its eyes were getting extremely small, | for a baby...
新：...much more like a snout than a real nose; | also its eyes were getting extremely small, | for a baby...
```

### Alice E23

```text
旧：...the Hatter continued," | in this way: "'Up above the world you fly...
新：...the Hatter continued," in this way: | "'Up above the world you fly...
```

### Willows E30

```text
旧：...leapt forth on the high road | through the open country, he was only conscious...
新：...leapt forth on the high road through the open country, | he was only conscious...
```

### Willows E34

```text
旧：...a jaunt on the river | in Mr. Rat's real boat; and the two animals...
新：...a jaunt on the river in Mr. Rat's real boat; | and the two animals...
```

### Willows E52

```text
旧：...happy and high-spirited | as of old, now that he found himself...
新：...happy and high-spirited as of old, | now that he found himself...
```

Alice E01/E09、Willows E33/E37/E59 与已接受基线完全相同。E37 的邻近标点会造成短块，因 6 词保护未迁移；
E59 没有形成可接受的一对一稳定替换，也保持不变。

## 验证

- solver 与冻结回放工具静态分析：0 issue；
- 本地分句回归：128 passed，1 个原生全量评测按环境开关跳过；
- 冻结 UDPipe 代表回放：Alice 4 章、Willows 6 章；只有上述 5 个原句变化；
- Alice E21 五轮 AOT 交替基准：
  - Round 23 中位数 2528 ms；
  - Round 24 中位数 2526 ms；
  - 当前约快 0.08%，无性能回退；
- 求解器净增 50 行（55 增、5 删）；事实只构建一次，没有新增递归、全窗重排或第二套求解管线；
- 无数据库迁移、TTS 重建或云 API 调用。
