# 说明：勿将「v3.10」路径/标签当作已接受版本

日期：2026-08-16  

**当前唯一已确认的求解器版本字符串：`syntax_solver_v3_9`。**

工作过程中曾把 candle（逗号收尾弹性负担）等**未确认**试验误标为 `syntax_solver_v3_10`，
甚至短暂误标 `v3.11`。这些标签**没有**经过「接受后才升号」流程，现已全部改回 v3.9。

因此下列目录/文件名里的 `v3_10` / `v3.10` **只是历史误标残留**，含义是
「当时基于 v3.9 的未接受试验回放」，**不是**已发布或已接受基线：

- `output/sentence-split-v3/db-vs-v3_10-full-20260816/`
- `output/sentence-split-v3/db-vs-v3_11-full-20260816/`（失败硬拦试验）
- `output/sentence-split-v3/v3-9-prelim-review-10x10/alice-v3_10-replay-10.json` 等
- `output/sentence-split-v3/v3-9-prelim-review-10x10/V3_10_*.md`
- `tools/build_v3_10_*.py` / `tools/audit_v3_10_*.py` / `tools/adjudicate_v3_10_*.py` /
  `tools/build_full_book_db_vs_v310_review.py`

对比与验收请以：

- 代码：`ReadAloudSplitterV3.solverVersion == syntax_solver_v3_9`
- 回放金标：`*-v3_9-replay-10.json` / 已确认的 v3.9 行为

未确认接受前，**禁止**再把工作区试验升为 `syntax_solver_v3_10`。
