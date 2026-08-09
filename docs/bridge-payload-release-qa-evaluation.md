# Flutter/Web Typed Bridge 负载与 Windows Release QA 评测

评测日期：2026-08-02

本文将此前记录在 Release QA 会话、协议测试和构建踩坑文档中的大回包问题整理成独立报告。
它适合使用 Flutter WebView、typed bridge、base64 图片或本机 QA HTTP 接口的客户端项目参考。

> **English abstract:** A Flutter/WebView bridge accidentally returned full article bodies and repeated
> base64 picture-book images in list, state, mutation, and QA snapshot responses. Real Windows Release
> measurements reduced `article.list` from 62,752,595 to 64,485 bytes, `pictureBook.state` from
> 48,938,928 to 1,686 bytes, and `/snapshot` from 80,836,150 to 14,422 bytes by using summaries,
> on-demand image variants, and incremental patches.

## 目的

验证并修复以下设计风险：

- 列表和 `app.ready` 是否隐式带回整篇正文、全部句子和封面 data URI；
- 绘本状态轮询是否反复传输整章原图；
- 写操作是否为更新一个句子而返回整个书库；
- QA `/snapshot` 是否把页面中重复出现的完整 base64 `src/currentSrc` 再序列化一次；
- 优化后真实 Windows Release 的页面、图片和增量更新是否仍正常。

## 方法

1. 审计所有 typed bridge 命令和事件，而不是只修触发问题的单个接口。
2. QA 客户端在 JSON 解析前记录 HTTP 原始 byte array；服务端同时记录 `estimatedChars` 和
   实际响应 `bytes`，避免“解析很慢”掩盖传输契约错误。
3. 将列表、正文、图片、写响应拆成不同按需接口：
   - 列表只返回 `ArticleSummary[] + StorySeries[]`；
   - 正文只由 `article.fullText(articleId)` 返回；
   - `pictureBook.state` 只返回页元数据，单图按 `thumbnail/display/full` 请求；
   - 写操作返回目标实体或 `LibraryPatch`，客户端按 ID upsert/delete；
   - `/snapshot` 对图片只保留 `{kind, length, preview}`。
4. 在真实 Windows Release 中覆盖 listening、follow、chat、creation 路由和图片懒加载，检查
   `/health`、`brokenImages`、实际图片变体及临时 mutation 的创建/修改/删除闭环。

## 实测结果

| 接口 | 优化前 | 优化后 | 降幅 | 体积倍数 |
| --- | ---: | ---: | ---: | ---: |
| `article.list` | 62,752,595 B | 64,485 B | 99.897% | 973.1x |
| `app.ready` | 62,768,731 B | 64,525 B | 99.897% | 972.8x |
| `pictureBook.state` | 48,938,928 B | 1,686 B | 99.997% | 29,026.6x |
| `article.fullText` | 627,091 B | 10,009 B | 98.404% | 62.7x |
| `/snapshot` | 80,836,150 B | 14,422 B | 99.982% | 5,605.1x |

Mutation 响应保持在小体积：create 715 B、rename 731 B、sentence update 233–286 B、delete 191 B。

真实 Release QA 还验证了：

- `/health` 为 `ok=true`、`webReady=true`、`usesDevServer=false`；
- listening/follow/chat/creation 路由 `brokenImages=0`；
- WebView 请求 `thumbnail` / `display`，没有渲染 `full` 原图；
- 临时文章完整执行 create/rename/sentence update/delete，清理后剩余匹配数为 0；
- Web UI 120/120、Flutter 293 passed / 1 skipped；静态分析只有 3 条当时已存在的 unused 警告。

## 结论

大回包的根因不是 JSON 库性能，而是接口职责重叠：列表、状态、图片传输和写响应都携带了本次
操作不需要的数据。对 Flutter WebView 项目，更可靠的规则是：

- 列表永远只返回摘要；
- 大对象通过明确的单项接口按需读取；
- 图片必须按用途选择分辨率并懒加载；
- 写命令返回 ack/patch，不返回整库；
- 运行日志应同时记录估算字符和真实网络字节；
- 单元契约测试后仍需在真实 Release WebView 复查图片和页面状态。

当前测试会对 bridge 字段和预算做门禁，运行时超预算会写 `payload.oversized` 诊断。报告数字来自
当次本机书库，绝对字节会随用户数据变化；优化原则和数量级差异才是可迁移结论。

## 代码与复现入口

- 协议测试：[`web_shell_payload_contract_test.dart`](../app/test/web_shell_payload_contract_test.dart)
- Web patch 测试：[`library_patch.test.ts`](../web_ui/src/library_patch.test.ts)
- Windows QA：[`qa_windows_release.mjs`](../tools/qa_windows_release.mjs)
- QA 协议：[本机 QA 控制接口](qa-remote-control.md)
- 详细排障：[构建与发布踩坑记录](build-and-release-pitfalls.md#bridge-列表状态写命令和-qa-snapshot-禁止隐式携带正文图片曾-60mb)
