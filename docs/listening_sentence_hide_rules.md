# 听力字幕软隐藏规则

## 语义

- 在听力页「修改字幕」中**清空英文并保存**，表示**软隐藏**该槽位，不是删文重建。
- DB 中 `articles.sentences[index]` 存 `""`，**槽位 index 不变**，后续句子编号也不变。
- 重新填入英文并保存即可**恢复**该句。

## 持久化

| 字段 | 行为 |
|------|------|
| `articles.sentences` | 保留空字符串占位 |
| `articles.content` | 按非空句重建，不含隐藏句 |
| `article_sentence_translations` | 隐藏时删除该 index 记录 |
| 听力 TTS 缓存 | 隐藏时 evict 旧句，不 synthesis |

## 各业务

| 模块 | 行为 |
|------|------|
| 听力列表 | 显示「（已隐藏）」行，可点编辑恢复 |
| 听力播放 / 全屏 | 跳过隐藏句 |
| 创作中心生成听力 | 不为隐藏句生成/统计 TTS |
| 跟读 | 打开与步进跳过隐藏槽 |
| 视频导出 | readiness 不要求隐藏句音频 |
| 歌曲 | 仍用 metadata `submittedLyrics` / 时间轴，不自动重算；改正文后旧歌曲仍列出，由用户删或用。见 `docs/article_song_version_retention.md` |
| 绘本分镜 | **不**因隐藏句失效 `summary_json` / `picture_book_pages` |
| 对话提纲 | `contentHash` 忽略空句；隐藏后 hash 可能变化，下次对话或重生成提纲 |

## 与删文重建的区别

- 软隐藏：槽位数不变，index 不变，可恢复，绘本/歌曲 metadata 不重算。
- 删文重建：改变分句边界，需重新生成听力、绘本等依赖材料。

## 相关代码

- `app/lib/core/practice/listening_sentence_visibility.dart`
- `listening.updateSentence` in `web_shell_screen.dart`
- `web_ui/src/listeningSentenceVisibility.ts`
