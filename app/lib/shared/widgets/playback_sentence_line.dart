import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/playback_visual_state.dart';

class PlaybackSentenceLine extends StatelessWidget {
  const PlaybackSentenceLine({
    required this.text,
    required this.state,
    this.textColor = Colors.white,
    this.onReplay,
    this.replayEnabled = true,
    this.showReplayButton = true,
    super.key,
  });

  final String text;
  final PlaybackVisualState state;
  final Color textColor;
  final VoidCallback? onReplay;
  final bool replayEnabled;
  final bool showReplayButton;

  @override
  Widget build(BuildContext context) {
    final showText = state != PlaybackVisualState.waitingStart;
    final showTailDots = state == PlaybackVisualState.playing;
    final showFailed = state == PlaybackVisualState.failed;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: showText
              ? Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    Text(
                      text,
                      style: GoogleFonts.nunito(
                        fontSize: 15,
                        color: textColor,
                        height: 1.45,
                      ),
                    ),
                    if (showTailDots)
                      EllipsisDots(
                        color: textColor.withValues(alpha: 0.85),
                        fontSize: 15,
                      ),
                    if (showFailed)
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Colors.red.shade300,
                      ),
                  ],
                )
              : EllipsisDots(
                  color: textColor.withValues(alpha: 0.9),
                  fontSize: 18,
                ),
        ),
        if (showReplayButton)
          IconButton(
            tooltip: '重播',
            onPressed: replayEnabled ? onReplay : null,
            icon: Icon(
              Icons.refresh_rounded,
              size: 18,
              color: replayEnabled
                  ? textColor.withValues(alpha: 0.9)
                  : textColor.withValues(alpha: 0.35),
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class EllipsisDots extends StatelessWidget {
  const EllipsisDots({
    required this.color,
    this.fontSize = 16,
    super.key,
  });

  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text(
      '...',
      style: GoogleFonts.nunito(
        fontSize: fontSize,
        color: color,
        fontWeight: FontWeight.bold,
      ),
    )
        .animate(onPlay: (controller) => controller.repeat())
        .fadeOut(duration: 380.ms)
        .fadeIn(duration: 380.ms);
  }
}
