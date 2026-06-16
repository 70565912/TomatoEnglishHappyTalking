# 修改日志

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
- E01 已保存提示词检查结论：章节连续性基本满足，但配角外观锚点不足；绘本 v4 提示词已新增紧凑角色清单规则，要求 bookDescription/storyBrief/groupPrompt 覆盖主角、配角、叙述者和有视觉意义的未命名群体，并在分镜视觉描述中复用稳定角色标签。
- 设置页模型字段改为候选下拉：阿里云百炼文本模型提供 Max/Plus/Flash 档位，火山方舟文本模型提供高效果/低成本档位；万相和 Seedream 图片候选只保留当前组图链路可用模型，不暴露不能完成连续组图的图片模型。
- 空书删除改为只按真实存在的文章章节判断；如果书籍只剩孤儿 `story_chapters` 关系，会先清理这些关系再删除书籍。
- 听力播放器顶部进度条缩短并改用更明显的蓝色进度，与章节导航按钮分组隔开，减少挤在一起的视觉问题。
- `change_list.md` 已按用户计划标记本轮 4 项完成状态；本文件继续作为项目修改日志单独维护。
- 绘本角色描述支持经典名著公开角色补全和章节角色累积：可识别经典会让 AI 基于公开常识列主要递归角色；未知书籍不编造全书角色；本章新增角色先进入审核草稿，保存/确认后合并进书籍描述供后续章节复用。
- 最终组图 prompt 增加长度控制：12 张场景仍保留所有 `Image N` 条目，同时压缩书籍/章节上下文和每张图视觉描述，尽量贴合 Seedream/万相图片接口提示词限制。

## 验证

- `npm --prefix web_ui test`
- `npm --prefix web_ui run build`
- `.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true","TOMATO_QA_PORT=39317"`
- Windows QA 连续实测：`#/practice?seriesId=2` 展开状态有“听力”按钮；折叠后显示“章节列表已折叠”且章节行隐藏；点击第一章“听力”进入 `#/books/2/player?articleId=42&mode=listening`，`activeListeningArticleId=42`。
- `D:\DevTools\flutter\bin\flutter.bat analyze`
- 本轮后续提交按用户确认未重复运行测试，仅刷新必要构建产物并做提交前静态核对。
