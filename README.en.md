<div align="center">
  <img src="app/assets/web/assets/ui/lego/brand-tomato.png" width="104" alt="Tomato English Happy Talking">
  <h1>Tomato English Happy Talking</h1>
  <p><strong>Turn an English or bilingual article into learning material children can listen to, read, speak, and share.</strong></p>
  <p>A local-first English content workspace for parents and teachers, available on Windows and Android.</p>
  <p>
    <a href="README.md">简体中文</a> ·
    <a href="README.en.md">English</a>
  </p>
  <p>
    <a href="https://github.com/70565912/TomatoEnglishHappyTalking/releases/latest"><img src="https://img.shields.io/github/v/release/70565912/TomatoEnglishHappyTalking?label=Release" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Android-2563EB" alt="Windows and Android">
    <a href="LICENSE"><img src="https://img.shields.io/github/license/70565912/TomatoEnglishHappyTalking" alt="Apache-2.0 license"></a>
    <img src="https://img.shields.io/badge/Flutter-3.41.9-02569B?logo=flutter" alt="Flutter 3.41.9">
  </p>
  <p>
    <a href="https://github.com/70565912/TomatoEnglishHappyTalking/releases/latest"><strong>Download Windows ZIP / Android APK</strong></a>
    · <a href="https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose">Report a problem or idea</a>
  </p>
</div>

![Tomato product overview](docs/readme/product-overview.webp)

## From an article to complete learning material

![Tomato four-step workflow](docs/readme/workflow.webp)

1. **Import an article:** paste English or bilingual content and organize it by book and chapter.
2. **Create material:** review picture-book scenes, generate illustrations and sentence audio, or create/import a song.
3. **Start practicing:** use picture-book listening, sentence shadowing, recognition-based scoring, and chapter conversation.
4. **Export and share:** export listening or song videos with SRT or burned-in subtitles.

[Ask a question](https://github.com/70565912/TomatoEnglishHappyTalking/discussions) · [Suggest a feature](https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose) · [View the roadmap](ROADMAP.md)

## Public engineering evaluations

Tomato publishes failed cases, rejected approaches, repeated trials, and scope limits—not only passing
test counts. These reports may help engineers choosing tools for English NLP, on-device Flutter AI,
subtitle alignment, and generative content workflows.

| Evaluation | Useful finding | Report |
| --- | --- | --- |
| Constrained syntax task for text LLMs | Aliyun `qwen3.7-max` (P7) and Volcengine `DeepSeek V4 Flash` (P8) each reached 30/30 across three runs; Doubao Lite/Pro did not meet the production gate, and all five disputed Lite paths were rejected by human review | [V3.3 acceptance report](docs/read_aloud_sentence_split_v3_3_implementation_report.md) · [Lite human review](docs/volcengine_doubao_lite_sentence_split_human_review.md) |
| UDPipe / Stanza / spaCy | On 10 difficult main-predicate-root probes: Stanza 10/10, official UDPipe reference 8/10, spaCy 7/10; production UDPipe is soft structural evidence, not the sole judge | [Parser comparison](docs/parser-comparison-evaluation.md) |
| Picture-book chapter planning prompt | The final 12 responses across four article structures had zero structural failures; expository scene-count standard deviation fell from 2.49 to 0.47, while wording and boundaries still require review | [Scene-planning tuning report](docs/picture_book_chapter_plan_scene_split_tuning.md) |
| Local subtitle alignment / BigASR | MMS CTC was a replacement candidate on 3/4 English samples at mean CPU RTF about 0.88; the hard long-Suno case still requires BigASR fallback | [Overview](docs/archive/ctc_forced_aligner_subtitle_eval_20260801/README.md) · [Round 1](docs/archive/ctc_forced_aligner_subtitle_eval_20260801/reports/summary.md) · [Round 2](docs/archive/ctc_forced_aligner_subtitle_eval_20260801/reports/summary_round2.md) |
| Real ASR snapshot regression | E03/E07/E13/E16 preserve missing-word, repeated-word, and weak-anchor failures for offline subtitle-DP regression without another paid ASR call | [Method and evidence index](docs/testing-and-evaluation.md#5-真实-asr-时间轴快照回归) |
| Windows/WebView/Bridge QA | In-app Suno Lexical keyboard failures were isolated to WebView2; `article.list` fell from 62,752,595 B to 64,485 B | [Suno isolation report](docs/suno_lexical_lyrics_editor.md) · [Bridge/Release QA](docs/bridge-payload-release-qa-evaluation.md) |

**[Open the complete testing and evaluation index, including methods, process, limitations, and reproduction entry points](docs/testing-and-evaluation.md)**

Sentence-segmentation performance is useful proxy evidence for English structural understanding and strict
instruction following, which also matter in translation and scene planning. It is not a direct substitute
for translation-fidelity or visual-storytelling benchmarks. Rankings apply only to the named model IDs,
protocols, and samples.

### Visual super-resolution A/B

The full E07 illustration locates two inspection regions. The rows below enlarge Alice's face/hair and the
crocodile's eye/teeth using exactly the same field of view. The input uses nearest-neighbor zoom so its source
pixels remain visible; the right side is the real output of the Windows bundle's `Real-ESRGAN NCNN Vulkan`
4x model. Click the comparison to open the 1800px original.

[![Windows local Real-ESRGAN 4x same-region detail comparison](docs/readme/upscale-comparison.webp)](docs/readme/upscale-comparison.webp)

[Raw 320×180 input PNG](docs/readme/upscale-evidence/input-320x180.png) ·
[Real 1280×720 output PNG](docs/readme/upscale-evidence/output-1280x720.png)

This is visual and pipeline evidence, not a multi-model perceptual-quality ranking.

## Public showcase

The frame below comes from Tomato's real local 1080p export of E07, *Am I Still Alice*, with burned-in English and Chinese subtitles. Click it to open the complete *Alice's Adventures in Wonderland* collection.

[![View the Tomato E07 picture-book listening output](docs/readme/demo-alice-e07.webp)](https://wap.qupeiyin.cn/app/v736/albumShare?shareUid=MDAwMDAwMDAwMLGdxGaAscyUsbeEcg&albumId=MDAwMDAwMDAwMLCHpmKAsa7e)

**[View all 41 videos](https://wap.qupeiyin.cn/app/v736/albumShare?shareUid=MDAwMDAwMDAwMLGdxGaAscyUsbeEcg&albumId=MDAwMDAwMDAwMLCHpmKAsa7e)** · [Full E03 on English Fun Dubbing](https://movie.qupeiyin.com/home/share/original_video/app/1/course/MDAwMDAwMDAwMLCHxKqCe7rdsMp0cg/uid/MDAwMDAwMDAwMLGdxGaAscyUsbeEcg) · [Full E09 on English Fun Dubbing](https://movie.qupeiyin.com/home/share/original_video/app/1/course/MDAwMDAwMDAwMLCHxKuCe67bsKR0cg/uid/MDAwMDAwMDAwMLGdxGaAscyUsbeEcg)

The *Alice's Adventures in Wonderland* read-along collection was produced with Tomato and published as 41 sequential learning videos. [View the complete collection on the English Fun Dubbing mobile page](https://wap.qupeiyin.cn/app/v736/albumShare?shareUid=MDAwMDAwMDAwMLGdxGaAscyUsbeEcg&albumId=MDAwMDAwMDAwMLCHpmKAsa7e). These full-version links are hosted by a third party, so availability and playback behavior depend on that platform.

## Who it is for

- Parents who want to turn a child's current English stories into picture-book listening material.
- Teachers preparing listening and speaking material from their own articles.
- Individuals who want their library, audio, images, and videos stored locally without running a private backend.
- Advanced users willing to configure and pay for their own cloud AI services.

## What makes it different

Tomato is not a level-based app with a fixed course catalog. It builds a complete workflow around your own articles. Persisted sentences, translations, reviewed picture-book scenes, listening audio, shadowing, chapter conversation, songs, and exported videos all remain attached to the same book and chapter. Successful generated assets are reused from local cache before another cloud request is made.

## Core capabilities

- Import English or bilingual text and save it as book chapters.
- Review a chapter-level picture-book plan before generating a sequential image group.
- Generate and cache sentence-level English TTS with full-screen picture-book listening.
- Record shadowing, recognize speech, and provide recognition-based pronunciation scoring.
- Practice English conversation grounded in the current chapter.
- Generate or import songs and create lyric timelines from ASR timing.
- Export listening or song videos with SRT or burned-in subtitles.
- Run bundled Real-ESRGAN NCNN Vulkan 2x/4x picture-book upscaling locally on Windows.

## Platform support

| Capability | Windows | Android |
| --- | :---: | :---: |
| Library, chapters, and Creation Center | Yes | Yes |
| Picture books, listening, shadowing, and conversation | Yes | Yes |
| Song and subtitled-video workflows | Yes | Yes |
| Local Real-ESRGAN picture-book upscaling | Yes, Vulkan required | Not available |
| GitHub package | ZIP | APK with current test signing |

## Before you start

- The project does not provide cloud accounts or API keys. Text, image, TTS, ASR, realtime conversation, and music requests are billed by the provider you select.
- The Windows and Android clients call your configured cloud services directly; no private Tomato backend is required.
- Articles, databases, downloaded and generated assets, caches, logs, and settings stay on the local device.
- Releases do not contain developer accounts, API keys, local databases, caches, logs, or generated user content.
- Suno uses a manual system-browser workflow; download the song there and import the local MP3 in Creation Center.

See the [cloud service setup guide](docs/cloud-service-setup.md) for provider and key details.

## Download and install

Open the [latest release](https://github.com/70565912/TomatoEnglishHappyTalking/releases/latest):

- **Windows:** download `tomato_english_happy_talking-windows-*.zip`, extract it, and run `tomato_english_happy_talking.exe`. Microsoft Edge WebView2 Runtime is required; local upscaling also requires a Vulkan-capable GPU.
- **Android:** download and sideload `tomato_english_happy_talking-android-*.apk`. The current public APK uses the project's test signing configuration and is not store-signed.
- When a release includes `SHA256SUMS.txt`, use it to verify downloaded assets before installation.

## More screens

| Creation Center | Listening and picture book |
| --- | --- |
| ![Creation Center](docs/readme/creation-center.png) | ![Listening and picture book](docs/readme/listening-preview.webp) |

| Shadowing | Chapter conversation |
| --- | --- |
| ![Shadowing](docs/readme/follow-preview.webp) | ![Chapter conversation](docs/readme/chat-preview.webp) |

Song generation, subtitles, and video/audio export:

![Song and video export](docs/readme/song-video-preview.webp)

## Author and origin

- Author: 兔子先生 / Ryan Chen
- Email: [70565912@qq.com](mailto:70565912@qq.com)

The app began as an AI-assisted English practice tool that Ryan built for his child, “Tomato.” The original goal was simple: turn any article the child was reading into an English picture-book video while supporting everyday listening and speaking practice. It has since grown into a workspace for books, chapters, picture books, listening, shadowing, conversation, songs, and video export.

## Local and cloud boundaries

| Area | How it is handled |
| --- | --- |
| Library, sentences, translation mappings, asset indexes | Local SQLite |
| API keys | Local secure storage; the bridge exposes masked status only |
| Image upscaling | Local Real-ESRGAN NCNN Vulkan on Windows |
| Text, images, TTS, ASR, realtime conversation | Aliyun or Volcengine, depending on settings |
| Suno songs | Manual system-browser workflow, followed by local import |
| Export and diagnostics | Local filesystem |

## Documentation

- [User guide and screenshots](docs/user-guide/)
- [Cloud service setup](docs/cloud-service-setup.md)
- [Development and build guide](docs/development-guide.md)
- [AI CLI / remote QA guide](docs/ai_cli_qa_remote_guide.md)
- [Testing and evaluation reports](docs/testing-and-evaluation.md)
- [English dependency-parser comparison](docs/parser-comparison-evaluation.md)
- [Flutter/Web bridge payload and Release QA evaluation](docs/bridge-payload-release-qa-evaluation.md)
- [Change log](docs/change_log.md)
- [Roadmap](ROADMAP.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## Built with

The main application uses [Flutter](https://github.com/flutter/flutter), with a React, Vite, and TypeScript Web UI. The project also uses or integrates [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), [ncnn](https://github.com/Tencent/ncnn), [FFmpeg](https://github.com/FFmpeg/FFmpeg), [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview), and [just_audio](https://github.com/ryanheise/just_audio). Third-party components, models, fonts, and media remain subject to their own licenses and terms.

## Participate

Use [Discussions](https://github.com/70565912/TomatoEnglishHappyTalking/discussions) for questions and showcases, or [Issue Forms](https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose) for bugs and feature requests. Remove API keys, accounts, local paths, databases, and unredacted logs before posting.

If Tomato helps your family or teaching workflow, starring the repository helps other people with the same need discover it.

## License

The project is open sourced under the [Apache License 2.0](LICENSE). Cloud services, third-party models, fonts, media, and generated user content remain subject to their own terms.
