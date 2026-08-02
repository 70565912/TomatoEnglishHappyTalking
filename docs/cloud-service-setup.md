# 云服务配置指南

Tomato 不提供云账号或 API Key。请只为实际使用的能力配置对应服务，并在调用前阅读供应商的最新计费、额度和内容政策。

## 需要哪些 Key

| 设置项 | 用途 | 何时需要 |
| --- | --- | --- |
| 百炼 Key | 阿里云文本、万相绘本组图、CosyVoice TTS、Qwen-ASR、百聆歌曲 | 使用默认阿里云路径时 |
| 方舟 Key | 火山方舟文本、Seedream 绘本组图 | 使用火山文本或图片时 |
| 语音 Key | 豆包 TTS、BigASR、Realtime 对话 | 使用火山语音、跟读识别或对话时 |

建议第一次使用时只配置百炼 Key，先体验文章导入、绘本和听力；需要火山能力或实时对话时再补充其它 Key。

## 申请地址

1. **阿里云百炼（DashScope）**
   - [API Key 管理](https://bailian.console.aliyun.com/?tab=model#/api-key)
   - [获取 API Key 的官方说明](https://help.aliyun.com/zh/model-studio/get-api-key)
2. **火山方舟**
   - [方舟 API Key 管理](https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey)
   - 使用前开通所需文本或图片模型，例如 Seedream 顺序组图。
3. **豆包语音**
   - [新版语音 API Key 管理](https://console.volcengine.com/speech/new/setting/apikeys)
   - [控制台 API Key 说明](https://www.volcengine.com/docs/6561/2119699)
   - Tomato 使用新版 `X-Api-Key` 鉴权；按需开通 TTS、ASR 和 Realtime。

Suno 不在 App 内配置 Key。选择 Suno 后，App 会打开系统浏览器；用户自行登录、生成并下载 MP3，再回到创作中心导入。

## 在 App 中配置

1. 安装并打开 Windows 或 Android App。
2. 进入 **设置 → 云服务**。
3. 在 **凭据** 中填写实际使用的百炼 Key、方舟 Key或语音 Key，不使用的字段保持为空。
4. 选择与凭据匹配的默认平台和模型。
5. 保存设置。新生成任务使用当前配置，本地已有成功缓存会优先复用。

## 费用与数据边界

- 文本、图片、TTS、ASR、实时对话和歌曲请求由对应供应商计费，Tomato 不代收费用。
- Windows 本地 Real-ESRGAN 超分不调用云图片接口，但需要 Vulkan 显卡资源。
- 文章、数据库、缓存、生成素材、日志和设置保存在本机。
- 云端会接收到完成当前请求所需的文本、音频、图片或提示词；具体保留政策以供应商条款为准。

## 密钥安全

- 只在 App 设置页输入 Key，不要写入仓库文件、命令行、Issue、截图或普通日志。
- App 使用本机安全存储保存凭据，Flutter/Web 桥接只返回脱敏状态，不返回明文 Key。
- 对外发布 Windows ZIP 时不得包含 `security/`、`settings.json`、数据库、日志、缓存或生成媒体。
- 怀疑 Key 泄露时，应立即在供应商控制台撤销并重新创建。

## 常见问题

**为什么刚安装后不能直接生成？**

生成类能力依赖用户自己的云服务配置，仓库和 Release 都不包含共享密钥。

**是否所有功能都必须同时配置三个 Key？**

不需要。只配置当前供应商和功能需要的 Key。

**为什么 Android 没有本地超分？**

当前 Real-ESRGAN NCNN Vulkan 集成只随 Windows 包发布，Android 暂未提供同等能力。
