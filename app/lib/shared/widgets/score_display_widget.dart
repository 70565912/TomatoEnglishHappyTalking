import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_theme.dart';
import '../../services/scoring_service.dart';

/// 发音评分展示卡片 — 显示总分、4 项子分和逐词高亮
class ScoreDisplayWidget extends StatelessWidget {
  const ScoreDisplayWidget({
    required this.result,
    super.key,
  });

  final PronunciationResult result;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- Row: big circle score + 4 bars ---
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CircleScore(score: result.overallScore),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                children: [
                  _ScoreBar(label: '准确度', value: result.accuracyScore),
                  const SizedBox(height: 6),
                  _ScoreBar(label: '流利度', value: result.fluencyScore),
                  const SizedBox(height: 6),
                  _ScoreBar(label: '完整度', value: result.completenessScore),
                  const SizedBox(height: 6),
                  _ScoreBar(label: '韵　律', value: result.prosodyScore),
                ],
              ),
            ),
          ],
        ),
        if (result.isMock)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '（当前为回退评分结果）',
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                fontSize: 11,
                color: Colors.grey[500],
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        const SizedBox(height: 12),
        // --- Word-level coloring ---
        _WordRow(words: result.words),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Big circle score
// ---------------------------------------------------------------------------

class _CircleScore extends StatelessWidget {
  const _CircleScore({required this.score});
  final double score;

  Color get _color {
    if (score >= 80) return const Color(0xFF43A047); // green
    if (score >= 60) return const Color(0xFFFB8C00); // orange
    return const Color(0xFFE53935); // red
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: score / 100,
            strokeWidth: 7,
            backgroundColor: Colors.grey[200],
            valueColor: AlwaysStoppedAnimation<Color>(_color),
          ),
          Center(
            child: Text(
              score.toStringAsFixed(0),
              style: GoogleFonts.nunito(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Score bar row
// ---------------------------------------------------------------------------

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.label, required this.value});
  final String label;
  final double value;

  Color get _color {
    if (value >= 80) return const Color(0xFF43A047);
    if (value >= 60) return const Color(0xFFFB8C00);
    return const Color(0xFFE53935);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            label,
            style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[700]),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value / 100,
              minHeight: 8,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(_color),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 28,
          child: Text(
            value.toStringAsFixed(0),
            textAlign: TextAlign.right,
            style: GoogleFonts.nunito(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _color,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Word-level colour row
// ---------------------------------------------------------------------------

class _WordRow extends StatelessWidget {
  const _WordRow({required this.words});
  final List<WordScore> words;

  Color _wordColor(WordScore w) {
    if (w.errorType == 'Omission') return Colors.grey;
    if (w.score >= 80) return const Color(0xFF43A047);
    if (w.score >= 60) return AppTheme.primary;
    return const Color(0xFFE53935);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: words.map((w) {
        final color = _wordColor(w);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Text(
            w.word,
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
              decoration: w.errorType == 'Omission'
                  ? TextDecoration.lineThrough
                  : TextDecoration.none,
            ),
          ),
        );
      }).toList(),
    );
  }
}
