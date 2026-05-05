import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../services/tts_service.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _loading = true;
  bool _apiKeyReady = false;
  String _ttsResourceId = 'seed-tts-2.0';
  String _ttsSpeaker = '默认声音';
  String _realtimeAppId = '未设置';

  @override
  void initState() {
    super.initState();
    _loadConfigStatus();
  }

  Future<void> _loadConfigStatus() async {
    final apiKey = (await AppConfig.volcApiKey).trim();
    final resourceId = (await AppConfig.volcTtsResourceId).trim();
    final speakerId = (await AppConfig.volcTtsSpeakerId).trim();
    final realtimeAppId = (await AppConfig.volcRealtimeAppId).trim();

    final matchedSpeaker = TtsService.voices
        .where((voice) => voice.id == speakerId)
        .cast<VoiceInfo?>()
        .firstWhere((voice) => voice != null, orElse: () => null);

    if (!mounted) {
      return;
    }

    setState(() {
      _apiKeyReady = apiKey.isNotEmpty;
      _ttsResourceId = resourceId.isNotEmpty ? resourceId : 'seed-tts-2.0';
      _ttsSpeaker = matchedSpeaker != null
          ? '${matchedSpeaker.name} (${matchedSpeaker.lang})'
          : (speakerId.isNotEmpty ? speakerId : '默认声音');
      _realtimeAppId = realtimeAppId.isNotEmpty ? realtimeAppId : '未设置';
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionCard(
                  title: '火山引擎 API Key',
                  subtitle: 'TTS、BigASR 与 AI 对话共用同一份本机密钥',
                  children: [
                    _StatusTile(
                      ready: _apiKeyReady,
                      readyText: '统一 API Key 已读取',
                      missingText: '统一 API Key 未读取',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _SectionCard(
                  title: '语音合成',
                  subtitle: '启动时读取本机加密配置中的非密钥参数',
                  children: [
                    const _MetaLine(label: '密钥来源', value: '统一火山引擎 API Key'),
                    const SizedBox(height: 12),
                    _MetaLine(label: '资源', value: _ttsResourceId),
                    _MetaLine(label: '伙伴声音', value: _ttsSpeaker),
                  ],
                ),
                const SizedBox(height: 16),
                const _SectionCard(
                  title: '语音识别',
                  subtitle: '跟读评分与聊天识别使用 BigASR',
                  children: [
                    _MetaLine(label: '识别模式', value: 'BigASR 闯关评分'),
                    _MetaLine(label: '密钥来源', value: '统一火山引擎 API Key'),
                  ],
                ),
                const SizedBox(height: 16),
                _SectionCard(
                  title: 'AI 对话',
                  subtitle: '未读取到远程配置时保留本地示例回复',
                  children: [
                    const _MetaLine(label: '密钥来源', value: '统一火山引擎 API Key'),
                    _MetaLine(label: 'App ID', value: _realtimeAppId),
                  ],
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Tomato English Happy Talking v1.0.0\n密钥材料只从本机加密配置读取，不在应用页面中手动填写。',
                      style: GoogleFonts.nunito(
                        color: Colors.grey[700],
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style:
                  GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.ready,
    required this.readyText,
    required this.missingText,
  });

  final bool ready;
  final String readyText;
  final String missingText;

  @override
  Widget build(BuildContext context) {
    final color = ready ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(ready ? Icons.check_circle : Icons.info_outline, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ready ? readyText : missingText,
              style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: AppTheme.darkBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: GoogleFonts.nunito(
                color: Colors.grey[600],
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.nunito(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
