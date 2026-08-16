# 跟读功能排查专项规则

> 排查录音、ASR、评分、播放或跟读状态时必读。

## 跟读功能排查工作流

跟读流程：

```text
1. NlpService.splitSentences(text)          -> List<String>
2. TtsService.synthesize(sentence)          -> List<int> MP3 bytes
3. just_audio AudioPlayer.play(bytes)       -> play audio
4. record AudioRecorder.start(path)         -> start recording WAV
5. record AudioRecorder.stop()              -> WAV file path
6. RecognitionBasedAssessmentEngine.assess -> selected ASR provider + heuristic score
7. ScoreDisplayWidget.show(result)          -> render score
```

排查关键文件：

- `app/lib/services/tts_service.dart`
- `app/lib/services/streaming_asr_service.dart`
- `app/lib/services/recognition_based_assessment_service.dart`
- `app/lib/services/scoring_service.dart`（仅保留兼容数据结构 / mock stub）
- `app/lib/features/follow_read/providers/follow_read_provider.dart`
- `app/lib/features/follow_read/follow_read_screen.dart`
- `app/lib/features/web_shell/web_shell_screen.dart`
- `app/android/app/src/main/AndroidManifest.xml`
- `app/android/app/build.gradle.kts`

常见检查项：

- WAV 是否为 16kHz 16bit mono PCM。
- `AppConfig.asrProvider`、所选 ASR 模型和对应凭据是否与预期一致。
- `StreamingAsrService` 是否通过所选 ASR Provider 拿到非空识别文本；只有 `asr_provider=volcengine` 时才按火山 SAUC 协议与当前 `volc_asr_model`（SeedASR / BigASR）的 Resource-Id 排查，不要默认写成 BigASR。
- `RecognitionBasedAssessmentEngine` 是否正确处理空识别、错词、漏读和明确标记的测试 fallback。
- `just_audio` 播放完毕事件是否正确触发下一步。
- Provider 的 `isRecording` 状态是否被 UI 正确监听。
- WebView bridge 是否把 `follow.state` / `avatar.state` 推给 Web UI。
- Android 是否声明并实际申请 `RECORD_AUDIO` 权限。
- 模拟器问题优先用 `.\tools\run_android_debug.ps1` 复现。
