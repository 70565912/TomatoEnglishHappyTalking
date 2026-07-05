# 文章歌曲版本保留与清理

## 归属边界

- 歌曲版本归属 **`articleId`**，不按当前正文 `lyricsHash` / `contentHash` 从 UI 隐藏。
- `listening.songState` 与创作中心展示该文章下**全部**本地有效版本（Suno / 阿里云百聆 / 外部导入），**单一列表**，不分「当前歌词 / 历史歌词」区块。
- 改字幕、软隐藏、微调正文**不会**自动删除或隐藏已有歌曲；用户自行决定继续播放或删除。

## hash 的用途（禁止用于列表过滤）

| 用途 | 说明 |
|------|------|
| 新缓存条目的 `cacheKey` | `api_cache_entries.request_json` 中的 `lyricsHash` / `contentHash` |
| metadata 记录 | 各版本保留生成时的 `lyricsHash`、`submittedLyrics` |
| Suno **新**检测下载 | 详情页 / Library 核对**当前**提交歌词是否匹配（见 `docs/suno_song_download_rules.md`） |
| **禁止** | 用当前 hash 过滤 `getEntriesForArticlePurpose` 结果，导致旧版本不出现在列表 |

## 文本不一致

- 播放与字幕以版本自身的 `submittedLyrics` + 时间轴算法为准。
- 与当前听力正文不一致时，App 不自动删歌；用户可播放、重新生成字幕或删除。
- 歌曲视频导出仍要求该版本的 `timelinePath` 有效。

## 删除（用户显式）

命令：`listening.songDeleteVersion`。

必须同步清理：

1. 音频文件（`audioPath`）
2. 字幕时间轴（`timelinePath`，若有）
3. 对应 `suno-music/` 或百聆 metadata JSON
4. 对应 `api_cache_entries` + `api_cache_article_refs` 行

实现：`ArticleSongCacheService.removeVersionFromArticleCache` 就地更新含该版本的 cache 行；组内无版本时整行删除。

**禁止**：删除后把剩余版本整包 rewrite 到**当前** hash 的新 metadata（会产生磁盘孤儿 JSON / cache 行）。

## 保存与更新

| 操作 | 规则 |
|------|------|
| 新下载 / 新生成 | 只 merge 或新建**当前** `lyricsHash` 对应 cache 行 |
| 设默认 / 字幕更新 | 只更新**含该 versionId** 的 cache 行内对应项 |
| 设默认（全局） | 各 cache 行内 `isDefault` 同步：仅目标版本为 true |

## 与软隐藏的关系

- 软隐藏改变 `_articleSongStoryText()` → 当前 `lyricsHash` 可能变化。
- 已落盘歌曲仍应列出；metadata 内 `submittedLyrics` 不变。
- 详见 `docs/listening_sentence_hide_rules.md`。

## 与 Suno 检测下载的边界

- **已缓存列表**：按 `articleId` 全量加载。
- **新检测下载**：仍须在 Suno 详情页用**当前**歌词做匹配，避免误下他人歌曲。

## 相关代码

- `app/lib/services/article_song_cache_service.dart` — cache 行查找、就地更新、删除；`loadAllCachedVersions` 按 article 全量读取
- `app/lib/features/web_shell/web_shell_screen.dart` — `_cachedSunoSongGroups`、`_cachedBailianSongState`、歌曲 bridge 命令
- `app/lib/data/models/article_song_model.dart` — `ArticleSongVersion`、`SunoCachedSongGroup`
