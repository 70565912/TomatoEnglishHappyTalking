# 分句 Round 23：从句标记前缘一对一修复（2026-08-15）

## 结论

**接受。** 不支持数由 **31 / 6792（0.456%）** 降为 **30 / 6792（0.442%）**，相对减少 3.226%；
没有新增不支持项。

## 通用规则

稳定路径若切在从句/关系标记与其主语之间，并且该标记前一个词隙已经被事实层识别为完整右侧主谓从句前缘，
只删除原坏边界，再由既有有界稳定插入器补入这个前缘。其它稳定边界不参与重排。

该规则保留完整主语｜谓语、谓语｜完整宾语等合法无标点停顿；它只处理 `marker | subject`，不把一般 crossing
升级为硬阻止。

## 实际变化

Alice E01 仅发生一对一替换：

```text
旧：Alice! a childish story take, And with a gentle hand Lay it where |
    Childhood's dreams are twined In Memory's mystic band, |
    Like pilgrim's wither'd wreath of flowers Pluck'd in a far-off land.

新：Alice! a childish story take, And with a gentle hand Lay it |
    where Childhood's dreams are twined In Memory's mystic band, |
    Like pilgrim's wither'd wreath of flowers Pluck'd in a far-off land.
```

- 下游 `...band, | Like pilgrim's...` 原标点边界完全不动；
- Alice E09 已批准的 `birds | and animals` 完全不变；
- Round 21 全量候选事实中，当前被选路径只有这一处带 `surface_relative_marker_subject_separation`，
  因而本轮触发面严格为 1 个原句。

## 验证

- 本地分句回归：128 passed，1 个原生全量评测按环境开关跳过；
- solver 静态分析：0 issue；
- Alice E01/E09 冻结 UDPipe 代表回放：E01 仅目标两句变化，E09 0 变化；
- 5 轮 AOT 交替基准（Alice E01/E09）：
  - Round 21 中位数 3088.38 ms；
  - Round 23 中位数 3052.00 ms；
  - 中位数快 1.18%，无性能回退；
- 求解器净增 12 行；没有新增递归、候选管线或全句重排器；
- 无数据库迁移、TTS 重建或云 API 调用。
