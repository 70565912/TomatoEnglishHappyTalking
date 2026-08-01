# CTC Forced Aligner 字幕同步评估归档（2026-08-01）

本目录归档「用本地 forced aligner 替代火山 BigASR 词锚点做歌曲字幕时间轴」的离线评估脚本与结论报告。

**产品正式字幕链路未改动**；App 仍使用 `SongSubtitleTimelineService` + BigASR `show_utterances` + 本地 DP 对齐。

## 结论摘要

评估对象：英文歌曲（本项目后续不考虑中文字幕 ASR）。基线为本地已有 BigASR + DP timeline。

| 后端 | 质量（相对 BigASR） | 速度（CPU RTF） | 产品建议 |
|------|---------------------|-----------------|----------|
| MMS CTC（MahmoudAshraf MMS-300M） | 干净曲中位约 105–160ms，3/4 可替代候选；长 Suno 难例仍差 | 平均 RTF ≈ 0.88 | **本地首选候选**；难例回退 BigASR |
| torchaudio LV60K FA | 次优，3/4 可替代候选，中位差于 MMS | 平均 RTF ≈ 1.43 | 可作备选，不优于 MMS |
| HF Wav2Vec2-Large CTC | 整体更差 | 近实时 | 不推荐 |
| Montreal Forced Aligner | 偶有可用，不稳定；Suno 样本失败 | 平均 RTF ≈ 5.5，最坏约 11.8 | **不适合**创作中心交互生成 |

**总体：** 英文干净曲上 MMS 可接近火山时间轴，但不能全面替换；保留 BigASR 作难例/异常兜底。MFA 因耗时过高排除。

详细数字见 [`reports/summary.md`](reports/summary.md)（round1）与 [`reports/summary_round2.md`](reports/summary_round2.md)（round2，含质量 + RTF）。

## 目录

- `scripts/` — 评估脚本与 `requirements.txt`（不含 `.venv`）
- `reports/` — 摘要报告与样本元数据（不含 per-sample  bulk / MFA work）

## 若需复现（可选）

1. Python 3.13 建 venv，安装 `scripts/requirements.txt`
2. 确保 `ffmpeg` 在 PATH（可用 App 发布目录下的 `ffmpeg.exe`）
3. 在有本地歌曲 + BigASR timeline 的机器上运行 `run_batch.py` / `run_round2.py`
4. MFA 另需 conda-forge `montreal-forced-aligner`（本次评测后本机 MFA/Miniconda 环境已清理）

## 清理说明

归档后已删除：

- 仓库内 `tools/eval_ctc_subtitle_align/`（含 ~1.15GB `.venv` 与 bulk reports）
- 本机为 MFA 安装的 `D:\DevTools\miniconda3`
- `%USERPROFILE%\Documents\MFA`
- 本次相关 HF 模型缓存（MMS / wav2vec2-large-960h-lv60-self）
