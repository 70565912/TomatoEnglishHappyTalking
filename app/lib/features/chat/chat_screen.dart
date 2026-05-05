import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/models/playback_visual_state.dart';
import '../../shared/widgets/playback_sentence_line.dart';
import 'providers/chat_provider.dart';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({required this.articleId, super.key});

  final int articleId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _showTextInput = false;

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider(widget.articleId));

    ref.listen(chatProvider(widget.articleId), (prev, next) {
      if (next.messages.length != (prev?.messages.length ?? 0)) {
        _scrollToBottom();
      }
    });

    final showInput =
        chatState.step != ChatStep.completed && chatState.step != ChatStep.init;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.darkBlue,
        foregroundColor: Colors.white,
        title: Text(
          chatState.articleTitle.isNotEmpty
              ? chatState.articleTitle
              : 'AI 聊天模式',
          style: GoogleFonts.nunito(fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (chatState.questionCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${chatState.questionCount}/8',
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _StatusBanner(step: chatState.step),
          Expanded(
            child: _buildBody(chatState),
          ),
          if (chatState.error != null) _ErrorBanner(error: chatState.error!),
          if (showInput)
            _InputBar(
              state: chatState,
              showTextInput: _showTextInput,
              textController: _textController,
              onToggleText: () =>
                  setState(() => _showTextInput = !_showTextInput),
              onRecord: () => ref
                  .read(chatProvider(widget.articleId).notifier)
                  .startRecording(),
              onStopRecord: () => ref
                  .read(chatProvider(widget.articleId).notifier)
                  .stopRecordingAndSend(),
              onSendText: (text) {
                ref
                    .read(chatProvider(widget.articleId).notifier)
                    .sendText(text);
                _textController.clear();
                setState(() => _showTextInput = false);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ChatState chatState) {
    if (chatState.step == ChatStep.init && chatState.messages.isEmpty) {
      return const _InitLoadingView();
    }
    if (chatState.step == ChatStep.completed) {
      return _CompletedView(onHome: () => context.go('/'));
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      itemCount: chatState.messages.length,
      itemBuilder: (_, i) {
        final msg = chatState.messages[i];
        return _ChatBubble(
          message: msg,
          onReplay: () => ref
              .read(chatProvider(widget.articleId).notifier)
              .replayAiMessage(msg.id),
        ).animate().fadeIn(duration: 250.ms).slideX(
              begin: msg.isAi ? -0.05 : 0.05,
              end: 0,
              duration: 250.ms,
            );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Status Banner
// ---------------------------------------------------------------------------

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.step});
  final ChatStep step;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text, Color color) = switch (step) {
      ChatStep.init => (Icons.auto_awesome, '正在初始化对话...', AppTheme.darkBlue),
      ChatStep.aiSpeaking => (
          Icons.volume_up,
          'Emma 正在说话...',
          AppTheme.darkBlue
        ),
      ChatStep.userIdle => (
          Icons.mic_none,
          '轮到你了！按麦克风说话或输入文字',
          AppTheme.primary
        ),
      ChatStep.recording => (
          Icons.fiber_manual_record,
          '录音中... 再次点击停止',
          Colors.red
        ),
      ChatStep.processing => (Icons.hourglass_empty, '处理中...', Colors.grey),
      ChatStep.completed => (Icons.emoji_events, '对话完成！', Colors.green),
      ChatStep.error => (Icons.warning_amber, '出错了', Colors.red),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.nunito(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (step == ChatStep.init ||
              step == ChatStep.processing ||
              step == ChatStep.aiSpeaking)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat Bubble
// ---------------------------------------------------------------------------

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message, required this.onReplay});
  final DisplayMessage message;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final isAi = message.isAi;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isAi ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (isAi) ...[
            const CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.darkBlue,
              child: Icon(Icons.smart_toy, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isAi ? AppTheme.darkBlue : AppTheme.primary,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isAi ? 4 : 16),
                  bottomRight: Radius.circular(isAi ? 16 : 4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: isAi
                  ? PlaybackSentenceLine(
                      text: message.text,
                      state: message.playbackState,
                      textColor: Colors.white,
                      onReplay: onReplay,
                      replayEnabled: message.playbackState !=
                              PlaybackVisualState.waitingStart &&
                          message.playbackState != PlaybackVisualState.playing,
                    )
                  : Text(
                      message.text,
                      style: GoogleFonts.nunito(
                        fontSize: 15,
                        color: Colors.white,
                        height: 1.45,
                      ),
                    ),
            ),
          ),
          if (!isAi) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.3),
              child: const Icon(Icons.person, color: Colors.white, size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Input Bar
// ---------------------------------------------------------------------------

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.state,
    required this.showTextInput,
    required this.textController,
    required this.onToggleText,
    required this.onRecord,
    required this.onStopRecord,
    required this.onSendText,
  });

  final ChatState state;
  final bool showTextInput;
  final TextEditingController textController;
  final VoidCallback onToggleText;
  final VoidCallback onRecord;
  final VoidCallback onStopRecord;
  final ValueChanged<String> onSendText;

  bool get _canInteract =>
      state.step == ChatStep.userIdle || state.step == ChatStep.recording;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTextInput) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: textController,
                    style: GoogleFonts.nunito(fontSize: 15),
                    decoration: const InputDecoration(
                      hintText: '输入你的回答...',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) onSendText(v);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  onPressed: state.step == ChatStep.userIdle
                      ? () {
                          final t = textController.text;
                          if (t.trim().isNotEmpty) onSendText(t);
                        }
                      : null,
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Toggle text input
              IconButton(
                icon: Icon(
                  showTextInput ? Icons.mic : Icons.keyboard,
                  color: AppTheme.darkBlue.withValues(alpha: 0.6),
                ),
                onPressed: onToggleText,
                tooltip: showTextInput ? '切换到语音' : '切换到文字',
              ),
              const SizedBox(width: 24),

              // Main record button
              GestureDetector(
                onTap: _canInteract
                    ? (state.step == ChatStep.recording
                        ? onStopRecord
                        : onRecord)
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: state.step == ChatStep.recording
                        ? Colors.red
                        : _canInteract
                            ? AppTheme.primary
                            : Colors.grey.shade300,
                    boxShadow: _canInteract
                        ? [
                            BoxShadow(
                              color: (state.step == ChatStep.recording
                                      ? Colors.red
                                      : AppTheme.primary)
                                  .withValues(alpha: 0.4),
                              blurRadius: 14,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: state.step == ChatStep.processing
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Icon(
                          state.step == ChatStep.recording
                              ? Icons.stop
                              : Icons.mic,
                          color: Colors.white,
                          size: 32,
                        ),
                ),
              ),

              const SizedBox(width: 24),
              // Placeholder to balance the row
              const SizedBox(width: 48),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Init loading view
// ---------------------------------------------------------------------------

class _InitLoadingView extends StatelessWidget {
  const _InitLoadingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text(
            '正在启动对话...',
            style: GoogleFonts.nunito(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Completed view
// ---------------------------------------------------------------------------

class _CompletedView extends StatelessWidget {
  const _CompletedView({required this.onHome});
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events, size: 80, color: AppTheme.accent),
            const SizedBox(height: 20),
            Text(
              '对话完成！',
              style: GoogleFonts.nunito(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: AppTheme.darkBlue,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '你完成了 8 轮英语对话练习，太棒了！',
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                fontSize: 16,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: onHome,
              icon: const Icon(Icons.home),
              label: const Text('返回首页'),
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
        ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.1, end: 0),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error banner
// ---------------------------------------------------------------------------

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: GoogleFonts.nunito(
                fontSize: 13,
                color: Colors.red.shade800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
