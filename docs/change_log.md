# 修改日志

## 2026-06-27

- 创作中心绘本面板新增“生成听力”按钮，位于“生成组图”后同一行；面板显示章节听力材料生成状态，缺失时可显式提交远程语音合成，完整时需确认覆盖后才重新生成。
- 新增 `listening.audioStatus` / `listening.audioGenerate` bridge 命令和 `listening.audioMaterial.progress` 事件；章节英文 TTS 统一作为 `listening_tts` 听力材料管理，`overwrite=false` 只补缺失，`overwrite=true` 清理当前文章 `listening_tts` 和旧 `follow_tts` 引用后全量重建。
- 听力打开、跟读打开、听力播放、全屏播放、视频导出 readiness 和跟读原音播放改为只检查本地听力材料缓存；缺失时明确提示“需要先在创作中心生成听力材料”，不再后台静默提交 TTS。
- 绘本提示词审核框重新打开时优先读取本地章节计划；如果 `story_chapters.summary_json` 缺失或不匹配，会尝试从旧 `picture_book_pages` prompt scene 恢复并写回；仍无法恢复时先打开可编辑的本地 fallback 审核框，不静默远程生成。
- 歌曲字幕匹配补强低信息词处理，避免 ASR 跳过弱词时抢占后续歌词锚点造成字幕过长或过短；新增 E07 真实 ASR fixture 和回归用例，作为后续歌词匹配算法改动的固定素材。
- 发布目录运行数据恢复：确认 `release/windows/tomato_english_happy_talking` 空库后，从最近有书的 runtime backup 恢复 `.dart_tool` 数据库和 `tomato_api_cache`，真实 release App 默认数据根读取到 20 篇文章、3 本书和 20 个章节。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\api_cache_service_test.dart --reporter expanded -j 1`
- `D:\DevTools\flutter\bin\flutter.bat test test\tts_memory_cache_service_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test -- App.test.tsx --testTimeout=20000`
- `npm --prefix web_ui run build`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `D:\PowerShell\7\pwsh.exe -Command ".\tools\build_windows.ps1 -Release"`
- 真实 release QA 联调：ready 样本 `articleId=46` 听力材料 `46/46 ready`，prepare/fullscreen/recording/play/follow 均通过；missing 样本 `articleId=52` 为 `0/53 missing`，prepare/fullscreen/play/recording/follow 均明确提示需要先在创作中心生成听力材料；联调前后 `api_cache_entries` 和 `api_cache_article_refs` 计数不变，确认未触发隐式远程 TTS。
- 默认 release 数据根验证：`article.list` 返回 20 篇文章，包含 `E10 - The Caucus Race`、`E07 - Am I Still Alice` 和 `E03 - Alice's Long Fall`。

## 2026-06-26

- 重写公开仓库首页 `README.md`：从内部开发状态长文档调整为面向 GitHub 访客的项目介绍，突出应用用途、平台、架构、云服务配置、快速开始、构建脚本和发布数据安全边界。
- README 保留作者信息和项目由来，但改为更适合公开首页阅读的简短表达；同时保留 Apache License、API Key 不入库、本地运行数据不应公开打包等关键信息。

## 2026-06-25

- 录制导出目录按类型分类：无内置字幕视频和 SRT 写入 `recording-export/srt/`，内置字幕视频写入 `recording-export/subtitled/`，歌曲音频导出写入 `recording-export/mp3/`；录制前按当前字幕模式检查对应子目录可写。
- 视频库扫描同时覆盖旧根目录文件和新的 `srt/`、`subtitled/` 子目录；`mp3/` 只作为音频导出目录，不参与视频库扫描。
- Web UI 与 mock payload 同步展示分类导出路径，歌曲音频导出提示改为 `recording-export/mp3`。
- Suno Create / 下载自动化加强候选判断：保存本次 Create 后继续回 Library 扫描后续候选，遇到不匹配详情页时按是否已有新版本决定停止或继续，避免把旧歌或错歌保存到当前文章；Styles 魔法棒定位排除 `View saved style prompts`。
- 发布文档补充 Windows 干净 zip 打包规则：对外包不能直接压缩本机发布运行目录，必须排除日志、诊断、缓存、数据库、导出媒体、`security/`、旧 key/settings 等运行数据。
- 发布文档补充 Android Release 外层 15 分钟超时排查：本次实测 Gradle 在 APK 生成后成功返回，但外层命令超时中断发布目录复制；后续自动化应预留 25-30 分钟。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\tts_memory_cache_service_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `npm --prefix web_ui run build`
- `.\tools\build_windows.ps1 -Release`
- `.\tools\build_android.ps1` 生成 `app-release.apk` 和 `mapping.txt`；外层超时后已按脚本目标同步到 `release/android/` 并执行 APK 签名和内容审计。
- Windows 干净 zip 审计：包内无 runtime/cache/log/security/db/key/settings 路径，文本类文件未发现常见密钥形态。

## 2026-06-22

- 歌曲和听力视频导出支持区分 `srt` / `subtitled` 产物；选择“两版视频 + SRT”时会同时输出无内置字幕视频、同名 SRT 和内置字幕视频，并在完成报告中分开展示。
- 导出文件名增加 `listening` / `song` / `srt` / `subtitled` / `song-audio` 标记，保留旧版导出文件扫描兼容；同一批 `both` 产物共享冲突后缀，便于成对识别。
- 歌曲版本增加“导出音频文件”入口，可把当前本地歌曲音频复制到程序目录 `recording-export/`，不依赖歌曲字幕时间线。
- 歌曲字幕时间线升级到 `alignmentVersion=10`，补强局部 ASR 匹配、首尾/中间推断行的可读时长分配，并新增 E03 真实 ASR fixture 回归。
- 新增歌曲 ASR 诊断快照流程：真实 ASR 词级结果写入程序目录 `diagnostics/`，可从快照重建 timeline 复现对齐问题；Windows 发布脚本保留 `diagnostics/` 运行数据目录。

验证：

- `D:\DevTools\flutter\bin\flutter.bat test test\song_subtitle_timeline_service_test.dart test\tts_memory_cache_service_test.dart --reporter expanded -j 1`
- `npm --prefix web_ui test`
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- `npm --prefix web_ui run build`
- `git diff --check`

## 2026-06-16

- 云平台选择升级为平台级分流：选择阿里云百炼时，文本、绘本图片、TTS、ASR 走 DashScope/百炼能力；选择火山引擎时，文本、绘本图片、TTS、ASR 走火山方舟/火山语音能力，不在失败时自动回退到另一平台。
- 绘本组图支持阿里云万相异步连续组图和火山 Seedream 顺序组图，v4 分镜上限调整为 12；组图少图或失败会保存明确错误，重试仍回到审核确认流程。
- 阿里云语音接入 CosyVoice 与 Qwen-ASR，默认 `cosyvoice-v3-flash` / `loongabby_v3` / `qwen3-asr-flash`；无词级时间戳时歌曲字幕按歌词和音频时长插值。
- 歌曲生成保留独立来源选择：Suno 网页自动化或阿里云百聆（Fun-Music）；百聆复用百炼 Key，不复制一套 Key 输入框。
- 设置页重新分区：凭据、平台地址、模型与语音、歌曲生成配置分开显示；Key 清除按钮并入对应输入行，移除单独占位的“Key 操作”字段。
- TTS 声音角色按平台隔离：阿里云使用 CosyVoice voice，火山使用 Doubao speaker；切换云平台时设置页只展示当前平台可用声音。
- 练习中心章节行恢复“听力”按钮，点击进入书籍播放器 `mode=listening`；章节列表标题支持折叠/展开，折叠后隐藏章节行并显示“章节列表已折叠”。
- Windows 发布脚本兼容没有 `.NET Path.GetRelativePath` 的 PowerShell 环境，发布阶段使用 URI 相对路径计算，保证真实 Windows App 构建/运行验证可以完成。
- 已刷新 Web UI 打包产物，旧 hash 资源替换为新的 `app/assets/web/` 资源。
- E01 已保存提示词检查结论：章节连续性基本满足，但配角外观锚点不足；当前绘本 v4 提示词已收敛为 bookDescription/chapterDescription/scenes[].sceneDescription，角色外观锚点只放在书籍简介或章节描述中。
- 设置页模型字段改为候选下拉：阿里云百炼文本模型提供 Max/Plus/Flash 档位，火山方舟文本模型提供高效果/低成本档位；万相和 Seedream 图片候选只保留当前组图链路可用模型，不暴露不能完成连续组图的图片模型。
- 空书删除改为只按真实存在的文章章节判断；如果书籍只剩孤儿 `story_chapters` 关系，会先清理这些关系再删除书籍。
- 听力播放器顶部进度条缩短并改用更明显的蓝色进度，与章节导航按钮分组隔开，减少挤在一起的视觉问题。
- `change_list.md` 已按用户计划标记本轮 4 项完成状态；本文件继续作为项目修改日志单独维护。
- 绘本角色描述支持经典名著公开角色补全和章节角色累积：可识别经典会让 AI 基于公开常识列主要递归角色；未知书籍不编造全书角色；本章新增角色先进入审核草稿，保存/确认后合并进书籍描述供后续章节复用。
- 最终组图 prompt 去掉长度控制：按审核后的书籍简介、章节描述和每张图分镜描述完整提交，不再压缩或截断单图描述。

## 验证

- `npm --prefix web_ui test`
- `npm --prefix web_ui run build`
- `.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true","TOMATO_QA_PORT=39317"`
- Windows QA 连续实测：`#/practice?seriesId=2` 展开状态有“听力”按钮；折叠后显示“章节列表已折叠”且章节行隐藏；点击第一章“听力”进入 `#/books/2/player?articleId=42&mode=listening`，`activeListeningArticleId=42`。
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- 本轮后续提交按用户确认未重复运行测试，仅刷新必要构建产物并做提交前静态核对。
