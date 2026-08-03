<div align="center">
  <img src="app/assets/web/assets/ui/lego/brand-tomato.png" width="104" alt="Tomato English Happy Talking">
  <h1>Tomato English Happy Talking</h1>
  <p><strong>把一篇英文或中英文章，变成可以听、读、说和分享的英语学习材料。</strong></p>
  <p>面向家长和教师的本地优先英语内容制作工具，支持 Windows 与 Android。</p>
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
    <a href="https://github.com/70565912/TomatoEnglishHappyTalking/releases/latest"><strong>下载 Windows ZIP / Android APK</strong></a>
    · <a href="https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose">报告问题或建议</a>
  </p>
</div>

![Tomato 产品总览](docs/readme/product-overview.webp)

## 从文章到完整学习材料

![Tomato 四步工作流](docs/readme/workflow.webp)

1. **导入文章**：粘贴英文或中英对照内容，按书籍和章节保存。
2. **制作素材**：审核绘本分镜，生成组图和逐句听力，也可以制作或导入歌曲。
3. **开始练习**：孩子可以进行绘本听力、逐句跟读、识别评分和章节对话。
4. **导出分享**：导出听力或歌曲视频，并选择 SRT 字幕或内嵌字幕。

[使用问题](https://github.com/70565912/TomatoEnglishHappyTalking/discussions) · [功能建议](https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose) · [查看路线图](ROADMAP.md)

## 公开作品案例

下图来自 Tomato 为 E07 `Am I Still Alice` 本地导出的真实 1080p 内嵌中英字幕视频。点击封面可打开《爱丽丝梦游仙境（原著领唱版）》完整作品集。

[![查看 Tomato E07 绘本听力成片](docs/readme/demo-alice-e07.webp)](https://wap.qupeiyin.cn/app/v736/albumShare?shareUid=MDAwMDAwMDAwMLGdxGaAscyUsbeEcg&albumId=MDAwMDAwMDAwMLCHpmKAsa7e)

**[查看 41 集完整作品集](https://wap.qupeiyin.cn/app/v736/albumShare?shareUid=MDAwMDAwMDAwMLGdxGaAscyUsbeEcg&albumId=MDAwMDAwMDAwMLCHpmKAsa7e)** · [趣配音 E03 完整版](https://movie.qupeiyin.com/home/share/original_video/app/1/course/MDAwMDAwMDAwMLCHxKqCe7rdsMp0cg/uid/MDAwMDAwMDAwMLGdxGaAscyUsbeEcg) · [趣配音 E09 完整版](https://movie.qupeiyin.com/home/share/original_video/app/1/course/MDAwMDAwMDAwMLCHxKuCe67bsKR0cg/uid/MDAwMDAwMDAwMLGdxGaAscyUsbeEcg)

《爱丽丝梦游仙境（原著领唱版）》已经使用 Tomato 制作并发布为 41 个连续学习视频，可在[英语趣配音移动端作品集](https://wap.qupeiyin.cn/app/v736/albumShare?shareUid=MDAwMDAwMDAwMLGdxGaAscyUsbeEcg&albumId=MDAwMDAwMDAwMLCHpmKAsa7e)查看。趣配音链接由第三方平台承载，页面可用性和播放方式以平台当前规则为准。

## 适合谁

- 想把孩子正在读的英文故事制作成绘本听力的家长。
- 需要把自有文章整理成课堂听说材料的英语教师。
- 希望保留本地书库、音频、图片和视频，不依赖自建后端的个人用户。
- 愿意自行申请并承担云 AI 服务费用、需要控制模型与素材版本的进阶用户。

## 有什么不同

Tomato 不是预置固定课程的闯关 App。它围绕你自己的文章建立一条完整内容链路：持久化分句、逐句翻译、绘本分镜审核、听力、跟读、章节对话、歌曲和视频导出都归属于同一本书和章节。已经生成的成功素材优先从本地缓存复用，减少重复云调用。

## 主要能力

- 导入英文或中英对照文本，并保存为书籍章节。
- 审核整章绘本提示词后，按顺序生成连续分镜组图。
- 生成并缓存逐句英文 TTS，支持绘本全屏听力播放。
- 跟读录音、语音识别和基于识别结果的发音评分。
- 基于当前章节内容开展英语对话练习。
- 生成或导入歌曲，并根据 ASR 时间生成歌词字幕时间轴。
- 导出听力或歌曲视频，支持 SRT 和内嵌字幕。
- Windows 可使用随包提供的 Real-ESRGAN NCNN Vulkan 进行本地 2x/4x 绘本超分。

![Windows 本地 Real-ESRGAN 超分对比](docs/readme/upscale-comparison.webp)

## 平台支持

| 能力 | Windows | Android |
| --- | :---: | :---: |
| 书库、章节与创作中心 | ✅ | ✅ |
| 绘本、听力、跟读与对话 | ✅ | ✅ |
| 歌曲与字幕视频工作流 | ✅ | ✅ |
| 本地 Real-ESRGAN 绘本超分 | ✅ 需要 Vulkan | 暂不支持 |
| GitHub 发布包 | ZIP | APK（当前为测试签名侧载版） |

## 使用前须知

- 本项目不提供云账号或 API Key。文本、图片、TTS、ASR、实时对话和歌曲能力按所选服务商实际计费。
- Windows/Android 客户端直接调用你配置的云服务，不需要部署 Tomato 私有后端。
- 文章、数据库、下载素材、生成图片、音频、视频、缓存、日志和设置保存在本机。
- Release 不包含开发者账号、API Key、本地数据库、缓存、日志或用户生成内容。
- Suno 使用系统浏览器手动生成和下载，再回到创作中心导入本地 MP3。

完整申请和配置步骤见 [云服务配置指南](docs/cloud-service-setup.md)。

## 下载与安装

前往 [最新 Release](https://github.com/70565912/TomatoEnglishHappyTalking/releases/latest)：

- **Windows**：下载 `tomato_english_happy_talking-windows-*.zip`，解压后运行 `tomato_english_happy_talking.exe`。需要 Microsoft Edge WebView2 Runtime；本地超分还需要支持 Vulkan 的显卡。
- **Android**：下载 `tomato_english_happy_talking-android-*.apk` 后侧载安装。当前公开 APK 使用项目测试签名，不是应用商店正式签名。
- 发布页提供 SHA-256 校验清单时，可在安装前核对下载文件完整性。

## 更多界面

| 创作中心 | 听力与绘本 |
| --- | --- |
| ![创作中心](docs/readme/creation-center.png) | ![听力与绘本](docs/readme/listening-preview.webp) |

| 跟读练习 | 章节对话 |
| --- | --- |
| ![跟读练习](docs/readme/follow-preview.webp) | ![章节对话](docs/readme/chat-preview.webp) |

歌曲生成、字幕与视频/音频导出：

![歌曲与视频导出](docs/readme/song-video-preview.webp)

## 作者与缘起

- 作者：兔子先生 / Ryan Chen
- 邮箱：[70565912@qq.com](mailto:70565912@qq.com)

这款应用最初是兔子先生为自家的「番茄」小朋友制作的 AI 英语学习工具。最初的愿望很直接：把孩子正在阅读的任意文章自动制作成英文绘本视频，同时支持日常听力和口语练习。项目后来逐步扩展为围绕书籍、章节、绘本、听力、跟读、对话、歌曲和视频导出的完整工作台。

## 本地与云端边界

| 范围 | 处理方式 |
| --- | --- |
| 书库、分句、翻译映射和素材索引 | 本地 SQLite |
| API Key | 本机安全存储；桥接只返回脱敏状态 |
| 图片超分 | Windows 本地 Real-ESRGAN NCNN Vulkan |
| 文本、图片、TTS、ASR、实时对话 | 按设置调用阿里云或火山引擎 |
| Suno 歌曲 | 系统浏览器手动流程后导入本地文件 |
| 导出与诊断 | 本机文件系统 |

## 文档

- [用户指南与截图](docs/user-guide/)
- [云服务配置](docs/cloud-service-setup.md)
- [开发与构建指南](docs/development-guide.md)
- [AI CLI / QA 远程调用指南](docs/ai_cli_qa_remote_guide.md)
- [变更记录](docs/change_log.md)
- [路线图](ROADMAP.md)
- [贡献说明](CONTRIBUTING.md)
- [安全政策](SECURITY.md)

## 技术与致谢

主应用使用 [Flutter](https://github.com/flutter/flutter)，Web UI 使用 React、Vite 和 TypeScript。项目还使用或集成了 [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)、[ncnn](https://github.com/Tencent/ncnn)、[FFmpeg](https://github.com/FFmpeg/FFmpeg)、[flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) 和 [just_audio](https://github.com/ryanheise/just_audio) 等开源项目。第三方组件、模型、字体和媒体仍遵守各自许可证与使用条款。

## 参与项目

普通用户可以在 [Discussions](https://github.com/70565912/TomatoEnglishHappyTalking/discussions) 提问或展示作品，在 [Issue Forms](https://github.com/70565912/TomatoEnglishHappyTalking/issues/new/choose) 报告问题和提出建议。提交前请删除 API Key、账号、本机路径、数据库和未脱敏日志。

如果 Tomato 对你的家庭学习或教学准备有帮助，可以为仓库点一个 Star，让更多有相同需求的人看到它。

## License

项目以 [Apache License 2.0](LICENSE) 开源。云服务、第三方模型、字体、媒体以及用户生成内容仍各自遵守其原有条款。
