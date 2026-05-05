import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/models/playback_visual_state.dart';
import '../../shared/widgets/playback_sentence_line.dart';
import '../../shared/widgets/score_display_widget.dart';
import 'providers/follow_read_provider.dart';

class FollowReadScreen extends ConsumerWidget {
  const FollowReadScreen({required this.articleId, super.key});

  final int articleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(followReadProvider(articleId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBlue,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: asyncState.whenOrNull(
              data: (s) => Text(
                s.article.title,
                style: GoogleFonts.nunito(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ) ??
            Text('跟读模式', style: GoogleFonts.nunito(color: Colors.white)),
        actions: [
          asyncState.whenOrNull(
                data: (s) => Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: Text(
                      '${s.currentIndex + 1} / ${s.totalSentences}',
                      style: GoogleFonts.nunito(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ) ??
              const SizedBox.shrink(),
        ],
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(message: e.toString()),
        data: (s) => _FollowReadBody(
          articleId: articleId,
          state: s,
          ref: ref,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Main body — only shown when state is loaded
// ---------------------------------------------------------------------------

class _FollowReadBody extends StatelessWidget {
  const _FollowReadBody({
    required this.articleId,
    required this.state,
    required this.ref,
  });

  final int articleId;
  final FollowReadState state;
  final WidgetRef ref;

  void _play() =>
      ref.read(followReadProvider(articleId).notifier).playCurrent();
  void _startRec() =>
      ref.read(followReadProvider(articleId).notifier).startRecording();
  void _stopRec() =>
      ref.read(followReadProvider(articleId).notifier).stopRecordingAndScore();
  void _next() =>
      ref.read(followReadProvider(articleId).notifier).nextSentence();
  void _retry() => ref.read(followReadProvider(articleId).notifier).retry();
  void _replayCurrent() =>
      ref.read(followReadProvider(articleId).notifier).replayCurrentSentence();

  @override
  Widget build(BuildContext context) {
    if (state.step == FollowReadStep.completed) {
      return _CompletedView(onDone: () => context.pop());
    }

    return SafeArea(
      child: Column(
        children: [
          // ---- Avatar / status area ----
          _AvatarArea(step: state.step),

          // ---- Sentence card ----
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SentenceCard(
                    sentence: state.currentSentence,
                    playbackState: state.playbackState,
                    playbackError: state.playbackError,
                    replayEnabled: state.step == FollowReadStep.idle ||
                        state.step == FollowReadStep.result,
                    onReplay: _replayCurrent,
                  ),
                  // Error banner
                  if (state.error != null) ...[
                    const SizedBox(height: 8),
                    _ErrorBanner(message: state.error!),
                  ],
                  // Score panel
                  if (state.lastResult != null) ...[
                    const SizedBox(height: 16),
                    _ScorePanel(result: state.lastResult!),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ---- Control buttons ----
          _ControlBar(
            step: state.step,
            hasResult: state.lastResult != null,
            onPlay: _play,
            onStartRec: _startRec,
            onStopRec: _stopRec,
            onNext: _next,
            onRetry: _retry,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Avatar / animated status area
// ---------------------------------------------------------------------------

class _AvatarArea extends StatelessWidget {
  const _AvatarArea({required this.step});
  final FollowReadStep step;

  @override
  Widget build(BuildContext context) {
    final isRecording = step == FollowReadStep.recording;
    final isPlaying = step == FollowReadStep.playing;
    final isBusy =
        step == FollowReadStep.loadingTts || step == FollowReadStep.scoring;

    return Container(
      width: double.infinity,
      color: AppTheme.darkBlue,
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          // Avatar placeholder circle
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.15),
              border: Border.all(
                color: isRecording
                    ? AppTheme.primary
                    : Colors.white.withValues(alpha: 0.3),
                width: 3,
              ),
            ),
            child: Icon(
              isRecording
                  ? Icons.mic
                  : isPlaying
                      ? Icons.volume_up
                      : isBusy
                          ? Icons.hourglass_top
                          : Icons.face,
              size: 44,
              color: isRecording ? AppTheme.primary : Colors.white,
            ),
          )
              .animate(
                onPlay: (c) => c.repeat(reverse: true),
                target: isRecording ? 1 : 0,
              )
              .scaleXY(begin: 1, end: 1.08, duration: 600.ms),
          const SizedBox(height: 10),
          Text(
            _statusText,
            style: GoogleFonts.nunito(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  String get _statusText => switch (step) {
        FollowReadStep.idle => '准备好了，先听，再跟读 🎧',
        FollowReadStep.loadingTts => '正在合成语音…',
        FollowReadStep.playing => '请认真听 🎵',
        FollowReadStep.recording => '正在录音，说吧！🎤',
        FollowReadStep.scoring => '正在评分…',
        FollowReadStep.result => '评分完成！✨',
        FollowReadStep.completed => '全部完成！',
      };
}

// ---------------------------------------------------------------------------
// Sentence card
// ---------------------------------------------------------------------------

class _SentenceCard extends StatelessWidget {
  const _SentenceCard({
    required this.sentence,
    required this.playbackState,
    required this.playbackError,
    required this.replayEnabled,
    required this.onReplay,
  });

  final String sentence;
  final PlaybackVisualState playbackState;
  final String? playbackError;
  final bool replayEnabled;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlaybackSentenceLine(
              text: sentence,
              state: playbackState,
              textColor: AppTheme.darkBlue,
              onReplay: onReplay,
              replayEnabled: replayEnabled,
            ),
            if (playbackState == PlaybackVisualState.failed &&
                playbackError != null &&
                playbackError!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  playbackError!,
                  style: GoogleFonts.nunito(
                    fontSize: 12,
                    color: Colors.red.shade700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Score panel
// ---------------------------------------------------------------------------

class _ScorePanel extends StatelessWidget {
  const _ScorePanel({required this.result});
  final dynamic result; // PronunciationResult

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ScoreDisplayWidget(result: result),
      ),
    )
        .animate()
        .fadeIn(duration: 400.ms)
        .slideY(begin: 0.2, end: 0, duration: 400.ms, curve: Curves.easeOut);
  }
}

// ---------------------------------------------------------------------------
// Error banner
// ---------------------------------------------------------------------------

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEF9A9A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Color(0xFFE53935), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.nunito(
                fontSize: 13,
                color: const Color(0xFFB71C1C),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Control bar
// ---------------------------------------------------------------------------

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.step,
    required this.hasResult,
    required this.onPlay,
    required this.onStartRec,
    required this.onStopRec,
    required this.onNext,
    required this.onRetry,
  });

  final FollowReadStep step;
  final bool hasResult;
  final VoidCallback onPlay;
  final VoidCallback onStartRec;
  final VoidCallback onStopRec;
  final VoidCallback onNext;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _buildButtons(),
      ),
    );
  }

  List<Widget> _buildButtons() {
    final isBusy = step == FollowReadStep.loadingTts ||
        step == FollowReadStep.playing ||
        step == FollowReadStep.scoring;

    if (step == FollowReadStep.recording) {
      return [
        _BigButton(
          icon: Icons.stop_circle,
          label: '停止录音',
          color: const Color(0xFFE53935),
          onTap: onStopRec,
        ),
      ];
    }

    if (hasResult) {
      return [
        _SmallButton(icon: Icons.replay, label: '重试', onTap: onRetry),
        _BigButton(
          icon: Icons.arrow_forward_ios,
          label: '下一句',
          color: AppTheme.primary,
          onTap: onNext,
        ),
      ];
    }

    return [
      _SmallButton(
        icon: Icons.volume_up,
        label: '播放',
        onTap: isBusy ? null : onPlay,
      ),
      _BigButton(
        icon: Icons.mic,
        label: '跟读',
        color: AppTheme.primary,
        onTap: isBusy ? null : onStartRec,
      ),
    ];
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: onTap == null ? 0.4 : 1.0,
        duration: 200.ms,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.nunito(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: onTap == null ? 0.4 : 1.0,
        duration: 200.ms,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.darkBlue.withValues(alpha: 0.08),
              ),
              child: Icon(icon, color: AppTheme.darkBlue, size: 24),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 11,
                color: AppTheme.darkBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Completed view
// ---------------------------------------------------------------------------

class _CompletedView extends StatelessWidget {
  const _CompletedView({required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events, color: AppTheme.accent, size: 80)
                .animate()
                .scale(
                    begin: const Offset(0, 0),
                    duration: 600.ms,
                    curve: Curves.elasticOut),
            const SizedBox(height: 24),
            Text(
              '全部完成！',
              style: GoogleFonts.nunito(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: AppTheme.darkBlue,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Great job! Keep practicing!',
              style: GoogleFonts.nunito(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.home),
              label: Text(
                '返回首页',
                style: GoogleFonts.nunito(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error view
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 60),
            const SizedBox(height: 16),
            Text(
              '加载失败',
              style: GoogleFonts.nunito(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
