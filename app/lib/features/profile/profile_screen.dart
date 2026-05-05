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
  // TTS controllers
  final _ttsApiKeyCtrl = TextEditingController();
  final _ttsResourceIdCtrl = TextEditingController();
  String _selectedSpeakerId = '';

  // Realtime / BigASR controllers
  final _realtimeAppIdCtrl = TextEditingController();
  final _realtimeKeyCtrl = TextEditingController();
  final _bigAsrKeyCtrl = TextEditingController();

  bool _loading = true;
  String? _saveMessage;
  bool _saveMessageIsError = false;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    _ttsApiKeyCtrl.text = await AppConfig.volcTtsApiKey;
    _ttsResourceIdCtrl.text = await AppConfig.volcTtsResourceId;
    final savedSpeakerId = await AppConfig.volcTtsSpeakerId;
    final hasMatchedSpeaker = TtsService.voices.any((voice) => voice.id == savedSpeakerId);
    _selectedSpeakerId = hasMatchedSpeaker
        ? savedSpeakerId
        : (TtsService.voices.isNotEmpty ? TtsService.voices.first.id : '');
    _realtimeAppIdCtrl.text = await AppConfig.volcRealtimeAppId;
    _realtimeKeyCtrl.text = await AppConfig.volcRealtimeApiKey;
    _bigAsrKeyCtrl.text = await AppConfig.volcBigAsrApiKey;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveTts() async {
    final apiKey = _ttsApiKeyCtrl.text.trim();
    final resourceId = _ttsResourceIdCtrl.text.trim();

    if (apiKey.isEmpty) {
      _showMessage('请先填写 TTS 2.0 API Key', isError: true);
      return;
    }

    if (resourceId.isEmpty) {
      _showMessage('请先填写 TTS 2.0 Resource ID', isError: true);
      return;
    }

    if (_selectedSpeakerId.isEmpty) {
      _showMessage('请先选择 Speaker', isError: true);
      return;
    }

    await AppConfig.saveVolcTtsV3(
      apiKey: apiKey,
      resourceId: resourceId,
      speakerId: _selectedSpeakerId,
    );
    _showMessage('Doubao TTS 2.0 配置已保存');
  }

  Future<void> _saveRealtime() async {
    await AppConfig.saveVolcRealtime(
      appId: _realtimeAppIdCtrl.text.trim(),
      accessKey: _realtimeKeyCtrl.text.trim(),
    );
    _showMessage('Realtime API Key 已保存');
  }

  Future<void> _saveBigAsr() async {
    await AppConfig.saveVolcBigAsr(apiKey: _bigAsrKeyCtrl.text.trim());
    _showMessage('BigASR API Key 已保存');
  }

  void _showMessage(String msg, {bool isError = false}) {
    setState(() {
      _saveMessage = msg;
      _saveMessageIsError = isError;
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _saveMessage = null;
          _saveMessageIsError = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _ttsApiKeyCtrl.dispose();
    _ttsResourceIdCtrl.dispose();
    _realtimeAppIdCtrl.dispose();
    _realtimeKeyCtrl.dispose();
    _bigAsrKeyCtrl.dispose();
    super.dispose();
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
                if (_saveMessage != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: _saveMessageIsError ? Colors.red[50] : Colors.green[50],
                      border: Border.all(
                        color: _saveMessageIsError ? Colors.red : Colors.green,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _saveMessageIsError ? Icons.error_outline : Icons.check_circle,
                          color: _saveMessageIsError ? Colors.red : Colors.green,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _saveMessage!,
                          style: GoogleFonts.nunito(
                            color: _saveMessageIsError ? Colors.red[800] : Colors.green[800],
                          ),
                        ),
                      ],
                    ),
                  ),

                // ─── 火山引擎 TTS ───
                _SectionCard(
                  title: '🌋 Doubao TTS 2.0（语音合成）',
                  subtitle: '配置项：API Key + Resource ID + Speaker',
                  children: [
                    _KeyField(
                        ctrl: _ttsApiKeyCtrl,
                        label: 'API Key',
                        hint: 'X-Api-Key',
                        obscure: true),
                    const SizedBox(height: 12),
                    _KeyField(
                        ctrl: _ttsResourceIdCtrl,
                        label: 'Resource ID',
                        hint: 'seed-tts-2.0'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedSpeakerId.isNotEmpty ? _selectedSpeakerId : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Speaker',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                        isDense: true,
                      ),
                      style: GoogleFonts.nunito(fontSize: 13, color: Colors.black87),
                      items: TtsService.voices
                          .map(
                            (voice) => DropdownMenuItem<String>(
                              value: voice.id,
                              child: Text('${voice.name} (${voice.id})'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }

                        setState(() {
                          _selectedSpeakerId = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    _SaveButton(label: '保存 TTS 2.0 配置', onPressed: _saveTts),
                  ],
                ),

                const SizedBox(height: 16),

                // ─── Realtime 语音对话 ───
                _SectionCard(
                  title: '🎙️ 端到端实时语音模型（聊天）',
                  subtitle: '用于聊天文本/语音实时对话能力',
                  children: [
                    _KeyField(
                        ctrl: _realtimeAppIdCtrl,
                        label: 'App ID',
                        hint: 'X-Api-App-ID'),
                    const SizedBox(height: 12),
                    _KeyField(
                        ctrl: _realtimeKeyCtrl,
                        label: 'Access Key',
                        hint: 'X-Api-Access-Key',
                        obscure: true),
                    const SizedBox(height: 12),
                    _SaveButton(label: '保存 Realtime 配置', onPressed: _saveRealtime),
                  ],
                ),

                const SizedBox(height: 16),

                // ─── BigASR STT ───
                _SectionCard(
                  title: '🗣️ BigASR（聊天语音识别）',
                  subtitle: '用于聊天语音输入识别',
                  children: [
                    _KeyField(
                        ctrl: _bigAsrKeyCtrl,
                        label: 'API Key',
                        hint: 'BigASR API Key',
                        obscure: true),
                    const SizedBox(height: 12),
                    _SaveButton(label: '保存 BigASR 配置', onPressed: _saveBigAsr),
                  ],
                ),

                const SizedBox(height: 24),

                // ─── About ───
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '关于',
                          style: GoogleFonts.nunito(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tomato English Happy Talking v1.0.0\n所有 API Key 均加密存储在本机，不上传任何服务器。',
                          style: GoogleFonts.nunito(
                              color: Colors.grey[600], fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),
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
              style: GoogleFonts.nunito(
                  fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _KeyField extends StatelessWidget {
  const _KeyField({
    required this.ctrl,
    required this.label,
    required this.hint,
    this.obscure = false,
  });
  final TextEditingController ctrl;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
        isDense: true,
      ),
      style: GoogleFonts.nunito(fontSize: 13),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(label, style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
      ),
    );
  }
}
