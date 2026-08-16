# 失败记录：紧密附着硬拦试验（未接受，已撤回）

日期：2026-08-16  
基线：**已确认** `syntax_solver_v3_9`  
试验曾误标：`syntax_solver_v3_11`（**未达标；不得占用版本号；代码已撤回，版本保持 v3.9**）

## 目标（人工裁定）

以下三处相对 DB 的差异，全部支持**旧切法（DB）**：

1. Willows E13  
   - DB：`…little door, | painted a dark green.`  
   - 拒：`seemed | to be`，以及任何未回到 DB 门边逗号切法的替代切点  
2. Alice E17  
   - DB：末段整段保留 `…bend about easily in any direction, like a serpent.`  
   - 拒：`bend | about`  
3. Willows E16  
   - DB：`…to his study | …face, | …"busy"…`（absolute 逗号不切开；`legs up` 不拆）  
   - 拒：`legs | up`，以及未回到 DB 的 absolute / 补语切法

## 假设（已证伪）

只要硬拦“不定式标记 / 方向小品词 / 紧邻 advmod”等紧密附着切点，求解会自然落到 DB 路径。

## 实际做法（禁止再原样复用）

在候选生成阶段叠加硬拦与 surface 校验拒绝，例如：

- `inside_predicate_infinitive_marker` / `inside_infinitive_marker_predicate`
- `inside_particle_or_adverbial_attachment` + `_directionalParticleLexemes`
- NOUN|ADP 时拒绝校验方向小品词 surface phrase
- 曾尝试用“句法切开后右块埋标点”的 skippedPunctuation 加罚，以及
  `syntax_before_nearby_source_pause` 一类宽泛硬拦（均已撤回）

并在未达标前就把 `solverVersion` 误调到 `syntax_solver_v3_11`。

## 结果

| 句 | 硬拦后常见结果 | 是否达 DB 目标 |
|---|---|---|
| E13 | `seemed to be` 可保住，但落到 `snow-bank \| stood…`，不是 `door, \| painted` | 否 |
| E17 | `bend about` 可保住，但落到 `…easily \| in any direction…`，不是整段 KEEP | 否 |
| E16 | `legs up` 可保住，但仍切 `Badger,` / `breakfast,` / `arm-chair \| with` / `"busy" \|` | 否 |

加宽“埋标点 / 主谓后禁切”后还会冲掉已审语法路径（如 Willows E43 `memories | by the fireside`）或把路径逼成更差切点。

## 结论与禁令

- **拒绝**本试验；版本号保持 **`syntax_solver_v3_9`**。
- **禁止**再靠“层叠硬拦紧密词隙 + 指望 DAG 自动对齐 DB 整句路径”解决这三处。
- **禁止**未达标就递增 `solverVersion`；后续试验仍基于 **v3.9**，只有验收通过后再升版本。
- 下一轮必须先定点说明：如何让 **E13 选中门边逗号**、**E16 保留 absolute 逗号并在 `study | and` / `face,` 切**、**E17 对末段 KEEP 或等价 DB 路径**，并在代表句回归通过后再扩范围。

## 相关产物（只读背景，非现行基线）

- `output/sentence-split-v3/db-vs-v3_11-full-20260816/`（失败回放，勿当基线）
- `output/sentence-split-v3/db-vs-v3_10-full-20260816/`（路径名含误标 v3.10；内容为未确认试验，勿当已接受版本）
- 对照仍以 DB `articles.sentences` 与已确认 `syntax_solver_v3_9` 为准
