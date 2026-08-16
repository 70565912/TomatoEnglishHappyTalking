# 诊断日志专项规则

> 新增日志、QA 日志接口或排查运行时链路时必读。

## 诊断日志规范

- 统一入口：`TomatoLogger`。
- 固定字段：`ts, level, category, event, message, flowId, articleId, route, stage, status, durationMs, data, error, stack`。
- 级别：`trace/debug/info/warn/error/fatal`；默认 `info`，可用 `TOMATO_LOG_LEVEL` 调整。
- 分类：`startup, bridge, qa, webview, article, pictureBook, tts, asr, chat, follow, listening, recording, suno, music, cache, config, safety`。
- 日志目录解析顺序：`TOMATO_LOG_DIR`、`TOMATO_DESKTOP_DATA_ROOT\logs`、桌面程序目录 `logs`。Windows Debug/Release 都应复用 `release\windows\tomato_english_happy_talking\logs`。
- 日志文件为 NDJSON，内存保留最近 2000 条，文件默认 5 MB 轮转，最多 10 个文件或 7 天。
- 永远不要记录完整 API key、Authorization、Cookie、完整文章正文、完整歌词、完整云响应或绝对路径明文；需要定位内容时记录 hash、长度、业务 ID 和短摘要。
- Web UI 通过 `diagnostics.clientLog` 上报 `window.onerror`、`unhandledrejection` 和关键 `console.warn/error`；bridge 请求只记录 payload 摘要。
- QA 实时接口：`GET /logs/recent?limit=200&level=&category=&since=`、`GET /logs/stream?level=&category=`、`GET /logs/files`、`GET /logs/export`。
