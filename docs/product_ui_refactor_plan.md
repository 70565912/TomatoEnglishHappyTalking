# 产品界面与功能重构方案

## 背景

Tomato English Happy Talking 早期定位更接近游戏化英语朗读、听力和对话练习软件，因此当前 Web UI 中仍保留了“大厅”“任务”“闯关”“XP”、乐高角色、怪物道具和奖励元素等游戏化表达。

现在产品重心已经转向：

- 按书籍和章节组织英语内容。
- 生成连续绘本图、歌曲和学习视频。
- 提供书籍章节级连续听力播放。
- 保留跟读、对话等练习能力，但不再让练习页面承担内容生产功能。

因此本轮重构不是单纯换视觉风格，而是重新定义产品信息架构、页面职责、桥接协议边界和旧能力清理范围。

## 重构目标

1. 以“书籍”为最高层级组织内容，而不是以“任务卡”或“游戏关卡”组织内容。
2. 新增单独的书籍章节听力界面，支持同一本书内按章节顺序连续播放。
3. 听力播放器支持两种模式：
   - 听力模式：英文 TTS + 绘本图 + 中英字幕。
   - 歌曲模式：本地已下载歌曲 + 歌词时间轴 + 绘本图。
4. 将练习能力和内容生产能力隔离：
   - 听力、跟读、对话练习只负责学习和播放。
   - 绘本、歌曲、视频生成集中到创作中心。
5. 去掉 MiniMax 歌曲生成 API 和其它旧歌曲来源，只保留 Suno 网页自动化与本地歌曲版本库。
6. 去掉无用游戏元素、游戏化文案和旧视觉资产引用。
7. 为后续 Windows 和 Android 双端统一体验打基础。

## 当前状态概览

### 本轮已落地范围

截至 2026-06-14，代码中已完成第一批落地：

- 主导航已切到书库、创作中心、练习中心和设置；首页文案不再使用游戏大厅、任务、闯关、XP 等定位。
- 已新增书籍详情、书籍章节播放器、创作中心和练习中心页面骨架；听力播放器保留播放职责，绘本、歌曲和视频生产动作集中到创作中心。
- 歌曲来源已固定为 Suno 网页自动化和本地版本库，MiniMax API、配置、mock 和测试入口已清理。
- `ArticleSongState`、`ArticleSongVersion` 和 `SunoCachedSongGroup` 已拆到 `app/lib/data/models/article_song_model.dart`，支持按歌词缓存组、缺失 `songUrl` 下载判断、歌词时间轴字段和默认版本标记。
- 新增 `npm run qa:layout` 布局审计脚本，并扩展 Windows QA 回归以覆盖书库、书籍详情、章节播放器、创作中心、练习中心和 Suno-only 设置。

下面的章节仍保留完整目标方案和后续拆分建议；未完成项以各阶段验收标准为准。

### 已具备的基础

当前数据库已经有书籍和章节相关表：

- `story_series`
- `story_chapters`
- `picture_book_pages`
- `article_sentence_translations`

这说明“书籍/章节”模型不用从零开始，可以复用现有 `StorySeries`、`Article`、`PictureBookPage` 和逐句翻译数据。

当前绘本和歌曲相关能力也已经基本存在：

- 文章保存后默认异步生成连续绘本组图。
- Suno 网页自动化已支持填歌词、每次让 Suno 根据歌词重新生成风格、确认消耗 credits、下载歌曲。
- Suno 下载音频和 metadata 已按持久目录 `suno-music/` 管理。
- 歌曲字幕时间轴已通过 `SongSubtitleTimelineService` 和 BigASR 生成。
- 听力视频和歌曲视频录制已有 bridge 与服务基础。

### 历史主要问题与剩余拆分点

1. `web_ui/src/App.tsx` 过大，把书库、导入、听力、跟读、对话、绘本、歌曲、视频录制、设置都揉在一个文件里。
2. 旧首页曾是游戏大厅心智，包含 `Level`、`Speaking Quest`、`XP`、`开始闯关` 等旧定位文案；本轮已改为书库工作台，后续仍需继续清理旧资产和历史文档引用。
3. 听力页曾承担过多职责，既播放句子，又管理绘本图、歌曲生成、歌曲下载、歌曲字幕、视频录制、句子编辑等；本轮已把新 UI 的生产入口迁到创作中心，但 `App.tsx` 和 bridge handler 仍需拆分。
4. 歌曲弹窗曾保留 Suno、MiniMax、其它方式三种来源；本轮已清理 MiniMax 和其它来源，后续重点是继续验证 Suno 本地版本库、默认版本和创作中心流程。
5. Flutter `WebShellScreen` 也承担了过多 bridge command 和 Suno 自动化状态管理，后续应分服务拆分。
6. 游戏化视觉资产仍在 `web_ui/public/assets/ui/lego/` 和设计文档中大量存在。

## 目标信息架构

新的主导航建议为：

```text
书库
创作中心
练习中心
设置
```

### 书库

书库是默认首页，展示所有书籍和未归档章节。

主要内容：

- 书籍封面。
- 书名。
- 章节数。
- 总句子数。
- 绘本完成度。
- 歌曲完成度。
- 视频导出状态。
- 上次播放位置。
- 最近更新章节。

主要操作：

- 继续播放。
- 打开书籍。
- 新增书籍/章节。
- 进入创作中心。

不再使用：

- 大厅。
- 任务卡。
- 闯关。
- XP。
- 游戏奖励。

### 书籍详情

书籍详情页是单本书的章节目录和资源状态页。

核心区域：

- 书籍封面和元信息。
- 章节列表，按 `story_chapters.chapter_order` 排序。
- 每章状态列：
  - 英文正文。
  - 中文字幕。
  - 绘本。
  - Suno 歌曲。
  - 歌词时间轴。
  - 听力视频。
  - 歌曲视频。
- 章节搜索和排序。

主要操作：

- 从头连续听。
- 从当前章节继续听。
- 歌曲模式播放整本书。
- 打开某章听力。
- 打开某章练习。
- 打开某章创作。

### 章节听力播放器

新增单独的书籍章节听力界面，建议路由：

```text
/books/:seriesId/player
/books/:seriesId/player?articleId=:articleId&mode=listening
/books/:seriesId/player?articleId=:articleId&mode=song
```

旧路由 `/listen/:articleId` 保留兼容，可进入单章播放器，也可以根据文章所属书籍跳转到书籍播放器。

播放器布局：

- 顶部：书名、当前章节、播放模式切换、返回书籍。
- 左侧或抽屉：章节队列。
- 中间：绘本画面。
- 底部：字幕和播放控制。
- 右侧或底部列表：当前章节句子列表。

播放器模式：

```text
听力 | 歌曲
```

听力模式只做播放：

- 播放英文 TTS。
- 中文只作为字幕显示，不播放中文 TTS。
- 支持播放/暂停/停止。
- 支持上一句/下一句。
- 支持上一章/下一章。
- 支持重听本句。
- 支持连续播放同一本书全部章节。
- 支持全屏播放。
- 支持点击单词查词和播放单词音频。

歌曲模式只做播放和本地版本选择：

- 播放已下载 Suno 歌曲。
- 按章节顺序连续播放。
- 使用 `listening.song.position` 推送当前歌词 cue。
- 使用 App 提交给 Suno 的原歌词作为字幕文本。
- 如果当前章节没有歌曲，显示“未生成，去创作中心”，不在播放器中直接生成。
- 如果歌曲存在但缺少时间轴，提示“去创作中心生成歌词时间轴”。

播放器中不出现：

- 生成绘本。
- 重试绘本整章组图。
- 创建 Suno 歌曲。
- 确认消耗 Suno credits。
- 下载缺失歌曲版本。
- 录制视频。
- 视频编码设置。

这些全部迁移到创作中心。

### 练习中心

练习中心只承载学习练习，不承载内容生成。

建议分为：

- 跟读练习。
- 对话练习。
- 练习记录。
- 发音评分回顾。

跟读页保留：

- 原句播放。
- 开始录音。
- 停止录音。
- 回放录音。
- 评分结果。
- 下一句。
- 绘本图作为上下文辅助展示。

跟读页移除：

- 绘本生成/重试。
- 歌曲生成/播放/下载。
- 视频录制。

对话页保留：

- 围绕当前章节和结构化分镜进行英语对话。
- AI 回复播放。
- 录音输入。
- 文本输入。
- 翻译展开。

对话页移除：

- 绘本生成/重试。
- 歌曲生成/下载。
- 视频录制。

### 创作中心

创作中心集中管理所有会消耗远程额度、Suno credits 或本地长任务的功能。

建议路由：

```text
/creation
/creation/books/:seriesId
/creation/articles/:articleId
```

创作中心主标签：

```text
绘本
歌曲
视频
资源库
```

#### 绘本标签

职责：

- 查看章节分镜。
- 查看每页图片状态。
- 查看失败原因。
- 重试整章组图。
- 清理当前章节绘本缓存。
- 预览绘本序列。

约束：

- 正式链路继续使用 Seedream 组图 `sequential_image_generation`。
- 组图失败不自动回退单图。
- 重试按钮重新提交整章组图。
- 不把 Alice 或其它单本书的设定固化到通用 prompt。

#### 歌曲标签

职责：

- 查看当前章节歌曲状态。
- 查看 Suno 风格分组。
- 查看本地已下载版本。
- 查看 detected song URLs。
- 查看缺失下载项。
- 打开 Suno 网页自动化。
- 确认消耗 Suno credits。
- 检测下载缺失 `songUrl`。
- 生成歌词时间轴。

约束：

- 只保留 Suno 网页自动化和本地版本库。
- 不再提供 MiniMax API。
- 不再提供“其它方式”占位入口。
- 不保存 Suno 用户名、密码、验证码或 cookie 明文。
- 完成下载后继续明确提示用户确认关闭 Suno 窗口。
- 当前歌词已完整下载时进入完成待命/播放状态；用户点击生成新版本时仍重新进入 Create 确认流程。

#### 视频标签

职责：

- 导出听力视频。
- 导出歌曲视频。
- 查看导出历史。
- 打开导出文件夹。
- 显示录制准备状态和失败原因。

听力视频前置条件：

- 绘本页 ready，并覆盖完整句子范围。
- 英文 TTS 可定位。
- 中文翻译可用于字幕。
- `ffmpeg.exe` 可用。

歌曲视频前置条件：

- Suno 本地音频版本 ready。
- `timelinePath` ready。
- 绘本页 ready。
- `ffmpeg.exe` 可用。

#### 资源库标签

职责：

- 管理本地绘本图。
- 管理 Suno 音频和 metadata。
- 管理歌词 timeline。
- 管理导出视频和字幕文件。
- 显示资源路径、更新时间、文件缺失状态。

## 关键流程

### 新增章节流程

1. 用户在书库或书籍详情中点击新增章节。
2. 选择已有书籍或新建书籍。
3. 粘贴英文、标准中英对照、混合文本或中文故事。
4. `article.create` 按现有本地解析优先级处理。
5. 标准中英对照内容优先本地解析，不调用 AI 提取英文。
6. 保存文章、句子和逐句中文翻译。
7. 默认异步生成连续绘本组图。
8. 保存完成后回到书籍详情，并显示章节生成状态。

### 书籍连续听力流程

1. 用户在书籍详情点击“继续播放”或“从头播放”。
2. Web UI 请求书籍播放队列。
3. 播放器打开第一个目标章节。
4. 当前章节播放结束后自动进入下一章。
5. 每章只预取当前和下一句英文音频、当前和下一张绘本图。
6. 章节切换时更新播放位置。
7. 书籍全部播放结束后显示完成状态。

### 歌曲连续播放流程

1. 用户在书籍播放器切换到歌曲模式。
2. 系统加载当前书籍章节队列中的歌曲状态。
3. 有本地歌曲版本的章节可播放。
4. 无歌曲的章节标记为缺失，播放队列可选择跳过或停止提示。
5. 播放歌曲时按 `listening.song.position` 更新歌词和绘本画面。
6. 当前歌曲结束后进入下一章歌曲。

### 创作歌曲流程

1. 用户进入创作中心的歌曲标签。
2. 选择书籍和章节。
3. 系统展示现有 Suno 风格、版本和下载状态。
4. 用户点击生成新版本。
5. 系统打开 Suno 页面并自动填写歌词。
6. 每次生成都清空旧 Styles，点击 Suno 蓝色魔法棒生成真实 style value。
7. 点击 Create 前必须让用户确认消耗 Suno credits。
8. 下载完成后保存音频、metadata、版本列表和 detected song URLs。
9. UI 提示下载完成，并等待用户确认关闭 Suno 窗口。

### 创作视频流程

1. 用户进入创作中心的视频标签。
2. 选择视频类型：
   - 听力视频。
   - 歌曲视频。
3. 系统检查 readiness。
4. 用户选择编码、分辨率和转场。
5. Native 使用已有图片、音频和字幕离线导出。
6. 完成后展示视频路径、字幕路径、编码器和 warning。

## 数据模型调整建议

### 复用现有表

继续复用：

- `articles`
- `story_series`
- `story_chapters`
- `picture_book_pages`
- `article_sentence_translations`
- `api_cache_entries`
- `api_cache_article_refs`

### 建议新增或补充的数据

#### 书籍播放位置

用于支持“继续播放”：

```sql
CREATE TABLE IF NOT EXISTS series_playback_positions (
  series_id INTEGER NOT NULL,
  mode TEXT NOT NULL,
  article_id INTEGER NOT NULL,
  sentence_index INTEGER NOT NULL,
  song_version_id TEXT,
  position_ms INTEGER,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (series_id, mode)
);
```

`mode` 建议值：

- `listening`
- `song`

#### 创作任务状态

如果后续需要统一管理绘本、歌曲、视频长任务，可新增：

```sql
CREATE TABLE IF NOT EXISTS creation_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  article_id INTEGER,
  series_id INTEGER,
  status TEXT NOT NULL,
  progress_json TEXT NOT NULL,
  result_json TEXT NOT NULL,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

`kind` 建议值：

- `picture_book`
- `suno_song`
- `listening_video`
- `song_video`

v1 可以先不新增 `creation_jobs`，继续用现有事件和状态；当创作中心需要跨页面恢复任务进度时再落库。

### 歌曲模型拆分

当前 `ArticleSongState`、`ArticleSongVersion`、`SunoCachedSongGroup` 和 MiniMax 服务放在同一个 `minimax_music_service.dart` 中。清理 MiniMax 前应先把歌曲状态模型拆出：

```text
app/lib/data/models/article_song_model.dart
```

拆出内容：

- `ArticleSongState`
- `ArticleSongVersion`
- `SunoCachedSongGroup`

保留给 Suno 和歌曲播放使用。

## Bridge 协议建议

### 书籍队列

新增：

```ts
book.playlist
```

请求：

```ts
interface BookPlaylistRequest {
  seriesId: number;
  startArticleId?: number;
  mode: 'listening' | 'song';
}
```

响应：

```ts
interface BookPlaylistPayload {
  series: StorySeries;
  chapters: Article[];
  startIndex: number;
  savedPosition?: {
    articleId: number;
    sentenceIndex?: number;
    songVersionId?: string;
    positionMs?: number;
  };
}
```

### 书籍播放位置

新增：

```ts
book.playbackPosition.save
book.playbackPosition.load
```

用于保存听力和歌曲模式下的书籍级播放进度。

### 听力队列

v1 可以由 Web UI 按章节顺序调用现有 `listening.open` 和 `listening.playSequence`。如果 native 侧需要更稳定的连续播放，可新增：

```ts
listening.queueOpen
listening.queuePlay
listening.queuePause
listening.queueStop
listening.queueNextChapter
listening.queuePreviousChapter
```

事件：

```ts
listening.queue.state
listening.queue.chapterChanged
listening.playback
```

### 歌曲队列

v1 可以由 Web UI 按章节顺序调用现有：

```ts
listening.songState
listening.songPlay
listening.songStop
```

如果要 native 管理整本书歌曲队列，可新增：

```ts
song.queueOpen
song.queuePlay
song.queuePause
song.queueStop
song.queueNextChapter
song.queuePreviousChapter
```

事件：

```ts
song.queue.state
listening.song.state
listening.song.position
```

### 创作中心命令归属

建议将创作命令命名从 `listening.*` 逐步迁移到更明确的命名空间：

```text
pictureBook.*
suno.*
video.*
recording.*
```

兼容期内旧命令可保留：

- `listening.songGenerate`
- `listening.songConfirmSunoCreate`
- `listening.songDownloadSunoExisting`
- `listening.songTimelineGenerate`
- `listening.recordVideo`
- `listening.songRecordVideo`

新 UI 优先调用新命名空间，旧命令只做兼容。

## MiniMax 移除清单

### Web UI

移除：

- `SongSource = 'suno' | 'minimax' | 'other'` 中的 `minimax` 和 `other`。
- 歌曲弹窗中的 MiniMax API 选项。
- “其它方式”禁用按钮。
- MiniMax 风格建议按钮。
- 长歌词超过 MiniMax 3500 字符的压缩确认。
- 设置页中的“默认生成来源”下拉框。
- mock bridge 中所有 MiniMax song state。

保留：

- Suno 输出目录。
- Suno 超时设置。
- 本地歌曲版本列表。
- 歌词时间轴生成。
- 歌曲视频录制。

### Flutter / Dart

移除：

- `MiniMaxMusicService.generateSong`
- `MiniMaxMusicService.ensureStylePromptForArticle`
- `AppConfig.miniMaxApiKey`
- `TOMATO_MINIMAX_API_KEY`
- `MiniMax.txt` 文件读取。
- `minimax_api_key` secure storage key。
- `song_default_source` secure storage key。
- WebShell 中非 Suno 歌曲生成分支。

调整：

- `AppConfig.songSettings` 不再返回 `defaultSource`。
- `saveSongSettings` 只保存 Suno 输出目录和超时。
- `_normalizeSongSource` 删除或固定返回 `suno`。
- 歌曲状态模型迁移到独立 model 文件。

### 测试

删除或改写：

- `app/test/minimax_music_service_test.dart`
- `app/test/app_config_test.dart` 中 MiniMax key 读取测试。
- `web_ui/src/App.test.tsx` 中 MiniMax 歌曲生成测试。
- `web_ui/src/bridge.ts` 中 MiniMax mock。
- `api_cache_service_test.dart` 中仅用于 MiniMax 的 `kind: minimax_music` 用例。

## 前端拆分建议

当前 `web_ui/src/App.tsx` 应拆成以下结构：

```text
web_ui/src/
  App.tsx
  routes.ts
  bridge.ts
  types.ts
  features/
    library/
      LibraryPage.tsx
      BookDetailPage.tsx
      ChapterImportPage.tsx
      bookGrouping.ts
    player/
      BookPlayerPage.tsx
      ListeningModePanel.tsx
      SongModePanel.tsx
      ChapterQueue.tsx
      PictureBookStage.tsx
      SubtitlePanel.tsx
    practice/
      PracticeCenterPage.tsx
      FollowPage.tsx
      ChatPage.tsx
    creation/
      CreationCenterPage.tsx
      PictureBookCreationPanel.tsx
      SongCreationPanel.tsx
      VideoCreationPanel.tsx
      ResourceLibraryPanel.tsx
    settings/
      SettingsPage.tsx
  shared/
    components/
    hooks/
    icons/
    styles/
```

拆分原则：

- `App.tsx` 只负责路由、全局状态和 shell。
- 页面组件不直接包含大量 bridge 细节，桥接逻辑放到 feature hooks 中。
- 播放器和创作中心不共享按钮组件状态，只共享数据模型。
- 旧 `PictureBookScene` 可改名为 `PictureBookStage` 并被播放器、跟读、对话复用。
- 歌曲版本列表从听力页弹窗中抽为 `SongVersionList`。

## Flutter 侧拆分建议

当前 `WebShellScreen` 仍可作为 WebView 壳入口，但内部职责应逐步拆出：

```text
app/lib/features/web_shell/
  web_shell_screen.dart
  web_bridge_protocol.dart
  web_bridge_handlers/
    article_bridge_handler.dart
    series_bridge_handler.dart
    picture_book_bridge_handler.dart
    listening_bridge_handler.dart
    song_bridge_handler.dart
    recording_bridge_handler.dart
    settings_bridge_handler.dart
    diagnostics_bridge_handler.dart
```

服务层建议：

```text
app/lib/services/
  suno_song_service.dart
  suno_automation_service.dart
  book_playback_service.dart
  article_song_repository.dart
```

拆分顺序：

1. 先抽模型，不改行为。
2. 再抽 song 相关 helper。
3. 再抽 bridge handler。
4. 最后整理 WebShellScreen 中的 UI overlay。

## 视觉设计方向

### 新定位

视觉心智从“游戏闯关”调整为：

```text
儿童英语绘本工作台 + 章节播放器 + 视频创作工具
```

关键词：

- 绘本。
- 章节。
- 时间轴。
- 版本。
- 播放。
- 导出。
- 资源状态。

### 保留

- 番茄橙作为品牌主色。
- Nunito 字体。
- 8px 间距体系。
- Material Icons 或现有 Icon 组件。
- 16:9 绘本图作为主要视觉资产。

### 移除

- Level。
- Quest。
- XP。
- Reward。
- 闯关。
- 任务卡。
- 怪物道具。
- 火箭、盾牌、星星奖励等游戏元素。
- 乐高角色作为主视觉。
- 大面积装饰渐变和游戏背景。

### 页面风格

书库：

- 更像电子书架和创作项目库。
- 书籍封面是第一视觉。
- 卡片信息密度适中，突出状态和继续动作。

播放器：

- 更像视频/有声书播放器。
- 绘本画面优先。
- 控制区稳定，不因字幕长短跳动。
- 章节队列可折叠。

创作中心：

- 更像生产工作台。
- 状态明确：缺失、生成中、失败、ready、已导出。
- 高成本动作必须有确认。
- 长任务显示进度、日志摘要和下一步建议。

练习中心：

- 安静、聚焦。
- 不再混入创作按钮。
- 评分结果清晰，但不再做游戏奖励。

## 迁移阶段

### 阶段 0：基线确认

目标：

- 记录当前 App.tsx、WebShellScreen、MiniMax、Suno、绘本和录制现状。
- 确认当前测试和 Windows 运行入口。

产出：

- 本文档。
- 当前路由和 bridge command 清单。
- MiniMax 删除影响清单。

### 阶段 1：文案和导航先行

目标：

- 首页从“大厅/任务/闯关”改为“书库/章节/继续播放”。
- 主导航改为书库、创作中心、练习中心、设置。
- 去掉 XP、Level、Quest 等文案。

范围：

- Web UI 文案和路由名称。
- 不改底层 bridge 行为。

验收：

- UI 不再出现旧游戏化主文案。
- 原有新增章节、听力、跟读、对话入口仍可用。

### 阶段 2：书籍详情页

目标：

- 新增单本书详情页。
- 章节按 `chapter_order` 展示。
- 展示绘本、歌曲、视频状态。

范围：

- Web UI 新页面。
- 复用 `article.list` 和 `series.list`。
- 必要时新增轻量状态聚合命令。

验收：

- Alice 等旧书籍章节能归到同一本书下显示。
- 空书籍、未归档文章都有明确状态。

### 阶段 3：书籍章节播放器

目标：

- 新增书籍级播放器。
- 支持从某章开始连续播放。
- 支持听力和歌曲模式切换。

范围：

- Web UI 播放器。
- v1 可先由 Web UI 管理章节队列。
- 保存播放位置。

验收：

- 从第一章开始可自动播放下一章。
- 从中间章节开始也能顺序播放到末尾。
- 歌曲模式能跳过或提示缺失歌曲章节。

### 阶段 4：创作中心

目标：

- 把绘本、歌曲、视频生成入口迁出听力页。
- 建立创作中心三大面板：绘本、歌曲、视频。

范围：

- Web UI 新页面。
- 复用现有 pictureBook、listening.song、recording 命令。
- 保留 Suno overlay 行为。

验收：

- 听力页不再出现生成歌曲、录制视频、绘本重试等生产按钮。
- 创作中心可以完成同样的生成和导出动作。

### 阶段 5：练习中心

目标：

- 跟读和对话练习从书库/章节进入。
- 练习页面只显示学习动作。

范围：

- 跟读页移除生产入口。
- 对话页移除生产入口。
- 增加练习中心聚合页。

验收：

- 用户能从书籍章节进入跟读和对话。
- 跟读/对话页面没有绘本、歌曲、视频生成入口。

### 阶段 6：MiniMax 清理

目标：

- 删除 MiniMax API、设置、mock、测试和非 Suno 分支。
- 保留 Suno 和本地歌曲版本库。

范围：

- Web UI 类型和弹窗。
- Flutter AppConfig。
- WebShell song bridge。
- MiniMax service 和测试。

验收：

- 全仓库不再有可执行 MiniMax 生成入口。
- 设置页不再展示 MiniMax。
- 歌曲功能仍能播放本地 Suno 版本、生成时间轴、导出歌曲视频。

### 阶段 7：视觉资产和样式清理

目标：

- 移除或停用旧游戏化资产。
- 统一新视觉系统。

范围：

- `web_ui/public/assets/ui/lego/`
- `app/assets/web/assets/ui/lego/`
- 旧设计文档可标记为历史，不再作为新 UI 基准。
- CSS 变量和页面布局。

验收：

- 主要 UI 不再加载乐高角色和游戏道具。
- 页面更像绘本/视频创作工作台。
- Windows 和 Android 宽窄屏布局稳定。

### 阶段 8：真实端到端回归

目标：

- 用真实 Windows App 验证关键流程。

必须验证：

- 新增章节。
- 保存后绘本异步生成状态。
- 书籍详情章节排序。
- 书籍连续听力。
- 歌曲模式播放。
- Suno 生成和下载完成确认。
- 歌词时间轴生成。
- 听力视频导出。
- 歌曲视频导出。
- 跟读和对话练习入口。

按项目约定，涉及绘本保存/生成/听力模式最终联调时，必须跑真实 Windows App UI；必要时使用 `TOMATO_QA_REMOTE=true` 和 QA 控制接口，不以 service/test harness 作为最终结论。

## 测试计划

### Web UI 单元测试

覆盖：

- 书籍分组和排序。
- 书籍详情状态展示。
- 播放队列章节切换。
- 听力/歌曲模式切换。
- 创作中心 tab 状态。
- MiniMax UI 删除后不会出现旧选项。

### Bridge mock 测试

覆盖：

- `book.playlist` mock。
- 连续播放章节切换。
- 歌曲缺失章节提示。
- Suno 状态展示。
- 视频 readiness 展示。

### Dart 测试

覆盖：

- AppConfig 删除 MiniMax 后的 song settings。
- 歌曲模型迁移后的 JSON 兼容。
- Suno metadata 读取和按歌词缓存组恢复。
- 播放位置保存和恢复。

### 真实 Windows 回归

推荐命令仍走项目脚本：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command '.\tools\build_windows.ps1 -Release -Run -DartDefine "TOMATO_QA_REMOTE=true","TOMATO_QA_PORT=39317"'
```

验证时注意：

- 不要在受限沙箱内直接跑 Flutter SDK 命令。
- 涉及 live API 调用时确认真实网络和 key 状态。
- 有限图片额度时只跑必要章节，但最终关键链路不能只用静态检查替代。

## 验收标准

### 产品验收

- 用户第一眼看到的是书库，而不是游戏大厅。
- 用户可以进入一本书并按章节顺序播放。
- 听力模式和歌曲模式在书籍播放器中清晰切换。
- 跟读、对话、听力页面没有内容生成入口。
- 绘本、歌曲、视频生成都集中在创作中心。
- 高成本动作都在创作中心确认。
- MiniMax 不再作为歌曲生成方式出现。

### 技术验收

- `App.tsx` 不再承载所有页面细节。
- 歌曲状态模型不再依赖 `minimax_music_service.dart`。
- MiniMax 相关 API key、配置、测试和 mock 已清理。
- Suno 缓存、按歌词分组、detectedSongUrls 和持久目录行为保持可用。
- 旧路由兼容，不会让已有文章无法打开。
- Windows 和 Android 布局没有严重遮挡和溢出。

### 回归验收

- Alice 等已有书籍章节仍能正确归属同一本书。
- 标准中英对照导入仍优先本地解析。
- 听力打开后中文翻译来自导入/保存结果，不批量重新翻译。
- 歌曲字幕展示文本仍使用 App 提交给 Suno 的原歌词。
- Suno 下载完成后提示明确，并等待用户确认关闭窗口。

## 风险与处理

### 风险：一次性重写 App.tsx 容易引入回归

处理：

- 先建新页面和新路由。
- 保留旧页面兼容。
- 每阶段只迁移一个能力域。

### 风险：创作中心迁移后旧听力页功能丢失

处理：

- 先复用旧 bridge command。
- UI 迁移完成后再重命名命令。
- 保留 QA 场景逐项验证。

### 风险：MiniMax 模型和 Suno 模型当前耦合

处理：

- 先抽出 `ArticleSongState` 和 `ArticleSongVersion`。
- 再删 MiniMax API 分支。
- 最后删配置和测试。

### 风险：旧游戏资产仍被打包

处理：

- 先让新 UI 不引用旧资产。
- 再清理 Web UI public 资产。
- 最后同步 `app/assets/web/` 和发布目录。

### 风险：书籍连续播放需要更稳定 native 队列

处理：

- v1 由 Web UI 管理队列，快速验证产品体验。
- 如果播放中跨章节状态复杂，再新增 native queue command。

## 推荐实施顺序

优先顺序：

1. 首页文案和主导航改造。
2. 新增书籍详情页。
3. 新增书籍章节播放器。
4. 迁移歌曲和视频生成到创作中心。
5. 迁移绘本重试和资源管理到创作中心。
6. 整理练习中心。
7. 清理 MiniMax。
8. 清理旧游戏视觉资产。
9. 真实 Windows 回归。

这个顺序的好处是先稳定用户心智和核心路径，再清理底层旧能力；不会因为过早删除 MiniMax 或大拆 WebShell 导致播放、绘本和 Suno 链路一起失稳。
