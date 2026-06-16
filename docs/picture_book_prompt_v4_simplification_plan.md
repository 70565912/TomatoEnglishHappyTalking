# 绘本组图提示词 v4 简化落地方案

本文档定义绘本组图生成的新目标方案：彻底下线系列 Bible、角色卡和参考图链路，改为“书籍简介 + 当前章节规划 + 顺序组图 prompt”的轻量流程。目标是降低历史提示词污染、减少误导性字段、让用户审核的内容更少但更有效。

## 目标

- 绘本提示词只服务当前章节组图生成，不再维护长期系列 Bible 或角色卡。
- 书籍层只保留书名和书籍简介，书籍简介承载时代、整体画风、主要角色基础外貌等稳定信息。
- 每章生成前只调用一次文本规划 API，由 AI 根据书名、书籍简介和章节正文决定分镜数量。
- 每张图片严格对应一个分镜，Seedream 顺序组图请求的 `max_images` 等于分镜数量。
- 删除 SQLite 中不再使用的 Bible、角色卡、参考图相关字段和表，避免后续开发继续误用。
- 不再写入 `audience`、`safety`、`negativePrompt`、字幕留白、UI overlay 等旧提示词字段。

## 数据模型与迁移

### story_series

新结构只保留：

```text
id
title
description
cover_image_path
created_at
updated_at
```

迁移要求：

- 新增 `description TEXT NOT NULL DEFAULT ''`。
- 删除 `style_guide_json`。
- 删除 `bible_json`。
- 旧书籍迁移时：
  - `description` 默认写入空字符串。
  - 若后续需要补充简介，由用户在编辑书籍时手动维护。

### story_reference_assets

删除整张表。

后续流程不再创建、读取、展示或传入参考图。旧参考图文件不参与新生成；是否清理旧文件可作为单独缓存清理任务处理，不阻塞本次方案。

### story_chapters.summary_json

新计划版本为：

```text
picture_book_chapter_plan_v4
```

旧版本一律不再读取，包括：

- `chapter_story_outline_v1`
- `picture_book_chapter_plan_v1`
- `picture_book_chapter_plan_v2`
- `picture_book_chapter_plan_v3`

旧 `summary_json` 中以下字段不再使用：

- `seriesBiblePatch`
- `characters` 作为系列角色记忆
- `locations` 作为系列地点记忆
- `continuityNotes` 作为跨章连续性记忆
- 旧 `pagePrompts`
- 旧 `negativePrompt`
- 旧 `styleGuide`
- 旧 `bible`

实现时可以保留旧 JSON 原文作为历史数据，但新链路必须只认 `planKind == picture_book_chapter_plan_v4`。重新生成组图时，如果当前章节不是 v4 计划，必须重新调用文本规划。

## 新生成流程

### 1. 文章保存

- 保存文章、句子、中文对照和书籍章节关系。
- 不自动提交图片生成。
- 保存成功后打开绘本提示词审核弹窗。

### 2. promptReview 文本规划

输入给文本模型：

- 书名。
- 书籍简介。
- 章节标题。
- 完整章节句子列表，带句子序号。

要求文本模型返回严格 JSON：

```json
{
  "planKind": "picture_book_chapter_plan_v4",
  "storyBrief": "Brief visual context for this book and chapter, including core story world and concise main character appearance descriptions.",
  "chapterBrief": "Brief description of the chapter as one coherent picture-book image sequence.",
  "scenes": [
    {
      "pageIndex": 0,
      "sentenceStartIndex": 0,
      "sentenceEndIndex": 2,
      "title": "Scene title",
      "story": "What happens in this scene.",
      "visual": "What the image should show, including characters, action, setting, mood, and key props."
    }
  ]
}
```

规划规则：

- AI 自行决定分镜数量。
- 分镜必须覆盖完整章节句子范围。
- 分镜按句子顺序排列，不重叠、不跳句。
- 分镜数量上限保留为 12，避免成本和接口超限。
- 每个分镜对应一张图片，不做候选图。
- 主配角外貌只写入 `bookDescription`、`storyBrief`、`groupPrompt` 或当前分镜 `visual`，不持久化为角色卡；三姐妹、旁白、老师等未命名群体也要有稳定角色标签和外观锚点。
- 不输出 `negativePrompt`、`safety`、`audience`、字幕留白或 UI 相关字段。

### 3. 提示词审核弹窗

弹窗只展示和允许编辑：

- 书籍简介。
- `storyBrief`。
- `chapterBrief`。
- 每个 scene 的 `title/story/visual`。
- 最终组图 prompt。

弹窗提供 3 个提示词魔法棒：

- `storyBrief` 魔法棒：只提交当前书名、书籍简介、章节标题和章节正文给文本模型，刷新绘本故事简述。
- `chapterBrief` 魔法棒：只刷新章节组图简述。
- `scenes` 魔法棒：只刷新分镜列表，可由 AI 重新决定分镜数量，但仍需覆盖完整章节且最多 12 张。

魔法棒只更新当前审核草稿，不调用图片 API，不删除旧组图。若最终组图 prompt 已被用户手动改动，魔法棒刷新不会自动覆盖最终组图 prompt，最终以用户当前确认提交的 group prompt 为准。

弹窗不再展示：

- 系列 Bible。
- 角色卡。
- 参考图开关。
- 参考图列表。
- `styleGuide` JSON。
- `negativePrompt`。

确认按钮文案使用“保存提示词并生成组图”。若用户修改书籍简介、brief、分镜或 group prompt，点击确认时先保存审核后的文本计划，再删除旧组图并提交顺序组图生成。

若用户修改书籍简介，确认时同步保存到 `story_series.description`，并用当前简介提交组图。

### 4. 最终组图 prompt 拼装

最终 prompt 固定为三段。

第一段：固定组图说明，所有书籍共用：

```text
Generate a coherent sequence of full-frame 16:9 English picture-book illustrations.
Each image corresponds to exactly one storyboard scene below, in order.
Keep the same book world, illustration style, color palette, and recurring character appearances across the whole sequence.
For every image, match the assigned scene action, characters, setting, props, mood, and composition.
Do not treat the images as alternate candidates.
Natural story-world text may appear only when it belongs to the scene, such as signs, book covers, maps, labels, or playing-card marks.
```

第二段：书籍与章节简述：

```text
Book title: <title>
Book description: <description>
Story brief: <storyBrief>
Chapter brief: <chapterBrief>
```

第三段：分镜列表：

```text
Image 1:
Sentence range: 1-3
Scene title: ...
Scene story: ...
Visual direction: ...

Image 2:
...
```

提交图片 API 时：

- `sequential_image_generation = "auto"`。
- `max_images = scenes.length`。
- `size = 2560x1440`。
- 不传参考图。
- 不使用 `negativePrompt`。

## 接口与 UI 调整

### Flutter bridge

保留：

- `pictureBook.promptReview`
- `pictureBook.refreshPromptReview`
- `pictureBook.confirmPromptReview`
- `pictureBook.cancelPromptReview`

调整 payload：

- `promptReview` 返回 `bookDescription`、`storyBrief`、`chapterBrief`、`scenes[]`、`groupPrompt`。
- `refreshPromptReview` 提交 `reviewId`、`target`、当前 `bookDescription`、`storyBrief`、`chapterBrief`、`scenes[]`；`target` 只允许 `storyBrief`、`chapterBrief`、`scenes`，返回更新后的审核草稿，不生成图片。
- `confirmPromptReview` 提交 `reviewId`、`bookDescription`、`storyBrief`、`chapterBrief`、`scenes[]`、`groupPrompt`。
- 删除 `characterCards`、`referenceAssets`、`useReferenceImages`、`styleGuide`、`seriesBible`。

旧命令兼容：

- `pictureBook.generate` 和 `pictureBook.retryPage` 不直接生成图片，只打开新的 prompt review。

### Web UI

- 新增/编辑书籍时增加“书籍简介”输入框。
- 新增章节选择书籍时显示当前书籍简介，可编辑当前书籍简介。
- 创作中心“重新生成组图”打开 v4 审核弹窗。
- 审核弹窗取消后不删除旧图片。
- 审核弹窗确认后才删除旧 `picture_book_pages` 和图片缓存引用，并提交新的顺序组图。

## 清理范围

需要删除或停止使用：

- `story_series.style_guide_json`
- `story_series.bible_json`
- `story_reference_assets`
- 角色卡 UI、类型和 payload。
- 参考图 UI、类型、payload 和生成逻辑。
- `_mergeSeriesBiblePatch`、`_characterCardsForReview`、`_characterCardPromptText` 等 Bible/角色卡相关逻辑。
- 旧 prompt 中的 `audience`、`safety`、`negativePrompt`、字幕留白和 UI overlay 相关正向/负向提示。

需要保留：

- 文章保存与书籍章节关系。
- 章节计划缓存，但只认 v4。
- 顺序组图生成。
- 图片页表 `picture_book_pages`。
- 缩略图缓存。
- 用户确认后再生成图片的审核流程。

## 测试与验收

### 单元测试

- 迁移后 `story_series` 有 `description`，没有 `style_guide_json` 和 `bible_json`。
- 迁移后 `story_reference_assets` 不存在。
- v4 promptReview 不读取旧 v1/v2/v3 章节计划。
- v4 promptReview 返回 `storyBrief`、`chapterBrief`、`scenes[]` 和 `groupPrompt`。
- scenes 覆盖完整句子范围，且 `scenes.length <= 12`。
- promptReview 不调用图片 API，不删除旧图片。
- refreshPromptReview 三个 target 都不调用图片 API，不删除旧图片。
- cancelPromptReview 不删除旧图片，不调用图片 API。
- confirmPromptReview 使用用户编辑后的 bookDescription、brief、scenes 和 groupPrompt，并把审核后的 v4 计划保存到 `story_chapters.summary_json`。
- confirmPromptReview 后才删除旧 pages/cache 并提交顺序组图。
- 最终 groupPrompt 不包含 `audience`、`safety`、`negativePrompt`、`subtitle`、`caption`、`app-rendered`、`UI overlay`。

### Web UI 测试

- 新增书籍可以填写书籍简介。
- 编辑书名时可以编辑书籍简介。
- 保存章节后打开 v4 审核弹窗。
- 审核弹窗不出现 Bible、角色卡、参考图开关。
- 审核弹窗有 3 个魔法棒，分别刷新故事简述、章节简述和分镜描述。
- 审核弹窗确认按钮显示“保存提示词并生成组图”。
- 修改书籍简介和分镜描述后，确认 payload 包含修改内容。
- 重新生成组图先打开审核弹窗，取消后旧组图仍在。

### Windows 联调

- 启动 Windows App + QA Remote。
- 打开 `E01 - All In The Golden Afternoon`。
- 点击“重新生成组图”。
- 审核弹窗只显示书籍简介、故事简述、章节简述、分镜和最终 prompt。
- 确认 prompt 中没有旧 Bible/角色卡/参考图/safety/audience/字幕留白内容。
- 用户确认后才提交图片生成。
- 生成结果页数等于 v4 scenes 数量。

## 默认取舍

- 跨章节一致性由“书籍简介”承担，不再由 Bible 或参考图承担。
- 角色外貌描述由 AI 在每章规划阶段生成紧凑角色清单，覆盖主角、配角、叙述者和视觉上重要的未命名群体；用户可在审核弹窗中调整书籍简介、分镜或最终 prompt。
- 未命名群体需要稳定角色标签和外观锚点，例如 eldest sister / middle sister / youngest sister，而不是只在 prompt 中写成 generic children。
- 旧计划不迁移、不兼容、不复用；需要重新生成时直接生成 v4 计划。
- 旧参考图不再参与生成；文件清理以后单独做缓存清理。
