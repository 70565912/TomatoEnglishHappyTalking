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
  bool _saving = false;
  bool _englishVoicesOnly = false;
  String _selectedSpeakerId = TtsService.defaultVoiceType;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadConfigStatus();
  }

  Future<void> _loadConfigStatus() async {
    final speakerId = (await AppConfig.volcTtsSpeakerId).trim();
    final resolvedSpeakerId = TtsService.isPresetVoice(speakerId)
        ? speakerId
        : TtsService.defaultVoiceType;

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedSpeakerId = resolvedSpeakerId;
      _loading = false;
    });
  }

  Future<void> _saveSpeaker() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    await AppConfig.saveVolcTtsSpeakerId(_selectedSpeakerId);
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      _message = '声音设置已保存';
    });
  }

  String _voiceLabel(VoiceInfo voice) =>
      '${voice.name} · ${_displayVoiceLanguage(voice.lang)} · ${voice.scene}';

  String _displayVoiceLanguage(String lang) {
    if (lang.contains('英语') ||
        lang.contains('English') ||
        lang.contains('日文') ||
        lang.contains('印尼') ||
        lang.contains('西班')) {
      return lang;
    }
    return lang.replaceAll('中文', '中文/英文');
  }

  bool _isEnglishCapableVoice(VoiceInfo voice) {
    final lang = voice.lang.trim();
    if (lang.contains('英语') ||
        lang.contains('英文') ||
        lang.toLowerCase().contains('english')) {
      return true;
    }
    final id = voice.id.trim();
    return id.startsWith('en_') ||
        id.startsWith('en-') ||
        id.contains('_en_') ||
        id.contains('ICL_uranus_en_');
  }

  VoiceInfo _voiceById(String id) {
    for (final voice in TtsService.voices) {
      if (voice.id == id) {
        return voice;
      }
    }
    return VoiceInfo(
      id: id,
      name: id,
      lang: '未知',
      scene: '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleVoices = _englishVoicesOnly
        ? TtsService.voices.where(_isEnglishCapableVoice).toList(growable: false)
        : TtsService.voices;
    final selectedVisible =
        visibleVoices.any((voice) => voice.id == _selectedSpeakerId);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('声音设置'),
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
                  title: '练习伙伴声音',
                  subtitle: '选择 Doubao TTS 2.0 发音人',
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('只显示英文声音'),
                      value: _englishVoicesOnly,
                      onChanged: _saving
                          ? null
                          : (value) {
                              setState(() {
                                _englishVoicesOnly = value ?? false;
                              });
                            },
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'voice-filter-$_englishVoicesOnly-$_selectedSpeakerId',
                      ),
                      initialValue: _selectedSpeakerId,
                      isExpanded: true,
                      menuMaxHeight: 420,
                      decoration: const InputDecoration(
                        labelText: '选择声音',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        if (_englishVoicesOnly && !selectedVisible)
                          DropdownMenuItem(
                            value: _selectedSpeakerId,
                            child: Text(
                              '当前声音 · ${_voiceLabel(_voiceById(_selectedSpeakerId))}',
                            ),
                          ),
                        ...visibleVoices.map(
                          (voice) => DropdownMenuItem(
                            value: voice.id,
                            child: Text(_voiceLabel(voice)),
                          ),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _selectedSpeakerId = value;
                                _message = null;
                              });
                            },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: _saving ? null : _saveSpeaker,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                          ),
                          child: Text(_saving ? '保存中' : '保存声音设置'),
                        ),
                        if (_message != null) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _message!,
                              style: GoogleFonts.nunito(
                                color: Colors.grey[700],
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
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
              style: GoogleFonts.nunito(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: GoogleFonts.nunito(
                color: Colors.grey[700],
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
