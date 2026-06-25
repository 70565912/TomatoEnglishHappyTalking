# Tomato English Happy Talking

Tomato English Happy Talking is a standalone Flutter app for AI-assisted
English listening, speaking, picture-book, song, and video practice.

It runs without a private backend. The Windows and Android clients call the
configured cloud AI services directly, while all learning content, generated
assets, playback cache, diagnostics, and user settings stay on the local device.

The project is open sourced under the Apache License 2.0. See
[LICENSE](LICENSE) for details. Cloud services, third-party models, fonts,
media, and generated user content remain subject to their own terms.

## Author And Origin

- Author: 兔子先生 / Ryan Chen
- Email: 70565912@qq.com

This app started as a personal tool for my child, Tomato. The original goal was
to use AI services to make better English picture-book videos and listening /
speaking practice material than the tools I had tried before. As the app grew,
it also became a local workflow for producing English learning content, testing
AI service quality across providers, and preparing structured material that can
be reused in model evaluation or training workflows.

## What It Does

- Imports English or bilingual text and saves it as book chapters.
- Organizes learning material around books, chapters, listening, shadowing, and
  conversation practice.
- Generates picture-book scenes for a full chapter after a prompt review step.
- Creates or imports song versions for chapter lyrics, then builds subtitle
  timelines from ASR timing.
- Plays chapter audio with cached TTS and optional full-screen picture-book
  playback.
- Supports follow-read recording and recognition-based pronunciation scoring.
- Provides English conversation practice based on chapter content.
- Exports listening and song videos with SRT or burned-in subtitles.
- Stores settings locally and avoids returning plaintext API keys through the
  Flutter/Web bridge.

## Current Platforms

- Windows desktop app: `tomato_english_happy_talking.exe`
- Android APK: `com.example.tomato_english_happy_talking`

The main UI is a bundled React/Vite WebView. Flutter owns native capabilities
such as local storage, secure settings, recording, playback, TTS, ASR, AI calls,
and file export.

## Architecture

```text
TomatoEnglishHappyTalking/
├── app/                  # Flutter app
│   ├── lib/              # Dart source
│   ├── assets/web/       # Built Web UI bundled into the app
│   ├── android/          # Android platform project
│   └── windows/          # Windows platform project
├── web_ui/               # React + Vite + TypeScript UI
├── tools/                # Build and local automation scripts
├── docs/                 # Design notes, migration notes, and change log
└── README.md
```

Runtime flow:

```text
React/Vite Web UI
        |
        | typed bridge commands/events
        v
Flutter WebShellScreen
        |
        +-- Riverpod providers
        +-- local SQLite and secure storage
        +-- recording and playback services
        +-- cloud AI service clients
        +-- export and diagnostic tooling
```

## Cloud Services

The app can be configured to use different providers for text, image, speech,
ASR, and music generation.

| Area | Supported provider path |
| --- | --- |
| Text generation | Aliyun Bailian OpenAI-compatible Chat Completions, Volcengine Ark |
| Picture-book images | Aliyun Wanxiang sequential images, Volcengine Seedream sequential images |
| TTS | Aliyun CosyVoice, Volcengine Doubao TTS 2.0 |
| ASR | Aliyun Qwen-ASR, Volcengine BigASR |
| Realtime conversation | Volcengine Realtime dialogue |
| Song generation | Aliyun Bailian Fun-Music, Suno web automation |

API keys are not included in this repository. Configure them from the app
settings page during local use. Do not commit keys, exported diagnostics, local
databases, generated media, or release runtime data.

## Requirements

The repository is developed on Windows. Other environments may work, but the
provided release scripts are PowerShell-based.

- Flutter stable SDK
- Dart SDK included with Flutter
- Node.js and npm for `web_ui/`
- Android SDK for APK builds
- Microsoft Edge WebView2 Runtime for the Windows app
- FFmpeg for video/audio export in the packaged Windows runtime

The original development machine uses Flutter under `D:\DevTools\flutter` and
Android SDK under `D:\Android\SDK`, but those paths are local conventions rather
than repository requirements.

## Quick Start

Install Flutter dependencies:

```powershell
cd app
flutter pub get
```

Install and build the Web UI:

```powershell
cd web_ui
npm install
npm run build
```

Build the Windows app from the repository root:

```powershell
.\tools\build_windows.ps1 -Release
```

Build the Android release APK:

```powershell
.\tools\build_android.ps1
```

Run Web UI tests:

```powershell
npm --prefix web_ui test
```

Run Flutter analysis:

```powershell
cd app
flutter analyze
```

## Build Scripts

### `tools/build_windows.ps1`

- Builds the bundled Web UI before the Flutter build.
- Supports Debug, Release, and optional `-Run`.
- Copies the runnable Windows app to `release/windows/tomato_english_happy_talking/`.
- Keeps runtime data in that local release directory during development.

### `tools/build_android.ps1`

- Builds an Android release APK.
- Copies the APK to `release/android/`.
- Can run Android Debug/Release on a connected device or emulator when invoked
  with the relevant flags.

Cold Android release builds may take more than 15 minutes while Gradle,
Flutter plugins, R8, resources, and mapping outputs initialize. Give automated
builds a wider timeout, especially on a clean machine.

## Release And Data Safety

The local Windows release directory is also a development runtime directory. It
may contain logs, diagnostics, databases, API cache, exported videos, imported
songs, generated audio, and old local configuration files.

For public distribution, do not zip that directory directly. Create a clean
staging folder containing only the executable, DLLs, Flutter `data/` assets,
FFmpeg, and required runtime files. Exclude at least:

- `logs/`
- `diagnostics/`
- `recording-export/`
- `suno-music/`
- API cache directories
- SQLite databases
- `security/`
- settings files
- any API key or token material

## Development Notes

- App feature work should keep Flutter services separate from UI state.
- Web UI must communicate with Flutter through the typed bridge protocol.
- Cloud calls should prefer local parsing, local cache, and saved business data
  before making new paid requests.
- Successful remote results may be cached; API keys, failed responses, mock
  fallbacks, and diagnostics with sensitive data must not be cached as reusable
  content.
- The default product model is a book/chapter learning workspace, not a game
  lobby or reward system.

More implementation details live under [docs/](docs/), especially the change
log, migration notes, prompt-review notes, and release/build troubleshooting
documents.

## License

Apache License 2.0. See [LICENSE](LICENSE).
