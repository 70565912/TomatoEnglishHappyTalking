# 音乐、听力与跟读专项规则

> 处理歌曲、听力、字幕、TTS 复用或跟读自动停止时必读。

- 歌曲生成来源支持阿里云百聆（Fun-Music）、Suno（系统浏览器）与 ElevenLabs Music；默认 provider 仍是 Suno，但设置页可选择 `bailian_fun_music` 或 `elevenlabs_music`。不要重新引入 MiniMax 歌曲 API、`TOMATO_MINIMAX_API_KEY`、`MiniMax.txt` 或 Web UI 中的 MiniMax/其它来源选项。歌曲状态模型放在 `app/lib/data/models/article_song_model.dart`，供本地歌曲缓存、播放、字幕时间轴和视频导出复用。
- 阿里云百聆（Fun-Music）入口为 `app/lib/services/bailian_music_service.dart`，通过阿里云 DashScope `https://dashscope.aliyuncs.com/api/v1/services/audio/music/generation` 生成音频；使用 `AppConfig.aliyunBailianApiKey` 与 `AppConfig.aliyunBailianMusicModel`，提交前先把过长或散文化章节压缩成适合歌曲接口的 `submittedLyrics`，再走 `ContentSafetyService`。成功音频写入 `ApiCacheService` 的 `music/` 子目录，metadata 必须记录 `submittedLyrics`、`lyricsHash` 和 `lyricsCompressed`；供应商错误直接显示，不自动回退到 Suno。
- Suno 生成走 **系统浏览器手动流程**（`app/lib/features/web_shell/suno/suno_external_launcher.dart`）：`listening.songGenerate (suno)` 复制整篇英文歌词到系统剪贴板，并用系统浏览器打开 `https://suno.com/create`；**不在 App 内 WebView 填表、不导航主 WebView 到 suno.com、不提供 Suno 顶栏**。用户在浏览器登录、粘贴、设风格、Create 并下载 MP3 后，回到创作中心用「导入本地音乐」添加版本。返回 `manualActionMessage` 指引用户，不进入 `generating` 自动化轮询。
- 历史 Suno 自动化（WebView 填表、Library 扫描、「检测下载」、`SunoAutomationController` 等）已移除；Lexical 键盘崩溃与踩坑归档见 `docs/suno_lexical_lyrics_editor.md`。
- 文章歌曲版本归属 `articleId`：`listening.songState` 必须列出该文全部本地有效版本，**禁止**用当前 `lyricsHash` / `contentHash` 过滤已落盘 cache。`lyricsHash` 仅用于新 cache 条目的 dedup 与 metadata 记录；删除/更新必须就地改对应 cache 行并清理 mp3/metadata，禁止整包 rewrite 到当前 hash 产生孤儿文件。规则见 `docs/article_song_version_retention.md`。
- Suno 历史缓存与外部导入歌曲的音频和 metadata 必须保存在持久目录 `suno-music/`。如果旧缓存或设置指向 `.tmp` / 系统临时目录，应通过 `AssetPathService` 迁移或忽略该设置，不要继续把可复用歌曲资产写到临时目录。
- 歌曲字幕时间轴使用歌曲版本记录的 `submittedLyrics` 作为展示文本；所选 ASR Provider 在需要词级锚点时只提供时间，不改写展示文本。如果 `submittedLyrics` 与文章原歌词不同，不要复用文章逐句中文翻译。不要把 ASR 识别文本写回文章、歌词或字幕正文。歌曲播放通过 `listening.song.position` 推送当前 cue；歌曲版视频录制必须先有 `timelinePath`。
- 字幕 ASR 语言由 `SongSubtitleTimelineService.lyricsAsrLanguage` 根据歌词是否含 CJK 自动选择：`en-US` 或 `zh-CN`；中文歌词按字级 token 对齐。含 CJK 的字幕生成必须走**火山引擎 ASR** 的词级时间（`show_utterances`），使用设置里当前的火山 ASR 模型（默认/推荐 SeedASR 2.0；BigASR 1.0 仅为可选旧模型，计费与 Resource-Id 不同，不要把它当成“火山 ASR”的统称或必开项）；当前 `asr_provider` 为阿里云时直接报错提示切换火山，不要用百炼 ASR 硬撑中文时间轴。
- Suno 下载的音频和 metadata 必须保存在持久目录 `suno-music/`。如果旧缓存或设置指向 `.tmp` / 系统临时目录，应通过 `AssetPathService` 迁移或忽略该设置，不要继续把可复用歌曲资产写到临时目录。
- 听力播放、全屏播放和普通录制只播放英文 TTS；中文翻译只作为字幕/对照文本显示，不再触发听力中文 TTS 预加载或播放。`listening.fullscreenReady` 只检查当前和下一句英文音频，绘本图片只预取当前和下一张；文章保存时应优先保存导入译文，缺失时可用 `PracticeTextService.translateToChinese` 生成逐句字幕，后续听力/跟读只读库中译文，不在打开页面时批量翻译。
- 文章一旦保存并完成分句，`articles.sentences` 就是听力音频、字幕、逐句翻译、绘本、歌曲和导出的持久化边界；打开文章、查询素材状态、播放、导出和列表展示都必须读取已持久化句子，不得重新分句并写回。需要改变分句时只能重建文章并重新生成相关素材。
- 老文章的已生成听力材料要按持久化句子文本直接复用，即使当时使用的是旧平台、旧音色或旧 `follow_tts` / `listening_tts` 引用；状态查询、播放、全屏 readiness 和视频导出 readiness 应先按文章一次性建立本地音频句柄索引，再按句子文本查找，避免逐句重复扫描缓存导致“读取中”或播放卡住。
- 跟读录音可根据**当前所选 ASR Provider** 的实时识别文本自动停止：只有识别结果达到参考句覆盖率并匹配句尾时才触发，避免只说末尾短语就结束。相关启发式在 `follow_read_provider.dart`，更新阈值时同步 `follow_recording_auto_stop_test.dart`。不要把该能力写成“必须调用 BigASR”。
