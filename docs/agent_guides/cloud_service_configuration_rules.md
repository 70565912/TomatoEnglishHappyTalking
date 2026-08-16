# 云服务端点与配置专项规则

> 处理 TTS、Realtime、ASR、图片模型、provider 或密钥设置时必读。

## 兼容性禁止项

- 不要把 Ark 文本补全重新作为聊天主链路。
- 不要重新引入已移除的第三方发音评估配置、依赖或远程评分调用；跟读评分沿用当前 ASR 识别与本地评估引擎。

### 云服务端点

Doubao TTS 2.0：

- 端点：`https://openspeech.bytedance.com/api/v3/tts/unidirectional`
- 鉴权：Header `X-Api-Key`、`X-Api-Resource-Id`、可选 `X-Api-Request-Id`
- 默认 Resource ID：`seed-tts-2.0`
- 返回 HTTP chunked JSON 行，`data` 字段为 Base64 MP3 分片，按顺序解码合并后交给 `just_audio`

Realtime V3 AI 对话：

- 端点：`wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- 推荐鉴权：`X-Api-Key`、`X-Api-Resource-Id: volc.speech.dialog`、`X-Api-Connect-Id`
- 不再回退旧鉴权头；语音链路只使用新版 `X-Api-Key`
- 当前客户端使用文本 query 模式：`StartConnection` -> `StartSession` -> `ChatTextQuery` -> `FinishSession` -> `FinishConnection`
- AI 回复文本交给本地 TTS 2.0 播放

BigASR（仅指火山 ASR Provider 下的具体模型实现）：

- 端点：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`
- 鉴权：`X-Api-Key`、`X-Api-Resource-Id`、`X-Api-Request-Id`、`X-Api-Sequence`
- 音频格式：WAV PCM 16kHz 16bit mono
- `StreamingAsrService` 依据 `AppConfig.asrProvider` 分流；本节端点和鉴权只适用于实际选择火山对应模型的请求，不代表通用 ASR 能力层
- 跟读评分由 `RecognitionBasedAssessmentEngine` 基于所选 ASR Provider 返回的识别文本和参考句做 LCS / 覆盖率 / 长度比例启发式计算，不与某个供应商模型绑定

数据库服务：

- `DatabaseService` 单例通过 `getInstance()` 获取。
- 表名、列名用常量定义，避免散落字符串。
- 所有写操作返回 `Future<void>` 或 `Future<int>`。

配置与密钥：

- 语音密钥字段：`volc_speech_api_key`，供 TTS、Realtime 和 BigASR 共用。
- 文本生成 provider 由 `ai_provider` 控制，默认 `aliyun_bailian`，可切换 `volcengine`。`TextGenerationService` 使用 `AppConfig.openAiTextConfig` 统一走 OpenAI-compatible Chat Completions。当前平台选择也是图片、TTS、ASR 的分流开关：阿里云走 DashScope/百炼，火山走方舟/火山语音，不自动回退到另一平台。
- 阿里云百炼配置字段：`aliyun_bailian_api_key`、`aliyun_bailian_base_url`、`aliyun_bailian_api_base_url`、`aliyun_bailian_text_model`、`aliyun_bailian_image_model`、`aliyun_bailian_image_size`、`aliyun_bailian_tts_model`、`aliyun_bailian_tts_voice`、`aliyun_bailian_tts_sample_rate`、`aliyun_bailian_asr_model`、`aliyun_bailian_realtime_asr_model`、`aliyun_bailian_realtime_asr_url`、`aliyun_bailian_music_model`；默认兼容模式 base URL 为 `https://dashscope.aliyuncs.com/compatible-mode/v1`，默认 DashScope API base URL 为 `https://dashscope.aliyuncs.com/api/v1`，默认文本模型 `qwen3.7-max`，图片模型 `wan2.7-image-pro`，CosyVoice `cosyvoice-v3-flash` + `loongabby_v3`，ASR `qwen3-asr-flash` / `qwen3-asr-realtime`，音乐模型 `fun-music-v1`。设置页用下拉候选保存模型，阿里云文本模型提供 Max/Plus/Flash 档位；图片模型候选只放当前连续组图链路可用的万相模型。
- 火山方舟配置字段：`volc_ark_api_key`、`volc_ark_base_url`、`volc_ark_text_model`、`volc_ark_image_model`；火山语音配置字段：`volc_speech_api_key`、`volc_tts_resource_id`、`volc_tts_speaker_id`。火山平台用于可选文本 provider、Seedream 图片生成、Doubao TTS 和 BigASR。设置页用下拉候选保存方舟文本模型，提供高效果/低成本档位；Seedream 图片候选只放当前顺序组图链路可用模型。
- 当前代码不再从工作目录 `security/speech-api-key.txt` 或 `security/ark.txt` 自动读取 legacy 明文 key。设置页可保存/清除百炼、方舟和语音 key，返回状态只显示 mask，不返回明文。设置页云服务区域必须保持“凭据 / 平台地址 / 模型与语音”分区，Key 清除按钮并入对应输入行；TTS 声音列表按当前平台切换，阿里云保存 CosyVoice voice，火山保存 Doubao speaker。
- 绘本图片按当前云平台分流：阿里云百炼使用 DashScope 万相异步组图接口，火山引擎使用方舟 `/api/v3/images/generations` Seedream 组图；不要恢复旧 Visual / AK-SK 图片备用链路，也不要在任一平台失败后自动回退到另一平台。
- Seedream 组图能力只在成功读取到 `volc_ark_api_key` 且当前平台为火山时启用；万相组图能力只在成功读取到 `aliyun_bailian_api_key` 且当前平台为阿里云时启用。缺少当前平台 key 时应跳过对应图片生成，不调用其它平台图片模型。
- 火山绘本图片默认使用方舟 `doubao-seedream-5-0-260128`。用户侧展示按产品需求使用 16:9 `1280x720` 体验，但真实方舟网络探针已确认远程 `1280x720` 会返回 `InvalidParameter: image size must be at least 3686400 pixels`；因此远程请求使用最小满足限制的 16:9 `2560x1440`。阿里云万相默认使用 `wan2.7-image-pro` + `2K`。下载后保存远程原图，UI 负责缩小显示；不要为了缩放再调用一次图片生成 API。
- 注意 `flutter_test` 默认会拦截 `HttpClient` 并让 HTTP 请求本地返回 400；任何 live API 测试都必须先清除测试框架的 HTTP override，否则 400 不能当作火山接口真实错误。
- 如果 live probe 在普通测试环境里返回空 body 的 HTTP 400，先按“测试环境拦截”处理：检查 `HttpOverrides.global = null`、网络权限/沙箱授权、API Key 是否真实读取，再讨论内容安全。不要先猜敏感词。
- Seedream 图片 API 笔记放在 `docs/volc_ark_seedream_image_api_notes.md`；涉及模型、endpoint、鉴权、组图、尺寸、缓存 key 的改动时先看这份文档。
- 调试兼容注入：`--dart-define TOMATO_VOLC_TTS_RESOURCE_ID=...`、`--dart-define TOMATO_VOLC_TTS_SPEAKER_ID=...`
- 旧的统一语音 key 和分服务语音 key 字段不再作为兜底
- 设置页可以保存/清除百炼、方舟和语音 key；UI 与 bridge payload 只能展示配置状态和脱敏 mask，不得回传明文 key。
