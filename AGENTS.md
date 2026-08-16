# Tomato English Happy Talking — Agent Guide

本文件是本仓库 AI Coding Agent 的全局 source of truth。它只记录每次开发都应遵守的工作方式、架构边界、产品不变量、验证要求和文档入口；具体功能、供应商协议和本机环境细节放在 `docs/`，按任务读取。

**Working code only. Plausibility is not correctness.**

## 1. 指令与事实优先级

发生冲突时按以下顺序处理：

1. 用户当前明确要求；
2. 本文件；
3. 与目标路径匹配的 `.github/instructions/*.md`；
4. 当前代码、测试、配置和实际运行行为；
5. `docs/` 中标记为当前的设计或专项文档；
6. 历史文档、archive、旧 prompt 和旧注释。

路径级 instructions 只能补充本文件，不应复制或改写全局规则。发现冲突时先核对当前实现并指出冲突，不要盲从旧文档。不要因为某个 API、模型、Provider、路径或架构曾在仓库中出现，就假设它仍然有效。

## 2. 项目与架构

Tomato English Happy Talking 是无自建后端的 Flutter 客户端，支持 Windows 和 Android。主用户界面是打包进本地 WebView 的 React/Vite/TypeScript 应用。

```text
React / Vite / TypeScript Web UI
              ↓ typed command/event bridge
       Flutter WebShellScreen
              ↓
Riverpod / SQLite / secure storage / audio / cloud services / export
```

主要目录：

| 路径 | 职责 |
|---|---|
| `app/lib/` | Flutter 运行代码、Bridge、Provider、Service 与本地能力 |
| `app/test/`、`app/integration_test/` | Dart/Flutter 测试 |
| `app/android/` | Android 原生工程 |
| `web_ui/src/` | React Web UI 与 Bridge 类型 |
| `app/assets/web/` | 打包进 App 的 Web UI 产物 |
| `tools/` | 构建、QA、发布和一次性工具 |
| `docs/` | 当前设计、专项规则、调试和变更文档 |

核心分层：

- Web UI 负责页面、交互和展示状态；不得直接访问云 API、SQLite、安全配置或本地文件。
- Web UI 与 Flutter 只通过 `app/lib/features/web_shell/web_bridge_protocol.dart`、`web_ui/src/bridge.ts` 和 `web_ui/src/types.ts` 定义的 typed bridge 交互。协议变化必须同步两侧类型和测试。
- Service 负责远程 API、本地数据处理、缓存、文件和模型转换，不持有 Widget UI 状态。
- Provider 负责状态与业务编排，沿用仓库现有 Riverpod 代码生成模式。
- Widget/Screen 负责 UI，通过 Provider/`AsyncValue` 连接业务，不直接调用远程 API。

## 3. 工作方式

### 3.1 先理解，后修改

非简单任务在修改前至少确认：实际入口、调用链、数据流、状态归属、相关测试、相似实现和对应专项文档。

不确定时按以下顺序处理：

```text
搜索 → 阅读 → 运行或复现 → 再判断
```

不得编造文件、API、配置、Git 状态、测试结果、构建结果或远程响应。不能验证时明确说明未验证。

### 3.2 控制授权和范围

- 回答、解释、审查或诊断任务以只读调查和报告为主；除非用户同时要求修改，否则不要实施修复。
- 修改、构建或修复任务应直接完成范围内的本地改动和非破坏性验证，无需为常规步骤反复确认。
- 提交、推送、发布、远程写入、付费云调用、破坏性操作或明显扩展范围前必须获得明确授权。
- 保护工作树中已有的无关改动。只修改完成当前任务所必需的文件和代码，不做顺手重构、全仓格式化、依赖升级或历史清理。
- 自己的修改造成 orphan、临时日志、探针或生成残留时，交付前清理；不要顺手删除原本存在的无关代码或数据。

### 3.3 修根因并形成闭环

```text
明确成功条件
  ↓
复现或建立基线证据
  ↓
实施最小修改
  ↓
运行针对性验证
  ↓
阅读失败输出并修复根因
  ↓
执行相关回归与必要的真实 App / Release 验证
```

不要用吞异常、虚假成功、无限重试、神秘延时、宽松判断或静默切换 Provider 来掩盖错误。

## 4. 产品不变量

除非用户明确要求改变产品设计，否则保留以下边界：

- 当前主导航围绕“书库 / 创作中心 / 练习中心 / 设置”，不要重新包装成游戏大厅、XP、闯关、每日任务或奖励系统。
- 文章保存并完成分句后，`articles.sentences` 是听力、跟读、字幕、翻译、绘本、歌曲和导出的持久化文本边界。打开文章、查询素材、播放或导出时不得偷偷重新分句并覆盖结果；改变边界应显式重建文章和派生素材。
- Web Bridge 是正式跨层协议。一次性迁移、内容修复、审计、实验和探针应放在独立工具或隔离工作区，不得接入 `app/lib/`、`web_ui/src/`、正式 Bridge 或发布产物。
- 当前跟读评分使用所选 ASR Provider 的识别结果和 `RecognitionBasedAssessmentEngine`。ASR 是产品能力层，不要把评分链路写死为某个供应商模型；兼容模型或测试 stub 不代表正式远程评分链路。
- 云平台选择是产品行为。除非当前设计明确提供 fallback，单一 Provider 失败后不得静默切换另一个 Provider。
- 歌曲字幕中的 ASR 结果只可作为时间锚点时，不得写回文章、歌词或字幕正文。
- WebView 不直接渲染绘本远程原始超大图；沿用项目定义的 display/thumbnail 链路。

## 5. 云调用、缓存与凭据

云服务端点、模型、鉴权和配额会变化。相关修改必须先检查当前代码和云服务专项文档；必要时只查供应商官方文档，不把旧 instructions、旧提交或历史示例当成现行事实。

- 优先复用已有业务数据、本地解析和成功缓存，再考虑远程 API。
- 只缓存成功的真实远程结果。错误、异常文本、安全拒绝和 mock/fallback 不得写入成功缓存。
- cache key 必须覆盖所有影响结果的输入、模型、声音或资源配置，避免错误复用和重复计费。
- API Key 只通过 `AppConfig` / secure storage 读取；不得硬编码、写日志、进入测试 fixture、通过 Bridge 返回明文或进入缓存。
- 沿用当前 Service 的 HTTP 与 Provider 选择机制；不要引入第二套重复网络栈或平行业务链路。
- 缺少配置或远程失败时保留真实错误语义。只有产品行为或明确的测试/本地演示场景需要时才使用可识别的 mock，不得把假数据伪装为成功结果。

## 6. 代码质量与性能

- 优先复用仓库已经证明可工作的模式，选择满足需求的最小简单方案。
- 不为单本书、单个词、单个页面或单次故障持续堆叠特例；修正可解释的统一规则和根因。
- 避免重复计算、无界队列/缓存、无终止条件的递归或重试、重复业务路径和职责混杂的超大函数。
- 同一事实只保留一个权威计算位置。兼容旧数据时隔离兼容层并明确退出条件。
- 性能优化不得删减正确性检查、诊断字段或测试范围。声称行为等价或性能改善时，使用相同机器、输入和构建模式记录回归或基线对比。
- 不为未来假想需求增加抽象层、配置系统、状态字段或扩展点；不随意修改依赖版本或加入重复能力的依赖。

## 7. 日志与安全

- 新增运行链路统一使用 `app/lib/core/logging/tomato_logger.dart` 的 `TomatoLogger`，不要增加散落的裸 `debugPrint` 作为正式诊断方案。
- 日志优先记录 ID、hash、长度、duration、stage、status 和短摘要。
- 不记录完整 API Key、Authorization、Cookie、文章正文、歌词、云响应或不必要的绝对私有路径。
- 调试接口、测试开关和 QA 能力不得削弱正式构建的安全边界，也不得把明文密钥返回给 Web UI。

## 8. 验证要求

迭代时先运行最相关的测试，交付前按风险扩大范围。没有实际运行的测试、分析、构建、远程请求或 UI 流程不得声称通过。

常用验证：

```powershell
# Web UI
cd web_ui
npm test
npm run build

# Flutter / Dart；从 app/ 调用仓库包装脚本
cd app
..\tools\run_flutter.ps1 analyze
..\tools\run_flutter.ps1 test
```

按改动选择最低验证范围：

| 改动 | 至少验证 |
|---|---|
| Dart Service / Model / Provider | 相关 `flutter test` + `analyze` |
| React / TypeScript UI | `npm test` + `npm run build` |
| Bridge protocol | Flutter 侧相关测试 + Web UI 测试/build + `analyze` |
| 数据库 / migration / cache | 新旧数据、二次运行、重启、失败恢复、cache hit/miss |
| Windows UI / WebView / 音频 / 文件 | 真实 Windows App 流程；单元测试不足以定论 |
| Android / Manifest / Gradle / plugin | Android 构建或设备/模拟器验证 |
| Release / 发布 | 对应 Release 构建、产物检查与真实运行验证 |

报告结果时明确区分“已验证 / 未验证 / 无法验证”，并说明未执行范围。

## 9. 构建与本机环境

优先使用仓库脚本，不复制平行构建流程：

```powershell
.\tools\build_windows.ps1 -Release
.\tools\build_windows.ps1 -Run
.\tools\build_android.ps1
.\tools\run_android_debug.ps1
.\tools\setup_android_emulator.ps1
```

Flutter SDK、Android SDK、AVD 和仓库盘符属于本机环境，不是项目协议。脚本应解析或配置环境；不要把某台开发机的绝对路径写进业务代码或通用规则。

Windows 发布目录可能同时包含本机运行数据、日志、缓存和安全配置。不得直接压缩整个运行目录对外发布；使用仓库发布脚本和干净 staging。不得为构建方便清空用户运行数据。

## 10. 专项规则路由

只读取与当前任务相关的文档，不要默认加载全部 `docs/`。历史/归档文档只作背景。

| 任务范围 | 必读文档 |
|---|---|
| 一般开发与项目结构 | [开发与构建指南](docs/development-guide.md) |
| 产品导航和原生/WebView 关系 | [产品 UI 专项规则](docs/agent_guides/product_ui_rules.md) |
| 页面、Provider、Bridge、Web UI | [功能页面开发专项规则](docs/agent_guides/feature_development_rules.md) |
| 分句算法、规则、性能与测试 | [分句统一规范](docs/read_aloud_sentence_split_spec.md)、[分句工程迭代约束](docs/read_aloud_sentence_split_engineering_rules.md) |
| 歌曲、听力、字幕、TTS 复用、跟读 | [音乐、听力与跟读专项规则](docs/agent_guides/music_listening_follow_read_rules.md) |
| 绘本、图片缓存、审核与云成本 | [绘本与云 API 成本专项规则](docs/agent_guides/picture_book_and_cloud_cost_rules.md) |
| 内容安全、文章导入、翻译与续传 | [内容安全与文章导入专项规则](docs/agent_guides/content_safety_and_article_import_rules.md) |
| 云端点、Provider、模型与密钥 | [云服务端点与配置专项规则](docs/agent_guides/cloud_service_configuration_rules.md) |
| 新建或重构云 API Service | [云 API Service 开发专项规则](docs/agent_guides/cloud_service_development_rules.md) |
| Android 原生、Manifest、Gradle | [Android 原生专项规则](docs/agent_guides/android_native_rules.md) |
| PowerShell 工具 | [PowerShell 工具专项规则](docs/agent_guides/powershell_tooling_rules.md) |
| 构建、运行与发布 | [构建发布专项规则](docs/agent_guides/build_and_release_rules.md)、[构建发布踩坑](docs/build-and-release-pitfalls.md) |
| 日志与运行时诊断 | [诊断日志专项规则](docs/agent_guides/logging_rules.md) |
| 跟读录音、ASR、评分与播放 | [跟读功能排查专项规则](docs/agent_guides/follow_read_troubleshooting.md) |
| 重要历史变化 | [变更记录](docs/change_log.md) |

## 11. 完成条件与本文件维护

任务完成前确认：

- 实际改动满足用户目标且没有无关扩张；
- 相关测试、分析、构建或真实流程已按风险执行并阅读输出；
- 没有新增 secret、临时入口、假成功或自己造成的残留；
- 文档、协议两侧、生成文件和产物在适用时保持同步；
- 最终报告列出改动、验证结果和仍未验证的风险。

本文件不是项目百科。只涉及单一功能、供应商 schema、模型/端点、固定 fixture、具体书籍或历史事故的内容应进入对应 `docs/`。同一规则只写一次；只有用户纠正暴露出可复现且未被覆盖的项目级缺口时，才在这里增加一条可执行规则，并定期删除失效内容。
