# Suno CLI（paperfoot/suno-cli）HTTP 自动化调研笔记

> **状态**：参考归档，**不是**当前产品实现。Tomato 正式 Suno 路径仍是「系统浏览器手动 Create + 导入本地音乐」。  
> **用途**：若日后评估「跳过 Lexical / WebView2、直接调 Suno 内部 HTTP」的自动化，优先对照本笔记与上游仓库，而不是恢复 App 内 WebView 填表。

| 项 | 值 |
| --- | --- |
| 上游 | https://github.com/paperfoot/suno-cli |
| 形态 | Rust CLI（非长期 HTTP 网关服务） |
| 调研对照版本 | 约 v0.5.5–v0.5.7（2026-04～2026-05）；集成前请再读最新 `README` / `API_INTELLIGENCE.md` / `src/` |
| 相关踩坑 | `docs/suno_lexical_lyrics_editor.md`（WebView2 + Lexical 输入崩溃） |
| 当前产品流程 | `docs/suno_song_download_rules.md` |

## 为什么值得记一笔

Suno Create v5.x 歌词区改为 **Lexical** 后，Tomato 在 Windows 上用 App 内 WebView2（含 InAppBrowser 弹窗）**键盘输入 1 个字符即可崩溃**。根因在 `flutter_inappwebview_windows` 的 WebView2 + Lexical IME 链路，无法靠「改进填表脚本」修好。

`suno-cli` **不解决 WebView/Lexical 输入问题**——它**从不**往 `.lyrics-editor-content` 打字或粘贴。歌词与风格作为 JSON 字段走 `studio-api`；本机 Chrome 仅用于鉴权 Cookie 提取与 **hCaptcha token**。这与「在 WebView 里驱动 Create UI」是两条完全不同的路径。

```text
Tomato 旧路径（已弃）：App WebView2 → Lexical 填词 → 崩
Tomato 现路径：        剪贴板 + 系统浏览器（真人操作）→ 导入 MP3
suno-cli 路径：        Cookie/JWT → （可选 Chrome 过 hCaptcha）→ POST v2-web → 轮询 feed → 下载
```

## 总览：三件事拆开

| 步骤 | 做法 | 是否碰 Lexical |
| --- | --- | --- |
| 1. 鉴权 | 从本机浏览器读 Clerk Cookie → `auth.suno.com` 换 JWT；请求带 `Authorization` / `device-id` / `browser-token` | 否 |
| 2. 提交歌词与风格 | `POST /api/generate/v2-web/`，自定义模式把歌词放在 `prompt` | 否 |
| 3. 人机验证 | 真 Chrome（非 headless）+ CDP 调 `hcaptcha.execute()`，token 写入 body | 否（只为拿到 token） |

参考源码：`src/auth.rs`、`src/api/generate.rs`、`src/api/types.rs`、`src/captcha.rs`、`src/main.rs`。

## 1. 鉴权（不登录表单、复用浏览器会话）

- `suno auth --login`：用 `rookie` 等从 Chrome / Arc / Brave / Firefox / Edge 提取含 `suno.com` / `auth.suno.com` 的 Cookie。
- Clerk：`auth.suno.com` 上用 `__client` 等换 **JWT**；JWT 约 1 小时级，可按会话 refresh（比整段 Cookie 短命，但可自动续）。
- 备选：`--cookie` 粘贴、`--jwt` 直贴（JWT 很快过期）。
- 业务请求基址（调研时）：`https://studio-api-prod.suno.com`
- 常见头：
  - `Authorization: Bearer <jwt>`
  - `device-id`（如 `ajs_anonymous_id`）
  - `browser-token`：动态构造（时间戳等 base64 包装；以当日网页为准）
  - `Origin` / `Referer`：`https://suno.com`

**注意**：旧开源 `Suno-API/Suno-API` 仍用 `clerk.suno.com` + `studio-api.suno.ai`，对应当前页面已过时；不要按那套再集成。

## 2. 歌词如何进入「最新版」Create 协议（关键）

自定义模式（CLI：`suno generate --lyrics-file …`）：

```text
GenerateRequest.prompt          = 歌词全文（可含 [Verse] 等结构标签）
GenerateRequest.tags            = 风格
GenerateRequest.title           = 标题
GenerateRequest.negative_tags   = 排除风格（空字符串，勿乱传 null）
metadata.create_mode            = "custom"
metadata.web_client_pathname    = "/create"
metadata.create_session_token   = 每次请求新 UUID
mv                              = 模型码，如 chirp-fenix（v5.5）
generation_type                 = "TEXT"
transaction_uuid                = 每次请求新 UUID
token                           = hCaptcha 响应（多数账号需要）
```

灵感模式：`create_mode = "inspiration"`，描述文本仍放在 **`prompt`**（调研时网页已不再依赖单独的 `gpt_description_prompt` 字段）。

提交端点：

```http
POST https://studio-api-prod.suno.com/api/generate/v2-web/
```

调研结论（约 2026-04）：旧路径 `/api/generate/v2/` 常返回 `Token validation failed.`；网页 Create 走 **`v2-web`**，且 schema 字段大量必填（含看似无用的占位 `null` / 空数组），缺字段易 422 / schema drift。

轮询：`GET /api/feed/?ids=…`（cli 侧常按 2 个 id 一批）；列表类另有 `POST /api/feed/v3`。完成后可用 CDN/`audio_url` 下载，MP3 可嵌 ID3 歌词。

### 与 Tomato 手动流程的对照

| 能力 | Tomato 现在 | suno-cli |
| --- | --- | --- |
| 歌词来源 | 文章 → 剪贴板 | `--lyrics` / 文件 → JSON `prompt` |
| 风格 | 用户在网页填 | `--tags` / `--exclude` / `--title` |
| 验证码 | 用户在系统浏览器点 Create | CDP + invisible hCaptcha → `token` |
| 产物回 App | 「导入本地音乐」 | CLI 下载目录；若集成需再落盘到 `suno-music/` 并写 `ArticleSongVersion` |

## 3. 真人 / hCaptcha 怎么解

模块：`src/captcha.rs`（注释写明：headless HTTP **过不了**，需要带行为指纹的真浏览器）。

流程摘要：

1. 生成本机 Chrome 进程（**不要** `--headless`；headed 但 `--window-position=-32000,-32000` 挪出屏幕）。
2. 视口保持桌面尺寸（如 1280×900）；过小会进移动端壳，**不加载** hCaptcha。
3. CDP（默认 `127.0.0.1:9233`）：清 Cookie → 注入**精简** Suno/Clerk Cookie（全量 Cookie 易 HTTP 431）→ `https://suno.com/create`。
4. 等全局 `hcaptcha` SDK；`hcaptcha.render({ size: 'invisible', sitekey: … })` 后 `hcaptcha.execute()`。
5. 把返回的 response 字符串写入生成请求的 `token`。
6. Chrome 可在同一次 CLI 会话复用。

调研时出现过的 sitekey / Suno 侧 hCaptcha 域名写在上游源码常量里；**易变**，集成前必须用实网页重新抓取，不要长期死抄本文数字。

备选：`--token` 外供；`--no-captcha`（仅当账号侧允许时）。

竞品对照：`gcui-art/suno-api` 多走 Playwright + **2Captcha 付费**；suno-cli 偏向本机真 Chrome 自执行 invisible 挑战，不依赖打码平台，但依赖本机图形浏览器环境。

## 4. 已知脆弱点（集成前必评估）

- **非官方逆向**：违反/游走于 Suno ToS；账号风控与封禁自负。
- **协议漂移**：`v2-web` body、模型码（`chirp-fenix` 等）、Captcha sitekey、Clerk 域名曾多次变；cli 用 `schema_drift` 等信号提示，靠发版跟随。
- **验证码**：账号策略变化、无 Chrome、CI/服务器无桌面时整条链路失败。
- **JWT 过期**：长时间 poll 需 refresh；Suno 侧也曾出现「JWT 未到 exp 仍 Token validation failed」类现象。
- **不是 HTTP 常驻服务**：要给 App 用需自研 sidecar 或把逻辑迁入 Flutter/Dart，并处理 Windows 上 Chrome 路径、profile、隐私（Cookie/JWT 禁日志明文）。
- **与 Tomato 架构约束**：Web UI 不得直连云；若做自动化只能落在 Flutter Service / 本地 sidecar，经现有 bridge；且 AGENTS 当前明确 **禁止**恢复 App 内 WebView 填表自动化。

## 5. 若未来考虑集成的建议门槛

**不要做：**

- 再次在主 WebView / InAppBrowser WebView2 里打开 Create 填 Lexical（已确认必崩）。
- 把过期的 `Suno-API/Suno-API`（Go，2024，`clerk.suno.com`）当新版方案。
- 为「省一次验证码」重新引入不稳定的 DOM 填词。

**可以评估：**

1. 独立实验分支 / 仅本地开发开关；默认产品仍走系统浏览器手动 + 导入。
2. 协议对齐当日网页：`v2-web`、metadata、模型码、Captcha；对照上游 `API_INTELLIGENCE.md` 做探针。
3. Windows：本机 Chrome + CDP（或经验证的等价方案）；验证码失败时回退手动流程。
4. 成功音频仍写入 `suno-music/`，遵守 `docs/article_song_version_retention.md`（按 `articleId` 列版本，禁止用当前 `lyricsHash` 过滤已落盘项）。
5. 自动化生歌默认仍优先 **百聆 / ElevenLabs** 正式 API；Suno HTTP 仅作可选实验能力。

## 6. 与其它「Suno API」项目的快速对照

| 项目 | 对新版页 | 歌词 | 验证码 | 备注 |
| --- | --- | --- | --- | --- |
| paperfoot/suno-cli | 对过 `v2-web` / v5.5 | JSON `prompt` | 本机 Chrome CDP | 调研时相对最对齐新网页 |
| gcui-art/suno-api | 有维护，但可能仍偏旧 `v2` | HTTP | 2Captcha + Playwright | 接入前需实测 generate |
| Suno-API/Suno-API | 基本过时 | HTTP | 无 | new-api 渠道依赖的上游形态之一 |
| new-api「Suno」渠道 | 只转发兼容上游 | — | — | 网关不直连 suno.com |

## 7. 参考链接

- https://github.com/paperfoot/suno-cli
- 上游 `API_INTELLIGENCE.md`、`src/captcha.rs`、`src/api/types.rs`
- 本仓库：`docs/suno_lexical_lyrics_editor.md`、`docs/suno_song_download_rules.md`、`app/lib/features/web_shell/suno/suno_external_launcher.dart`
