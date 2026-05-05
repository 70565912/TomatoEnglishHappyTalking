---
description: "Use when debugging Tomato English Happy Talking follow-read issues such as TTS playback, microphone recording, Azure pronunciation scoring, permission problems, timing bugs, or device-only regressions. Prefer reproducing with the repository root scripts instead of defaulting to raw flutter run commands."
argument-hint: "Describe the symptom (e.g. 'Android emulator can record but score never appears')"
agent: "agent"
tools: [read, search, edit]
---

帮我排查「Tomato English Happy Talking」跟读功能的完整数据流问题。

## 运行与复现

如需先复现问题，请优先使用 `tools/` 下脚本：

- Windows 调试：`./tools/build_windows.ps1 -Run`
- Android 已连接设备调试：`./tools/build_android.ps1 -Run -DeviceId <device-id>`
- 启动模拟器并调试：`./tools/run_android_debug.ps1`

只有在怀疑脚本层本身有问题时，才退回到裸 `flutter` 命令。

## 跟读流程概览

```
1. NlpService.splitSentences(text)          → List<String> 句子列表
2. TtsService.synthesize(sentence)          → List<int> MP3 字节
3. just_audio AudioPlayer.play(bytes)       → 播放音频
4. record AudioRecorder.start(path)         → 开始录音（WAV 16kHz）
5. record AudioRecorder.stop()              → 返回 WAV 文件路径
6. ScoringService.assess(wavBytes, refText) → PronunciationResult
7. ScoreDisplayWidget.show(result)          → 显示评分
```

## 排查步骤

请检查以下关键文件，定位问题所在：

1. **`app/lib/services/tts_service.dart`** — TTS 调用是否成功？返回非 null？
2. **`app/lib/services/scoring_service.dart`** — Azure 调用是否成功？Header 格式是否正确？
3. **`app/lib/features/follow_read/providers/follow_read_provider.dart`** — 状态转换是否正确？录音结束后是否触发 assess？
4. **`app/lib/features/follow_read/follow_read_screen.dart`** — UI 是否正确监听 Provider 状态？AsyncValue.error 是否显示？
5. **`app/android/app/src/main/AndroidManifest.xml`** — 若问题只出现在 Android，检查录音权限、应用标签和原生配置是否影响流程。
6. **`app/android/app/build.gradle.kts`** — 若问题只出现在 Android，检查当前 package `com.example.tomato_english_happy_talking` 与构建配置是否一致。

## 常见问题检查项

- [ ] Azure `Pronunciation-Assessment` Header 是否 Base64 编码正确？
- [ ] WAV 格式是否为 16kHz 16bit mono PCM？（`record` 包需要配置）
- [ ] `just_audio` 播放完毕事件是否触发了录音开始？
- [ ] `ScoringService` 在 Key 未配置时是否返回 mock 而非 null？
- [ ] Provider 的 `isRecording` 状态是否在 UI 中正确反映？
- [ ] Android 端是否已声明并实际申请 `RECORD_AUDIO` 权限？
- [ ] 若问题只在模拟器出现，是否已经通过 `./tools/run_android_debug.ps1` 复用了当前 D 盘 AVD 环境？

## 输出期望

请提供：
1. 找到的问题描述（文件 + 行号）
2. 修复建议或直接修复代码
3. 如果是时序问题，给出正确的 await 顺序
4. 如果问题与运行环境有关，明确指出应走哪个根目录脚本复现或验证
