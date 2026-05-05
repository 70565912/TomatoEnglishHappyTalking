调用 StartVoiceChat 接口，在你的应用中接入一个具备听说能力的 AI，使其与真人用户进行自然、流畅、真人感的实时对话。
:::warning

* 该接口仅在使用 AI 音视频互动方案服务和应用时生效。若您当前业务中使用的是实时对话式 AI 应用，请使用接口 [StartVoiceChat（2024-12-01）](https://www.volcengine.com/docs/6348/1558163)，或[迁移至 AI 音视频互动方案](https://www.volcengine.com/docs/6348/2137638)。
* AI 音视频互动方案与实时对话式 AI 为不同的商品，在计费和集成方式上均有差异。详细说明，参见[产品简介](https://www.volcengine.com/docs/6348/1310537?lang=zh#%E4%B8%8E%E5%AE%9E%E6%97%B6%E5%AF%B9%E8%AF%9D%E5%BC%8F-ai-%E7%9A%84%E5%B7%AE%E5%BC%82)。

:::
<span id="AxxbdIEk"></span>
## 注意事项

* **请求频率**：单账号下 QPS 不得超过 60。
* **请求接入地址**：仅支持 `rtc.volcengineapi.com`。
* **任务状态监控**：调用本接口后返回 `200`，仅代表任务**下发成功**，不代表 AI 已成功入房或可以正常工作。你可以前往 [控制台-功能配置-回调配置](https://console.volcengine.com/conversational-ai/devTools/config?tab=callback)开启事件回调，通过监听 `VoiceChat` 事件来任务状态。具体操作及事件说明，请参见[接收 AI 对话任务状态](https://www.volcengine.com/docs/6348/1798101)。
* **任务生命周期与成本管理**：调用该接口开启 AI 对话后，若真人用户退出房间，180s 后该任务会自动停止，但该 180s 内仍会计费。你可以通过 `AgentConfig.IdleTimeout` 参数自定义此等待时长。为避免不必要的费用，建议真人用户退出房间后，，及时调用 [StopVoiceChat](https://www.volcengine.com/docs/6348/2123349) 接口关闭对话任务。

<span id=".6LCD55So5o6l5Y-j"></span>
## 调用接口
发送 HTTP(S) 请求时，你需要符合火山引擎规范，具体请参见[如何调用 OpenAPI](https://www.volcengine.com/docs/6348/1899868)。
<span id=".6K-35rGC6K-05piO"></span>
## 请求说明

* 请求方式：POST
* 请求地址：https://rtc.volcengineapi.com?Action=StartVoiceChat&Version=2025\-06\-01

<span id=".6K-35rGC5Y-C5pWw"></span>
## 请求参数
下表仅列出该接口特有的请求参数和部分公共参数。完整公共请求参数请见[公共参数](https://www.volcengine.com/docs/6348/1178321)。
<span id="Query"></span>
### Query


**Action ** <span data-label="purple">String</span> %%require%%示例值：`StartVoiceChat`
接口名称。当前 API 的名称为 `StartVoiceChat`。


**Version ** <span data-label="purple">String</span> %%require%%示例值：`2025-06-01`
接口版本。当前 API 的版本为 `2025-06-01`。


<span id="Body"></span>
### Body


**AppId ** <span data-label="purple">String</span> %%require%%示例值：`661*****3cf`
AI 音视频互动方案的应用 AppId。
:::warning

* ❌ 请勿使用 **实时对话式 AI** 应用的 AppId。
* ✅ 必须使用 **AI 音视频互动方案 ** 应用的 AppId 且需与生成 RTC 鉴权 Token 时使用的 AppId 一致。可前往 [AI 音视频互动方案-应用管理](https://console.volcengine.com/conversational-ai/devTools/appIdManage)获取。

:::

**RoomId ** <span data-label="purple">String</span> %%require%%示例值：`Room1`
RTC 房间的 ID。需与生成 RTC 鉴权 Token 时使用的 RoomId 一致。


**TaskId ** <span data-label="purple">String</span> %%require%%示例值：`task1`
任务 ID。由您自行定义，用于唯一标识该对话任务。后续调用 `UpdateVoiceChat`（更新）或 `StopVoiceChat`（结束）时必须传入相同的 `TaskId`。

* **命名规范**：请参见[参数赋值规范](https://www.volcengine.com/docs/6348/70114)。
* **唯一性规则**：在同一个 AppId 和 RoomId 组合下，TaskId 必须唯一。不同房间可以使用相同的 TaskId。


**BusinessId ** <span data-label="purple">String</span> `可选` 示例值：`chatroom`
业务标识 ID，用于区分不同业务。可[在控制台获取](https://console.volcengine.com/rtc/aigc/bidRTC)。


**Config ** <span data-label="purple">Object</span> %%require%%示例值：`-`
智交互服务配置，包括语音识别（ASR）、语音合成（TTS）、大模型(LLM)、字幕和函数调用（Function Calling）配置。

**ASRConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
语音识别（ASR）相关配置。
:::warning
启用端到端语音模型（`S2SConfig`）后，该配置会失效。

:::
**Provider ** <span data-label="purple">String</span> %%require%%示例值：`volcano`
语音识别服务的提供商：

* `volcano`：火山引擎的豆包语音服务。可使用以下模型：
   * 流式语音识别（识别速度更快）
   * 流式语音识别大模型（识别准确率更高）
      两者详细差异（如可识别语种、支持的能力等），请参见[流式语音识别](https://www.volcengine.com/docs/6561/109880)和[流式语音识别大模型](https://www.volcengine.com/docs/6561/1354871)。
* `ai_gateway`：自定义语音识别模型（通过火山边缘大模型网关接入的）


**ProviderParams ** %%require%%示例值：`-`
服务配置参数。不同服务，`ProviderParams` 包含的字段不同：

* [火山流式语音识别大模型](#volcanolmasrconfig)
* [火山流式语音识别（小模型）](#volcanoasrconfig)
* [自定义语音识别](#thirdpartyasrconfig)


<span id="volcanolmasrconfig3"></span>
#### 火山流式语音识别大模型（参数透传） <span data-label="purple">Object</span>
此方式支持流式语音识别大模型服务的所有配置参数（如直传不支持的 VAD 顺滑）， 相较于直传配置更灵活、功能更全面。

**Mode ** <span data-label="purple">String</span> %%require%%示例值：`bigmodel`
模型类型。该参数固定取值：`bigmodel`，表示火山引擎语音识别大模型。


**VolcanoASRParameters ** <span data-label="purple">String</span> %%require%%示例值：`"{"request":{"vad_segment_duration":1000,"end_window_size":500}}"`
一个 JSON 字符串，用于透传火山引擎语音识别大模型 ASR 服务的 [原生 API 参数](https://www.volcengine.com/docs/6561/1354869)。
**如何配置该字段**：

* **基础用法**：若您不需要进行任何自定义配置，接受平台所有默认行为，可将该字段值设为空的 JSON 对象，即 `VolcanoASRParameters: "{}"`。
* **高级用法**：若您需要判停、热词等功能，则需要通过此参数传入对应的参数配置。
   1. 根据需求，参考文档 [大模型流式语音识别API](https://www.volcengine.com/docs/6561/1354869) 选取您需要的参数构建一个 JSON 对象，然后将其转为 JSON 字符串。
      :::tip

      请详细阅读文档 [大模型流式语音识别API](https://www.volcengine.com/docs/6561/1354869)，确保您已充分了解所需透传参数的具体行为和潜在影响。

      :::
   2. 将该 JSON 对象压缩并转义为字符串后，作为 VolcanoASRParameters 的值传入。例如，要将静音判停阈值设为 500 毫秒，则为 `"{\"request\":{\"end_window_size\":500}}"`。

**可透传的参数：**

* **支持的参数**：[大模型流式语音识别API](https://www.volcengine.com/docs/6561/1354869) 中的请求参数（即 发送 full client request 表格下的参数）。**下方无需透传的参数除外**。
* **不可透传的参数**：
   以下参数由平台统一管理，您的 JSON 对象中不可包含这些字段：
   * user
   * request.show_speech_rate
   * request.show_volume
   * request.enable_lid
   * request.enable_emotion_detection
   * request.enable_gender_detection
   * request.show_utterances
   * request.result_type
   * request.model_name
   * request.force_to_speech_time
   * audio.format
   * audio.codec
   * audio.rate
   * audio.bits
   * audio.channel


**Credential ** <span data-label="purple">Object</span> `可选` 示例值：`-`
指定要使用的流式语音识别大模型版本，默认 1.0 版本。

**ApiResourceId ** <span data-label="purple">String</span> `可选` 示例值：`volc.bigasr.sauc.duration`
指定要使用的流式语音识别大模型版本：

* `volc.bigasr.sauc.duration`（默认值）：流式语音识别大模型 1.0。
* `volc.seedasr.sauc.duration`：流式语音识别大模型 2.0。

:::warning
使用流式语音识别大模型 2.0 版本时，`StreamMode` 取值只能为 `1` 或 `2`（推荐）。

:::


**StreamMode ** <span data-label="purple">Integer</span> `可选` 示例值：`2`
语音识别结果返回模式：

* `0`（默认值）：流式输入流式输出。识别结果会分段、实时地返回。该模式下识别速度更快，适用于对实时性要求高的场景，如实时字幕。
* `1`：流式输入非流式输出。即在完整接收并处理完整个语音片段后，一次性返回最终的识别结果。该模式下识别准确率更高，适用于对实时性要求不高的场景，如会议录音转写。
* `2`（推荐）：双向流式优化版。在流式输入和流式输出的基础上，支持对检测到的完整语句片段进行二次非流式识别，兼顾实时性与准确性。

> 要启用二次识别，您必须在 `VolcanoASRParameters` 参数中透传 `"enable_nonstream": true`。

:::warning
使用流式语音识别大模型 2.0 版本时，`StreamMode` 取值只能为 `1` 或 `2`，推荐用 `2`。

:::

**ContextHistoryLength ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
上下文轮次。将最近指定轮数会话内容送入流式语音识别大模型，有助于模型理解当前对话的背景，从而提升大模型识别准确性。
取值范围为 `[0, 20]`，默认为 `0` 表示不开启该功能。



<span id="volcanolmasrconfig"></span>
#### 火山流式语音识别大模型（参数直传） <span data-label="purple">Object</span>
此方式封装了流式语音识别大模型的部分配置参数，接入简单，但无法使用该服务的全部功能。

**Mode ** <span data-label="purple">String</span> %%require%%示例值：`bigmodel`
模型类型。该参数固定取值：`bigmodel`，表示火山引擎语音识别大模型。


**ApiResourceId ** <span data-label="purple">String</span> `可选` 示例值：`volc.bigasr.sauc.duration`
指定要使用的流式语音识别大模型版本：

* `volc.bigasr.sauc.duration`（默认值）：流式语音识别大模型 1.0。
* `volc.seedasr.sauc.duration`：流式语音识别大模型 2.0。

:::warning
使用流式语音识别大模型 2.0 时，`StreamMode` 取值只能为 `1` 或 `2`（推荐）。

:::

**StreamMode ** <span data-label="purple">Integer</span> `可选` 示例值：`2`
语音识别结果返回模式：

* `0`（默认值）：流式输入流式输出。识别结果会分段、实时地返回。该模式下识别速度更快，适用于对实时性要求高的场景，如实时字幕。
* `1`：流式输入非流式输出。即在完整接收并处理完整个语音片段后，一次性返回最终的识别结果。该模式下识别准确率更高，适用于对实时性要求不高的场景，如会议录音转写。
* `2`（推荐）：双向流式优化版。在流式输入和流式输出的基础上，支持对检测到的完整语句片段进行二次非流式识别，兼顾实时性与准确性。
   > 要启用二次识别，您必须将 `enable_nonstream` 参数设置为 `true`。

:::warning
使用流式语音识别大模型 2.0 版本时，`StreamMode` 取值只能为 `1` 或 `2`，推荐用 `2`。

:::

**enable_nonstream ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否在双向流式优化版（`StreamMode: 2`）的基础上开启二遍识别。

* `false`（默认值）：不开启。
* `true`：开启二遍识别。开启后，当用户的说话停顿时间超过 `ASRConfig.VADConfig.SilenceTime` 时，系统会对该分句音频再进行一次识别（此次识别为流式输入非流式输出）。

:::warning
`enable_nonstream` 为 `true` 仅在 `StreamMode` 为 `2`时才生效。

:::

**context ** <span data-label="purple">String</span> `可选` 示例值：`"{\"hotwords\": [{\"word\": \"CO2\"},{\"word\": \"雨伞\"},{\"word\": \"鱼\"}]}"`
热词直传（通过 JSON 字符串直接传入）。默认为空。
如果某些词汇（比如人名、产品名等）的识别准确率较低，可以将其作为热词传入 ASR 模型，提高输入词汇的识别准确率。例如传入"雨伞"热词，发音相似的词会优先识别为“雨伞”。

* 大小限制：热词传入最大值为 200 tokens，超出会自动截断。
* 格式要求：JSON 字符串。


**context_history_length ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
上下文轮次。将最近指定轮数会话内容送入流式语音识别大模型，有助于模型理解当前对话的背景，从而提升大模型识别准确性。
取值范围为 `[0, 20]`。`0`（默认值）表示不开启该功能。



<span id="volcanoasrconfig"></span>
#### 火山流式语音识别（小模型） <span data-label="purple">Object</span>

**Mode ** <span data-label="purple">String</span> %%require%%示例值：`smallmodel`
模型类型。固定取值：`smallmodel`，表示火山引擎流式语音识别模型。


**Cluster ** <span data-label="purple">String</span> %%require%%示例值：`volcengine_streaming_common`
传入集群标识（Cluster ID）。取值请参见 [Cluster ID（火山引擎流式语音识别）](/docs/6348/1827286)。



<span id="thirdpartyasrconfig"></span>
#### 自定义语音识别 <span data-label="purple">Object</span>
:::warning
配置前请确保：

* 已准备好定义 ASR 服务接口，并满足[自定义语音识别（ASR）模型接口协议](https://www.volcengine.com/docs/6893/1593361)。
* 已将定义 ASR 服务接入到火山边缘智能大模型网关。具体操作，请参见[调用自部署模型](https://www.volcengine.com/docs/6893/1528786)。


:::
**URL ** <span data-label="purple">String</span> %%require%%示例值：`wss://ai-gateway.vei.volces.com/v1/realtime?model=customasr`
边缘大模型网关的服务接入点 URL。StartVoiceChat 会通过此地址连接到网关，网关再将请求转发给你的自定义 ASR 服务。

* URL 格式：`wss://ai-gateway.vei.volces.com/v1/realtime?model=<ASR 调用名称>`。
* <ASR 调用名称\>：需替换为您在边缘大模型网关控制台中自定义的模型`调用名称`。获取路径：[边缘大模型网关_大模型管理](https://console.volcengine.com/vei/aigateway/llm-list)。

<span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_a206083fc1674059e457f3485caf4052.png =591x) </span>


**APIKey ** <span data-label="purple">String</span> %%require%%示例值：`sk-xxxxxx`
网关访问密钥，自定义 ASR 接入边缘大模型网关时配置的。可前往以下路径获取：[边缘大模型网关_网关访问密钥](https://console.volcengine.com/vei/aigateway/tokens-list)。


**ExtraData ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"custom_param": "value1"}`
自定义参数，将以 JSON 格式透传给你的自定义 ASR 服务。


**ExtraHeader ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"custom_header": "value"}`
自定义透传 Header。一个 JSON 对象，其键值对将作为额外的 HTTP Header 字段，透传到您的自定义 ASR 服务请求中，可用于鉴权或其他自定义逻辑。




**VADConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
VAD（语音检测） 配置。

**SilenceTime ** <span data-label="purple">Integer</span> `可选` 示例值：`600`
判停静音时长。当真人用户静音时长超过该设定值时，系统判定用户本轮说话结束。
取值范围为 `[500，3000)`，单位为 `ms`，默认值为 `600`。


**AIVAD ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启智能语义判停。
启用后，当用户静音时长达到 `SilenceTime` 时，系统会引入 AI 模型来分析用户语义是否完整；如果语义完整，系统才判定用户本轮发言结束。该功能有效提升在复杂对话场景下（如长句、思考停顿）判停的准确性，避免将一句完整的话错误地拆分为多轮对话。

* `true`：开启。为了达到最佳的断句效果，建议组合使用 `SilenceTime` 和 `LLMConfig.Prefill`。具体配置建议，请参见[推荐配置](/docs/6348/1544164#.6L-b6Zi26YWN572u77ya6K-t5LmJ5Yik5YGc5LiO6aKE5aGr5YWF)。
* `false`（默认值）：关闭。

:::warning
AIVAD 功能目前在限时免费公测阶段。

:::

**ForceBeginThreshold ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
首帧打断阈值。
当 AI 正在播报时，若系统（基于 VAD）检测到用户语音持续时长达到该设定值，AI 立即停止播报。此过程不完全依赖 ASR 识别具体文字。

* 取值范围： `[0, 1000]`。
* 默认值：`0`，即禁用此功能。

:::tip
在嘈杂环境下，设置过小的阈值可能导致 AI 被环境噪音误打断（如突然的关门声、咳嗽声）。

:::

**ForceEnd ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启辅助 VAD 强制判停。
开启后，一旦用户静音时长达到 `SilenceTime`，系统会立即判定用户发言结束，并终止本轮 ASR 识别。适用于对响应速度要求极高，且用户说话节奏较快的场景。此过程基于 VAD 实现，不依赖 ASR 判停。

* `false`（默认值）：关闭。
* `true`：开启。



**VolumeGain ** <span data-label="purple">Float</span> `可选` 示例值：`0.3`
音量增益值。增益值越低，采集音量越低。适当低增益值可减少噪音引起的 ASR 错误识别。
默认值为 `1.0`，推荐值 `0.3`。


**InterruptConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
语音打断配置，支持基于说话时长打断、关键词打断。
:::warning
该功能仅在 `InterruptMode` 为 `0`时生效。

:::
**InterruptSpeechDuration ** <span data-label="purple">Integer</span> `可选` 示例值：`500`
自动打断的触发阈值，即真人用户持续说话时长达到设定值，AI 才自动停止输出。

* 取值范围：`0` 或 `[200，3000]`，单位为 `ms`。值越大，AI 越不容易被打断。
* 默认值：`0`，表示用户发出声音且包含真实语义时，AI 就停止输出。


**InterruptKeywords ** <span data-label="purple">String[]</span> `可选` 示例值：`["停止", "停下"]`
触发打断的关键词列表。
当用户语音中识别到列表中的任意关键词时，AI 将立即停止输出，以降低背景环境人声误打断的干扰。默认为空，表示不触发关键词打断。
:::warning
使用该参数时，建议 `InterruptSpeechDuration` 设置为 `0`，避免自动打断触发阈值过高，导致关键词打断不生效。

:::


**TurnDetectionMode ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
新一轮对话的触发方式。

* `0`（默认值）：自动触发。服务端检测到完整的一句话后，自动触发新一轮对话。
* `1`：不自动触发。您可以在业务逻辑中自行实现手动触发新一轮会话，如通过 API 指令（比如按键），精确控制交互流程。

具体使用方法，参看[判停与对话触发](https://www.volcengine.com/docs/6348/1544164)。


**FarfieldConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
远场人声抑制配置。
通过抑制距离麦克风 3\-5 米以外的背景人声，解决远场场景下的 AI 误触发、误识别及判停延迟等问题。该功能适用于耳机、手机等收音效果较好的设备。
:::warning

* 该功能仅在使用火山流式语音识别大模型时生效。
* 由于不同硬件设备的收音特性差异较大，必须根据实际设备类型和应用场景选择合适的 `Level` 或 `Threshold`。若参数设置不当（如抑制过强），可能会导致正常用户的声音也被抑制，影响收音质量。建议根据实际业务场景进行细致调试。


:::
**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启远场人声抑制功能。

* `true`：开启。
* `false`（默认值）：关闭。


**Level ** <span data-label="purple">String</span> `可选` 示例值：`Medium`
噪声抑制强度，系统将根据环境底噪自动动态调整过滤门槛。可取值如下：

* `High`：强抑制，过滤效果最强，适用于极其嘈杂或远场人声干扰严重的场景。
* `Medium`（默认值）：中抑制，在抑制干扰与保留微弱人声之间取得平衡。
* `Low`：弱抑制，过滤效果最弱，保留更多音频细节，适用于相对安静的环境。

若 `Threshold > 0` ，本配置失效。


**Threshold ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
自定义噪声抑制阈值。

* 取值范围：`[0, 127]`，数值越小抑制越强，`127` 接近静音。
* 默认值： `0`，表示不启用自定义噪声抑制，由 `Level` 抑制噪声。

若此值 \> 0，则 `Level` 配置失效。不同硬件设备的阈值可能存在差异，建议优先使用 `Level` 参数。


**FixedSource ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
音源位置是否固定：

* `true`：若音源与麦克风位置相对固定（如使用耳机、听筒模式），请设为该值。
* `false`（默认值）：若音源与麦克风位置不固定（如使用扬声器），请设为该值。



**ExpireTime ** <span data-label="purple">Integer</span> `可选` 示例值：`1000`
强制判停时长。单位：ms。
从 ASR 识别到最后一段文字起，若经过 `ExpireTime` 时长仍未触发静音判停（即 `SilenceTime`），则强制判定用户本轮说话已结束。
适用于背景噪声大、环境干扰严重（导致 VAD/ASR 无法准确判断静音）时，进行兜底强制判停。
建议设置为 `SilenceTime` 的 1.5 倍。



**TTSConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
语音合成（TTS）相关配置。
:::warning
启用端到端语音模型（`S2SConfig`）后，该配置会失效。

:::
**Provider ** <span data-label="purple">String</span> %%require%%示例值：`volcano_bidirection`
语音合成服务提供商，使用不同语音合成服务时，取值不同。支持使用的语音合成服务及对应取值如下：

* `volcano_bidirection`：火山引擎 TTS 模型（流式输入流式输出），支持如下模型：
   * 火山语音合成大模型（流式输入流式输出）
   * 火山声音复刻大模型（流式输入流式输出）
* `volcano`：火山引擎 TTS 模型（非流式输入流式输出），支持如下模型：
   * 火山语音合成大模型（非流式输入流式输出）
   * 火山声音复刻大模型（非流式输入流式输出）
   * 火山语音合成
* `minimax`：MiniMax 语音合成
* `ai_gateway`：自定义语音合成模型（通过火山边缘大模型网关接入的）


**ProviderParams ** %%require%%示例值：`-`
配置所选的语音合成服务。不同服务下，该结构包含字段不同：

* [火山语音合成大模型（流式输入流式输出）](#volcanobigbittsconfig)
* [火山语音合成大模型（非流式输入流式输出）](#volcanobittsconfig)
* [火山声音复刻大模型（流式输入流式输出）](#volcanodubittsconfig)
* [火山声音复刻大模型（非流式输入流式输出）](#volcanoduttsconfig)
* [火山语音合成](#volctts)
* [MiniMax 语音合成](#minimaxtts)
* [自定义语音合成](#thirdpartyttsconfig)


<span id="volcanobigbittsconfig2"></span>
#### 火山语音合成大模型（流式输入流式输出_参数透传） <span data-label="purple">Object</span>

**Credential ** <span data-label="purple">Object</span> `可选` 示例值：`-`
指定要使用的语音合成大模型的版本，默认为 1.0 版本。

**ResourceId ** <span data-label="purple">String</span> `可选` 示例值：`volc.service_type.10029`
指定要使用的语音合成大模型的版本：

* `seed-tts-1.0` 或 `volc.service_type.10029`（默认值）：语音合成大模型 1.0
* `seed-tts-2.0`：语音合成大模型 2.0



**VolcanoTTSParameters ** <span data-label="purple">String</span> %%require%%示例值：`"{"req_params":{"speaker":"zh_female_linjianvhai_moon_bigtts"}}"`
一个 JSON 字符串，用于透传火山引擎双向流 TTS 服务的 [原生 API 参数](https://www.volcengine.com/docs/6561/1329505)。
**如何传**：根据 [双向流式 TTS API 文档](https://www.volcengine.com/docs/6561/1329505)，找到 **Payload 请求参数** 部分，遵循以下原则构建一个标准 JSON 对象，然后将该 JSON 对象转为一个 JSON 字符串。参数要求如下：

* **必填参数**：必须包含参数 `req_params.speaker`（音色）。
   :::warning
   音色需与在 `Credential.ResourceId` 指定的模型版本匹配 ，即使用语音合成大模型 1.0 服务仅支持 1.0 支持的音色；使用语音合成大模型 2.0 服务只能使用 2.0 支持的音色。详情可参见[音色列表](https://www.volcengine.com/docs/6561/1257544)。
   :::
   * **不可传入的参数**：不可以包含以下由平台管理的参数：
   * user
   * event
   * namespace
   * req_params.text
   * req_params.audio_params.format
   * req_params.audio_params.enable_timestamp
   * req_params.additions.max_length_to_filter_parenthesis
   * req_params.additions.cache_config、req_params.additions.enable_latex_tn：仅当使用语音合成大模型 2.0（`ResourceId` 为 `seed-tts-2.0`）时，若启用了对齐时间戳的字幕（`SubtitleMode: 0`），不可传入。
* **其他参数**：根据业务需求按需选择（例如 `req_params.audio_params.speech_rate`）。

**示例**：以设置指定的音色（必填）并调整语速（可选）为例

1. 先构建如下 JSON：
   ```JSON
   {
       "req_params": {
           "speaker": "zh_female_linjianvhai_moon_bigtts",
           "audio_params": {
               "speech_rate": 100
           }
       }
   }
   ```

2. 然后将其转换为 JSON 字符串再传入：`"{\"req_params\":{\"speaker\":\"zh_female_linjianvhai_moon_bigtts\",\"audio_params\":{\"speech_rate\":100}}}"`



<span id="volcanobigbittsconfig"></span>
#### 火山语音合成大模型（流式输入流式输出_参数直传） <span data-label="purple">Object</span>
此方式支持语音合成大模型（流式输入流式输出）所有配置参数，相较于直传配置更灵活、功能更全面。

**ResourceId ** <span data-label="purple">String</span> `可选` 示例值：`volc.service_type.10029`
指定要使用的语音合成大模型的版本：

* `seed-tts-1.0` 或 `volc.service_type.10029`（默认值）：语音合成大模型 1.0
* `seed-tts-2.0`：语音合成大模型 2.0


**audio ** <span data-label="purple">Object</span> %%require%%示例值：`-`
火山引擎语音合成大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> %%require%%示例值：`zh_female_linjianvhai_moon_bigtts`
音色。填入音色对应的标识 `voice_type`，需与在 `ResourceId` 中指定的模型版本匹配：

* 使用语音合成大模型 1.0 服务仅支持 1.0 支持的音色。
* 使用语音合成大模型 2.0 服务仅支持 2.0 支持的音色。

详情请参见[音色列表](https://www.volcengine.com/docs/6561/1257544)。


**speech_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
语速。取值范围 `[-50, 100]`，取值越大，语速越快。

* `100`：2.0 倍速。
* `-50`：0.5 倍速。
* `0`（默认值）：原语速。



**Additions ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成大模型服务高级配置。

**enable_latex_tn ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
播报 LaTeX 公式。启用后，AI 能够以自然语言朗读文本中的 LaTeX 格式的数学公式。

* `false`（默认值）：不播报。
* `true`：播报。 为`true` 时，`disable_markdown_filter` 也需为 `true` 才生效。

**效果示例**：

* LLM 返回：`根据公式 a^2 + b^2 = c^2 可知...`
* AI 播报：`根据公式 a 的平方加上 b 的平方等于 c 的平方 可知...`
* 字幕显示：`根据公式 a^2 + b^2 = c^2 可知...`

:::warning
使用语音合成大模型 2.0 或声音复刻大模型 2.0 时，该功能与对齐时间戳的字幕功能（`SubtitleMode: 0`）不兼容，不可同时开启。

:::

**disable_markdown_filter ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
过滤 Markdown 格式。
启用后，语音合成时会自动过滤 LLM 返回文本中的 Markdown 格式符号（如加粗、标题等），确保语音播报的连贯性。

* `false`（默认值）：不过滤。
* `true`：过滤。

**效果示例**：

* LLM 返回：`请执行 **grep** 命令查看日志。`
* AI 播报：`请执行 grep 命令查看日志。`
* 字幕显示：`请执行 **grep** 命令查看日志。`


**enable_language_detector ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否自动识别语种。[支持哪些语种？](https://www.volcengine.com/docs/6561/1257543)

* `true`：自动识别。
* `false`：不自动识别。

默认值为 `false`。




<span id="volcanobittsconfig"></span>
#### 火山语音合成大模型（非流式输入流式输出） <span data-label="purple">Object</span>

**audio ** <span data-label="purple">Object</span> %%require%%示例值：`-`
语音合成大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> %%require%%示例值：`zh_female_meilinvyou_moon_bigtts`
音色。仅支持使用语音合成大模型 1.0 支持的音色，具体 `voice_type` 值参见[音色列表](https://www.volcengine.com/docs/6561/1257544?lang=zh#%E8%B1%86%E5%8C%85%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90%E6%A8%A1%E5%9E%8B1-0-%E9%9F%B3%E8%89%B2%E5%88%97%E8%A1%A8)。


**speed_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值范围为 `[0.2, 3]`，默认值为 `1.0`，通常保留一位小数即可。




<span id="volctts"></span>
#### 火山语音合成 <span data-label="purple">Object</span>

**audio ** <span data-label="purple">Object</span> %%require%%示例值：`-`
火山引擎语音合成服务音频配置。

**voice_type ** <span data-label="purple">String</span> %%require%%示例值：`BV001_streaming`
音色。支持的取值：

* `BV001_streaming`：通用女生。
* `BV002_streaming`：通用男生。


**speed_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值范围为 `[0.2, 3]`，默认值为 `1.0`，通常保留一位小数即可。取值越大，语速越快。


**volume_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音量。取值范围为 `[0.1, 3]`，默认值为 `1.0`，通常保留一位小数即可。取值越大，音量越高。


**pitch_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音高。取值范围为 `[0.1, 3]`，默认值为 `1.0`，通常保留一位小数即可。取值越大，音调越高。




<span id="volcanodubittsconfig"></span>
#### 火山声音复刻大模型（流式输入流式输出） <span data-label="purple">Object</span>
此方式封装了声音复刻大模型（流式输入流式输出）部分通用参数，接入简单，但无法使用该服务的全部功能。

**audio ** <span data-label="purple">Object</span> %%require%%示例值：`-`
火山引擎声音复刻大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> %%require%%示例值：`S_U****ft1`
经过训练后的复刻声音 ID。你需要先进行以下操作：

1. [购买声音复刻资源](https://console.volcengine.com/conversational-ai/purchase)。
   * 音色 1.0：对应火山引擎声音复刻大模型 1.0，合成速度较快，适用于对实时交互速度有极致要求的场景，如高频播报、系统提示、快节奏问答。
   * 音色 2.0：对应火山引擎声音复刻大模型 2.0，情感表现力更强，能够更好地模拟真人的语调、停顿和情感变化。适用于注重沉浸式体验的场景，如 AI 陪伴、故事播讲、虚拟主播等。
2. [训练音色并获取声音 ID](https://console.volcengine.com/conversational-ai/myVoice/voiceCloning)。
   <span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_ecc579b4ca43d705a0b7c359a9f164d3.png =427x) </span>


**speech_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
语速。取值范围 `[-50, 100]`，取值越大，语速越快。

* `100`：2.0 倍速。
* `-50`：0.5 倍速。
* `0`（默认值）：原语速。



**ResourceId ** <span data-label="purple">String</span> %%require%%示例值：`seed-icl-2.0`
指定要使用的声音复刻大模型服务版本。需要与您在 `voice_type` 中指定的音色版本一致：

* `seed-icl-1.0` ：声音复刻大模型 1.0
* `seed-icl-2.0`：声音复刻大模型 2.0


**Additions ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎声音复刻大模型服务高级配置。

**enable_latex_tn ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
播报 LaTeX 公式。启用后，AI 能够以自然语言朗读文本中的 LaTeX 格式的数学公式。

* `false`（默认值）：不播报。
* `true`：播报。 为`true` 时，`disable_markdown_filter` 也需为 `true` 才生效。

**效果示例**：

* LLM 返回：`根据公式 a^2 + b^2 = c^2 可知...`
* AI 播报：`根据公式 a 的平方加上 b 的平方等于 c 的平方 可知...`
* 字幕显示：`根据公式 a^2 + b^2 = c^2 可知...`

:::warning
使用语音合成大模型 2.0 或声音复刻大模型 2.0 时，该功能与对齐时间戳的字幕功能（`SubtitleMode: 0`）不兼容，不可同时开启。

:::

**disable_markdown_filter ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
过滤 Markdown 格式。
启用后，语音合成时会自动过滤 LLM 返回文本中的 Markdown 格式符号（如加粗、标题等），确保语音播报的连贯性。

* `false`（默认值）：不过滤。
* `true`：过滤。

**效果示例**：

* LLM 返回：`请执行 **grep** 命令查看日志。`
* AI 播报：`请执行 grep 命令查看日志。`
* 字幕显示：`请执行 **grep** 命令查看日志。`


**enable_language_detector ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否自动识别语种。

* `true`：自动识别。
* `false`：不自动识别。

默认值为 `false`。




<span id="volcanoduttsconfig"></span>
#### 火山声音复刻大模型（非流式输入流式输出） <span data-label="purple">Object</span>
此方式封装了语音合成大模型（流式输入流式输出）部分通用参数，接入简单，但无法使用该服务的全部功能。

**audio ** <span data-label="purple">Object</span> %%require%%示例值：`-`
火山引擎声音复刻大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> %%require%%示例值：`S_U****ft1`
经过训练后的复刻声音 ID。请确保你已经进行以下操作：

1. [购买声音复刻资源](https://console.volcengine.com/conversational-ai/purchase)（**购买音色 1.0**）。
2. [训练音色并获取声音 ID](https://console.volcengine.com/conversational-ai/myVoice/voiceCloning)。
   <span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_ecc579b4ca43d705a0b7c359a9f164d3.png =418x) </span>


**speed_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值范围为 `[0.8, 2]`，通常保留一位小数即可，取值越大，语速越快。
默认值为 `1.0` 表示原语速。



**app ** <span data-label="purple">Object</span> %%require%%示例值：`-`
火山引擎声音复刻大模型服务应用配置。

**cluster ** <span data-label="purple">String</span> %%require%%示例值：`volcano_icl`
集群标识（Cluster ID），必须为 `volcano_icl`。



**ResourceId ** <span data-label="purple">String</span> %%require%%示例值：`volc.service_type.10029`
声音复刻大模型服务版本。固定取值 `seed-icl-1.0` ，表示声音复刻 1.0 字符版。



<span id="minimaxtts"></span>
#### MiniMax 语音合成 <span data-label="purple">Object</span>

**Authorization ** <span data-label="purple">String</span> %%require%%示例值：`eyJhbG****SUzI1N`
API 密钥。前往 [Minimax 账户管理-接口密钥](https://platform.minimaxi.com/login)获取。


**Groupid ** <span data-label="purple">String</span> %%require%%示例值：`983*****669`
用户所属组 ID。前往 [Minimax 账号信息-基本信息](https://platform.minimaxi.com/login)获取。


**model ** <span data-label="purple">String</span> %%require%%示例值：`speech-01-turbo`
发起请求的模型版本：

* `speech-01-turbo`：最新模型，拥有出色的效果与时延表现。
* `speech-01-240228`：稳定版本模型，效果出色。
* `speech-01-turbo-240228`：稳定版本模型，时延更低。


**URL ** <span data-label="purple">String</span> %%require%%示例值：`https://api.minimax.chat/v1/t2a_v2`
请求语音合成 URL，该参数固定取值：`https://api.minimax.chat/v1/t2a_v2`。


**voice_setting ** <span data-label="purple">Object</span> `可选` 示例值：`-`
音频配置。

**speed ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值越大，语速越快。
取值范围为 `[0.5, 2]`，默认值为 `1.0`。


**vol ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音量。取值越大，音调越高。
取值范围为 `(0, 10]`，默认值为 `1.0`。


**pitch ** <span data-label="purple">Float</span> `可选` 示例值：`0`
语调。取值越大，语调越高。
取值范围为 `[-12, 12]`，且必须为整数。
默认值为 `0`，表示原音色输出。


**voice_id ** <span data-label="purple">String</span> `可选` 示例值：`male-qn-jingying`
系统音色编号/复刻音色编号。

* 系统音色可前往 [voice_setting.voice_id](https://platform.minimaxi.com/document/T2A%20V2?key=66719005a427f0c8a5701643#YqSh1KAoyms1WH4XJrdeIrrb) 查询。
* 克隆音色参看 [FAQ](https://platform.minimaxi.com/document/FAQ?key=66701d031d57f38758d581be)。

:::warning
`voice_id` 与 `timber_weights`必须设置其中一个。

:::


**pronunciation_dict ** <span data-label="purple">Object</span> `可选` 示例值：`-`
特殊标注配置。可对特殊文字、符号指定发音。

**tone ** <span data-label="purple">String[]</span> `可选` 示例值：`["燕少飞/(yan4)(shao3)(fei1)","达菲/(da2)(fei1)"，"omg/oh my god"]`
用于替换需要特殊标注的文字、符号及对应的发音，可用于调整声调或指定其他字符的发音。格式为 `"原文字/注音"`，注音部分根据语言类型采用不同方式标注：

* 英文注音：使用对应发音的英文单词，例如：`"omg/oh my god"`。
* 中文注音：使用拼音，并在每个音节后以括号标注声调，音调用数字表示：
   * 一声（阴平）：1
   * 二声（阳平）：2
   * 三声（上声）：3
   * 四声（去声）：4
   * 轻声：5
      例如，`"燕少飞/(yan4)(shao3)(fei1)"`、`"达菲/(da2)(fei1)"`。

默认为空。



**timber_weights ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
合成音色权重设置。可通过该参数设置多种音色混合，并调整每个具体音色权重。最多支持 4 种音色混合。
:::warning
`timber_weights` 与 `VoiceSetting.voice_id`必须设置其中一个。

:::
**voice_id ** <span data-label="purple">String</span> `可选` 示例值：`male-qn-jingying`
音色编号。当前仅支持系统音色，可前往 [voice_setting.voice_id](https://platform.minimaxi.com/document/T2A%20V2?key=66719005a427f0c8a5701643#YqSh1KAoyms1WH4XJrdeIrrb) 查询。


**weight ** <span data-label="purple">Integer</span> `可选` 示例值：`1`
权重。取值为整数，单一音色取值占比越高，合成音色越像。取值范围为 `[1, 100]`。



**stream ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启流式输出。

* `false`：不开启流式输出。
* `true`：开启流式输出。

默认值为 `false`。


**language_boost ** <span data-label="purple">String</span> `可选` 示例值：`auto`
增强指定小语种/方言场景下的语音表现。不同场景下取值及含义如下：

* 不明确小语种类型：`auto`。取值为 `auto` 时，模型将自主判断小语种类型。
* 小语种：
   * `Spanish`：西班牙语
   * `French`：法语
   * `Portuguese`：葡萄牙语
   * `Korean`：韩语
   * `Indonesian`：印度尼西亚语
   * `German`：德语
   * `Japanese`：日语
   * `Italian`：意大利语
   * `auto`：自动模式
* 方言：
   * `Chinese,Yue`：粤语。`Chinese,Yue` 仅当 `MiniMaxTTSConfig.model`=`speech-01-turbo` 时生效。

默认值为空。



<span id="thirdpartyttsconfig"></span>
#### 自定义语音合成 <span data-label="purple">Object</span>

**URL ** <span data-label="purple">String</span> %%require%%示例值：`wss://ai-gateway.vei.volces.com/v1/realtime?model=ttsname`
边缘大模型网关的服务接入点 URL。StartVoiceChat 会通过此地址连接到网关，网关再将请求转发给你的定义 TTS 服务。
URL 为固定格式：`wss://ai-gateway.vei.volces.com/v1/realtime?model=<TTS 调用名称>`
其中，`<TTS 调用名称>` 需替换为在边缘大模型网关控制台中自定义的模型调用名称，获取路径：[边缘大模型网关_大模型管理](https://console.volcengine.com/vei/aigateway/llm-list)
<span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_fc7e321f92178ebced9a3bcc4f8e9262.png =589x) </span>


**APIKey ** <span data-label="purple">String</span> %%require%%示例值：`sk-xxxxxx`
网关访问密钥。将自定义模型接入边缘大模型网关时所配置的，获取路径如下：[边缘大模型网关_网关访问密钥](https://console.volcengine.com/vei/aigateway/tokens-list)。
<span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_6a5b014e0d9dc3598313f752395af14f.png =656x) </span>


**Voice ** <span data-label="purple">String</span> %%require%%示例值：`-`
音色。填入自定义 TTS 服务所支持的音色名称。


**OutputAudioSpeedRate ** <span data-label="purple">Float</span> `可选` 示例值：`0`
语速。


**OutputAudioVolume ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音量。


**OutputAudioPitchRate ** <span data-label="purple">Float</span> `可选` 示例值：`0`
音调。


**ExtraData ** <span data-label="purple">JSONMap</span> `可选` 示例值：`-`
传入自定义参数，将以 JSON 格式透传给你的自定义 TTS 服务。


**ExtraHeader ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"custom_header": "value"}`
自定义透传 Header。一个 JSON 对象，其键值对将作为额外的 HTTP Header 字段，透传到您的自定义 TTS 服务请求中，可用于鉴权或其他自定义逻辑。




**IgnoreBracketText ** <span data-label="purple">Integer[]</span> `可选` 示例值：`[1,2,3,4,5]`
过滤 LLM 返回内容中指定括号内的文字，再进行语音合成。
适用于过滤 LLM 返回的情绪标记（如“开心”）、动作描写（如“点头”）或场景备注，避免 TTS 将这些辅助信息朗读出来，提升对话的沉浸感。
支持取值（默认为空，表示不过滤）：

* `1`：中文括号 `（）`
* `2`：英文括号 `()`
* `3`：中文方括号 `【】`
* `4`：英文方括号 `[]`
* `5`：英文花括号 `{}`

**使用方法**

* **前提条件**：需先编写 Prompt，引导大模型将不需要朗读的内容（如心理活动、动作）放入指定的括号中。详细说明，可参见[控制语音播报内容](https://www.volcengine.com/docs/6348/1350596)。
* **长度限制**：单组括号内的内容长度上限为 500 字符，超出限制的内容将无法被过滤。
* **字幕显示**：一般情况下，被过滤的内容仍会显示在字幕中，但不会被播放。若括号内容位于回复的**最末端**，且被判定为独立句子（其后无其他有效语义），则会显示在字幕中。
   * `...我知无不言！(自信满满）。` → `(自信满满）。`不会显示在字幕中。
   * `...我知无不言（自信满满）！` → `(自信满满）！` 会显示在字幕中。


**Context ** <span data-label="purple">Object</span> `可选` 示例值：`-`
配置 TTS 上下文及标签解析，以控制 AI 播报的语气（如欢快、伤心）、语速和音量等，使 AI 播报更具情感和表现力。
:::warning
该功能仅在使用火山语音合成大模型（流式输入流式输出）时生效。

:::
**TagParse ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启 `{{...}}` 标签解析：

* `true`：开启。开启后，在 LLM（方舟模型、Coze 智能体或第三方大模型）的系统提示词中引导 LLM 根据语境自动生成标准格式的指令标签，标签及其内容不会被朗读或显示在字幕中。标签格式和 Prompt 编写方法，请参见[情绪识别与生成](/docs/6348/2139328)。
   > 使用方舟或第三方大模型时，需在 `LLMConfig.SystemMessages` 编写 Prompt；解析在过滤之前，配置 `IgnoreBracketText` 不影响解析。
* `false`（默认值）：关闭。`{{...}}` 及其内容将被视为普通文本处理；若 `IgnoreBracketText` 配置了过滤 `{}`，标签及内容会被过滤。


**QuoteUserQuestion ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否将用户问题作为上下文传递给 TTS，让 TTS 模型根据对话语境自动匹配合适的回复语气。

* `true`（默认值）：是。
* `false`：否。

:::warning
该字段仅在使用火山语音合成大模型 2.0 时生效，且优先级低于指令标签。

:::


**Prefill ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否将 LLM 生成结果实时送入 TTS 进行语音合成。

* `true`（默认值）：开启。该模式下 AI 响应速度最快，但若 LLM 推理内容随用户后续话语发生修正，会导致 TTS 重复合成，增加 TTS 字符消耗。
* `false`：关闭。系统会等待用户说话结束后才将文本送入 TTS，以降低 TTS 字符消耗



**LLMConfig ** `可选` 示例值：`-`
大模型相关配置。支持的大模型平台如下：

* [火山方舟模型](#arkllmconfig)
* [Coze智能体](#cozellmconfig)
* [第三方大模型/Agent](#thirdpartyllmconfig)


<span id="arkllmconfig"></span>
#### 火山方舟模型 <span data-label="purple">Object</span>

**Mode ** <span data-label="purple">String</span> %%require%%示例值：`ArkV3`
大模型平台标识。使用火山方舟平台时，该参数固定取值：`ArkV3`。


**ModelName ** <span data-label="purple">String</span> `可选` 示例值：`doubao-seed-1-8-251228`
大模型名称。支持的模型及取值，参见[支持的方舟模型](https://www.volcengine.com/docs/6348/1581714?lang=zh#72b35722)。


**Temperature ** <span data-label="purple">Float</span> `可选` 示例值：`0.1`
采样温度，用于控制生成文本的随机性和创造性，值越大随机性越高。
取值范围为 `(0, 1]`，默认值为 `0.1`。


**MaxTokens ** <span data-label="purple">Integer</span> `可选` 示例值：`1024`
输出文本的最大 token 限制。默认值为 `1024`。


**TopP ** <span data-label="purple">Float</span> `可选` 示例值：`0.3`
采样的选择范围，控制输出 token 的多样性。模型将从概率分布中累计概率超过该取值的标记中进行采样，以确保采样的选择范围不会过宽，值越大输出的 token 类型越丰富。
取值范围为 `[0, 1]`，默认值为 `0.3`。


**SystemMessages ** <span data-label="purple">String[]</span> `可选` 示例值：`["你是小宁，性格幽默又善解人意。你在表达时需简明扼要，有自己的观点。"]`
系统提示词。用于输入控制大模型行为方式的指令，定义了模型的角色、行为准则，特定的输出格式等。


**UserPrompts ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
用户提示词，可用于增强模型的回复质量，模型回复时会优先参考此处内容，引导模型生成特定的输出或执行特定的任务。
:::warning
`UserPrompts` 设有自动逐出机制：当对话总数超过 HistoryLength 限制时，最早的 `UserPrompts` 会被自动逐出，为新的对话历史腾出空间。
示例：若 HistoryLength 设置为 3 且已预存 2 轮对话。在用户与 AI 完成第 1 轮真实对话后，上下文总轮数为 3（2 预存 + 1 用户），此时无需逐出；当用户发起第 2 轮对话时，总轮数变为 4 超过限制，系统会自动移除最早的一轮预存内容，使上下文始终只保留最近的 3 轮记录。

:::
**Role ** <span data-label="purple">String</span> `可选` 示例值：`user`
发送消息的角色。支持取值 system、user 和 assistant。其中 user 和 assistant 必须成对出现（一问一答），否则大模型可能会出现未定义行为。


**Content ** <span data-label="purple">String</span> `可选` 示例值：`你是谁？`
消息内容。



**HistoryLength ** <span data-label="purple">Integer</span> `可选` 示例值：`3`
对话上下文保留轮数。默认值为 `3`。
 AI 在回复时会参考最近 N 轮的历史对话，以保证多轮对话的连贯性。
:::warning
需确保发送给大模型的总 Token 数不超过模型的上下文上限（如 8k）。即 **SystemMessages + 当前生效的 UserPrompts + HistoryLength 轮对话  <  模型最大上下文长度。**
:::
例如：历史问题轮数为 3，LLM 上下文限制为 8k，UserPrompts 预先存储了两轮对话，用户输入了第一轮会话的问题，此时 ` SystemMessages + UserPrompts + 第一轮会话问题`总长度不超过 8k。


**Tools ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
声明一组可供模型在 Function Calling 功能中调用的工具。目前仅支持函数作为工具。功能详细使用方法，请参见 [Function Calling](https://www.volcengine.com/docs/6348/1554654)。
:::warning

* 模型需支持 Function Calling。支持的方舟模型，请参见[模型列表-工具调用](https://www.volcengine.com/docs/82379/1330310?#f44ceef7)。
* Function calling 功能不支持和联网插件或知识库插件同时使用。
* 请确保您已在业务代码中实现了具体的函数逻辑。Function Calling 的作用是让模型 “决策” 调用哪个函数并传入什么参数，而函数的执行则由您的代码负责。例如，想实现天气查询，您需要自己实现一个能查询并返回天气信息的函数。


:::
**type ** <span data-label="purple">String</span> %%require%%示例值：`function`
工具类型。目前固定取值 `function`，表示函数调用。


**function ** <span data-label="purple">Object</span> %%require%%示例值：`-`
模型可以调用的函数列表。

**name ** <span data-label="purple">String</span> %%require%%示例值：`get_current_weather`
函数的名称。
建议使用清晰、能体现函数作用的英文名。如 `get_current_weather`，而不是 `tool_1` 或 `my_func`。


**description ** <span data-label="purple">String</span> `可选` 示例值：`获取指定城市的天气信息`
函数用途的描述。
大模型会参考该字段来选择是否使用该函数。建议用一句话清晰概述参数的用途、格式要求，并提供示例。


**parameters ** <span data-label="purple">JSONMap</span> `可选` 示例值：`-`
函数的请求参数。大模型会参考该字段来提取函数的入参；如果函数不需要输入参数，则无需指定 `parameters` 参数。
该字段必须遵循  [JSON Schema](https://json-schema.org/understanding-json-schema) 格式，其核心结构如下：

* `type`：必须是 "object"。
* `properties`：列出支持的所有参数名及其类型。
   * `参数名`：须为英文字符串，且不能重复。
   * `type`：需遵循 [JSON 规范](https://json-schema.org/docs)，支持类型包括 string、number、boolean、integer、object、array。
   * `description`：对参数的清晰描述。引导模型正确提取值，建议包含用途和格式示例。
* `required`：指定函数中必填的参数名，未在此列出的参数则被视为可选。

示例：
```JSON
{
  "type": "object",
  "properties": {
    "location": {
      "type": "string",
      "description": "需要查询天气的城市名，例如：'北京市'"
    },
    "date": {
      "type": "string",
      "description": "查询的日期，格式应为 YYYY-MM-DD。如果省略，则表示查询当天天气。"
    }
  },
  "required": ["location"]
}
```





**EnableParallelToolCalls ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
单次请求，是否允许模型的返回包含多个待调用的工具。

* `true`（默认值）：允许返回多个待调用的工具。
* `false`：模型最多返回一个待调用的工具。

:::warning
该功能仅 `doubao-seed-1.6`系列模型支持。

:::

**Prefill ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否将 ASR 中间结果提前送入 LLM 进行文本推理， 以降低延时。

* `true`：开启。
* `false`（默认值）：关闭。等待 ASR 判断用户发言结束后，才将用户完整发言文本提交给 LLM 进行推理。

:::warning

* 开启后会产生额外模型消耗。
* LLM 生成的文本，其是否实时送入 TTS 由 `TTSConfig.Prefill`参数控制，默认送入。

:::

**VisionConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
视觉理解能力配置。[如何使用视觉理解能力？](https://www.volcengine.com/docs/6348/1408245)
:::warning

* 该功能仅在使用视觉理解模型时生效。
* 启用端到端语音模型时（S2SConfig）后，该配置不生效。


:::
**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启视觉理解功能。

* `false`：不开启。
* `true`：开启。

默认值为 `false`。


**SnapshotConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
抽帧截图配置。系统会按照配置策略在后台自动抽帧截图送入大模型以供理解。

**StreamType ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
截图流类型。

* `0`：主流。指来自摄像头的实时视频画面。
* `1`：屏幕共享流。指用户共享的设备屏幕内容（如桌面、应用窗口、PPT 等）。

默认值为 `0`。


**ImageDetail ** <span data-label="purple">String</span> `可选` 示例值：`auto`
图片处理模式。取值及含义如下：

* `high`：高细节模式。适用于需要理解图像细节信息的场景，如对图像的多个局部信息/特征提取、复杂/丰富细节的图像理解等场景，理解更全面。
* `low`：低细节模式。适用于简单的图像分类/识别、整体内容理解/描述等场景，理解更快速。
* `auto`：自动模式。根据图片分辨率，自动选择适合的模式。

默认值为 `auto`。


**Height ** <span data-label="purple">Integer</span> `可选` 示例值：`640`
送入大模型截图视频帧高度，取值范围为 `[0, 1792]`，单位为像素。
不填或传 `0` 时自动修改为 `360`。
传入大模型截图视频帧宽度自动按传入高度进行比例计算。


**Interval ** <span data-label="purple">Integer</span> `可选` 示例值：`1000`
相邻截图之间的间隔时间，取值范围为 `[100, 5000]`，单位为毫秒。默认值为 `1000`。


**ImagesLimit ** <span data-label="purple">Integer</span> `可选` 示例值：`2`
单次送大模型截图数。取值范围为 `[0, 50]`。
不传或传 `0` 时自动修改为 `2`。


**AutoSelect ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否启用自动选帧。
启用后，系统会自动输入的视频中选取质量较高的帧送入 LLM，解决因移动抖动或失焦导致的识别不准问题。

* `true`：启用。
* `false`（默认值）：关闭。

:::warning
启用后，截图间隔 `Interval` 固定为 166ms（每秒采样 6 张图片），用户自定义的 `Interval`会失效。

:::


**StorageConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
截图存储相关配置。

**Type ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
存储位置。

* `0`（默认值）：按照 Base 64 编码存入服务端缓存，会话结束后自动删除。
* `1`：存储至 TOS 平台。


**TosConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
TOS 存储配置。
:::warning
配置 TOS 存储前，请先完成以下操作：

1. 开通[火山引擎 TOS 服务](https://console.volcengine.com/tos)，创建存储桶。
2. 为 RTC 服务进行 [TOS 跨服务授权](https://console.volcengine.com/iam/service/attach_role/?ServiceName=rtc)。


:::
**AccountId ** <span data-label="purple">String</span> `可选` 示例值：`account_id`
火山引擎平台账号 ID，例如：`20****00`。查看路径参看[查看和管理账号信息](https://www.volcengine.com/docs/6261/64929)。
:::warning

* 此账号 ID 为火山引擎主账号 ID。
* 若你调用 OpenAPI 鉴权过程中使用的 AK、SK 为子用户 AK、SK，账号 ID 也必须为火山引擎主账号 ID，不能使用子用户账号 ID。

:::

**Region ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
存储桶区域。不同存储桶区域对应的 Region 不同，具体参看 [Region对照表](https://www.volcengine.com/docs/6348/1167931#region)。
默认值为 `0`。
:::warning
该字段填入的存储桶区域需要与你在 TOS 平台创建存储桶时选择的区域相同。

:::

**Bucket ** <span data-label="purple">String</span> `可选` 示例值：`bucket`
c前往 [TOS 控制台](https://console.volcengine.com/tos/bucket?)创建或查询。





**ThinkingType ** <span data-label="purple">String</span> `可选` 示例值：`disabled`
关闭或开启大模型的深度思考能力。若你使用的是具备深度思考能力的模型，强烈建议通过该字段关闭模型的深度思考能力（`disabled`），以避免 AI 回复耗时过长，影响对话的流畅性。
可取值及含义如下：

* `disabled`（**推荐**）：关闭深度思考能力。
* `enabled`：开启深度思考能力。开启后，会增加推理时延迟，且思考内容会丢失，也不会被输出。
* `auto`：模型自行判断是否需要开启深度思考能力（比如根据对话复杂度判断）。
* `null`（**默认值**）：采用模型自身的默认行为。`null` 是一个关键字，在构建 JSON 请求传入时无需引号。示例：`{"ThinkingType": null}`。

:::warning
`ThinkingType` 字段及 `auto` 取值仅部分深度思考能力的模型支持。支持的模型，请参见[关闭深度思考模型](https://www.volcengine.com/docs/82379/1449737#fa3f44fa)。

:::

**MCP ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
配置 MCP，用于接入知识库等外部工具服务。详细配置说明，请参见[接入 MCP](./1856160)。
:::warning

* 模型要求：
   * 火山方舟模型需支持 Function calling。具体支持的模型，请参见 [模型列表-工具调用](https://www.volcengine.com/docs/82379/1330310?#f44ceef7)。
   * 不建议使用 `doubao-seed-1.6-thinking`，该模型会强制开启思考模式，且不可关闭，可能造成较高时延。
* MCP Server 返回必须必须支持流式 SSE 协议。


:::
**URL ** <span data-label="purple">String</span> %%require%%示例值：`https://knowledge-mcp-server.com/test/123`
远端 MCP Server 的访问地址。
> 火山引擎提供了一些常用的 MCP 工具，你可以直接使用。具体使用方法，请参见 [MCP MarketPlace](https://www.volcengine.com/mcp-marketplace)。


**ComfortWords ** <span data-label="purple">String</span> `可选` 示例值：`正在处理中...`
当调用 MCP 工具时，向用户播放的安抚语内容。


**InterestedTools ** <span data-label="purple">String[]</span> `可选` 示例值：`["search_knowledge"]`
指定要添加到 LLM 上下文中的工具列表，以供 LLM 决策和调用。

* 若为空或不传：MCP Server 提供的所有工具都将被添加到 LLM 上下文中。
* 若指定了工具：则仅将指定的工具添加到 LLM 上下文中。


**Name ** <span data-label="purple">String</span> %%require%%示例值：`knowledge`
自定义一个唯一的名称，用于标识该 MCP 服务。
该名称供 LLM 区分工具来源，且系统会根据该名称将工具调用请求路由至对应的 MCP Server。
:::warning
该名称不能与联网问答 Agent（`WebSearchAgentConfig.FunctionName`）和 Function Calling（`Tools.function.name`）里定义的工具重名。

:::



<span id="cozellmconfig"></span>
#### Coze智能体 <span data-label="purple">Object</span> 示例值：`-`
:::warning
使用前须知：

* 请确保 Coze 智能体已发布为 API 服务。详情参考[准备工作](https://www.coze.cn/open/docs/developer_guides/preparation)。
* 使用 Coze 智能体时不支持视觉理解、Function Calling 和端插件能力。


:::
**Mode ** <span data-label="purple">String</span> %%require%%示例值：`CozeBot`
大模型平台名称。该参数固定取值：`CozeBot`。


**CozeBotConfig ** <span data-label="purple">Object</span> %%require%%示例值：`-`
Coze 智能体配置。

**Url ** <span data-label="purple">String</span> %%require%%示例值：`https://api.coze.cn`
请求地址。该参数固定取值：`https://api.coze.cn`


**BotId ** <span data-label="purple">String</span> %%require%%示例值：`73****68`
Coze 智能体 ID。
可前往你需要调用的智能体开发页面获取。开发页面 URL 中 bot 参数后的数字即智能体ID。例如开发页面 URL 为：`https://www.coze.cn/space/341/bot/73****68`，则 `BotId` 为 `73****68`。


**APIKey ** <span data-label="purple">String</span> %%require%%示例值：`czu_UEE*****CVv9uQ7H`
Coze 访问密钥，用于 API 调用时的身份认证。支持传入两种类型的密钥：

* **个人访问令牌**：用于快速测试。您可以在 Coze 平台的 [个人访问令牌](https://www.coze.cn/open/oauth/pats) 页面生成。
* **OAuth 访问令牌**：推荐用于生产环境。根据 Coze 的 [OAuth 授权码授权](https://www.coze.cn/open/docs/developer_guides/oauth_code) 获取  access_token，并将其填入此字段。

:::warning

* **令牌有效期**：个人访问令牌和 OAuth 访问令牌均有有效期。在生产环境中，您的业务服务端需要自行管理 OAuth 令牌的刷新逻辑，确保在调用本接口时传入有效的令牌。
* **权限范围**：创建个人访问令牌或 OAuth 应用时，您需要根据 Bot 使用的插件和工作流勾选相应权限，否则会因鉴权失败导致调用不通。

:::

**UserId ** <span data-label="purple">String</span> %%require%%示例值：`123`
标识当前与智能体对话的用户，由你自行定义、生成与维护。`UserId` 用于标识对话中的不同用户，不同的 `UserId`，其对话的上下文消息、数据库等对话记忆数据互相隔离。如果不需要用户数据隔离，可将此参数固定为一个任意字符串，例如 `123`、`abc` 等。


**HistoryLength ** <span data-label="purple">Integer</span> `可选` 示例值：`3`
历史问题轮数。默认值为 `3`。
在调用该接口时需要确保作为上下文的用户消息和 AI 消息文本总长度小于模型上下文长度。
例如：历史问题轮数为 3，使用 `Skylark2-lite-8k`大模型，该模型上下文长度限制为 8k，询问第 10 个问题时，需保证第 10 个问题的长度与第八、九轮用户消息和 AI 消息文本的总长度之和不得超过 8k。


**Prefill ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否将 ASR 中间结果提前送入 LLM 进行文本推理， 以降低延时。

* `true`：开启。
* `false`（默认值）：关闭。等待 ASR 判断用户发言结束后，才将用户完整发言文本提交给 LLM 进行推理。

:::warning

* 开启后会产生额外模型消耗。
* LLM 生成的文本，其是否实时送入 TTS 由 `TTSConfig.Prefill`参数控制，默认送入。

:::

**EnableConversation ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否将上下文存储在 Coze 平台。
若需要使用 Coze 平台上下文管理相关功能，如将指定内容添加到会话中，可开启此功能。功能开启后 RTC 不再存储上下文内容。

* `false`：不开启。
* `true`：开启。

默认值为 `false`。
:::warning
EnableConversation 为 true 时会导致 `HistoryLength`设置无效。

:::

**CustomVariables ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"custom_var_1": "value1"}`
为 Coze 智能体 Prompt 中定义的变量 {{key}} 动态赋值。Map<String, String\> 格式，支持 Jinja2 语法。
> 对应 Coze [Chat API](https://www.coze.cn/open/docs/developer_guides/chat_v3) 中的 `custom_variables` 字段。详细使用说明可参考[变量示例](https://www.coze.cn/open/docs/developer_guides/chat_v3#6917d529)。

:::tip

* 仅作用于智能体提示词中的变量，不会传递给智能体的变量或工作流。
* 变量名只支持英文字母和下划线。

:::

**MetaData ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"order_id": "xyz-123"}`
为对话附加信息，比如业务标识（如订单号、用户来源等），方便后续数据查询和分析。
[查看对话详情](https://www.coze.cn/open/docs/developer_guides/retrieve_chat)时，扣子会透传此附加信息，[查看消息列表](https://www.coze.cn/open/docs/developer_guides/list_message)时不会返回该附加信息。
**格式要求**：自定义键值对。长度为 16 对键值对，其中键（key）的长度范围为 1～64 个字符，值（value）的长度范围为 1～512 个字符。
> 对应 Coze [Chat API](https://www.coze.cn/open/docs/developer_guides/chat_v3) 中的 `meta_data` 字段。


**Parameters ** <span data-label="purple">JSONMap</span> `可选` 示例值：`-`
为 Coze 对话流起始节点中定义的自定义参数赋值，Map<String, Any\> 格式。
> 对应 Coze [Chat API](https://www.coze.cn/open/docs/developer_guides/chat_v3) 中的 `parameters` 字段，详细使用说明可参见[自定义用户变量](https://www.coze.cn/open/docs/developer_guides/chat_v3#ec9c5fb2)。

:::warning
仅支持为已发布 API、ChatSDK 的单 Agent（对话流模式）的智能体设置该参数。

:::

**ResponseTimeout ** <span data-label="purple">Integer</span> `可选` 示例值：`10`
Coze 智能体回复超时时间。如果在设定的时间内未能收到智能体回复，系统会自动取消本次回复。单位为秒，取值范围 [0, 60]，默认为 10s。
> 如果您的 Coze 智能体内部配置了复杂流程（如 MCP、插件调用、工作流执行），其响应时间可能会变长。此参数用于设定一个合理的等待上限，避免因智能体长时间无响应而影响用户体验。




<span id="thirdpartyllmconfig"></span>
#### 第三方大模型/Agent <span data-label="purple">Object</span> 示例值：`-`

**Mode ** <span data-label="purple">String</span> %%require%%示例值：`CustomLLM`
大模型平台名称。使用第三方大模型/Agent 时，该参数固定取值：`CustomLLM`。


**Url ** <span data-label="purple">String</span> %%require%%示例值：`https://test.com/path/to/app`
第三方大模型/Agent 的请求 URL，需要使用 HTTPS 域名，且必须符合[火山引擎标准](https://www.volcengine.com/docs/6348/1399966#cae507df)。
> 系统请求该 URL 的超时时间为 10 秒，请确保您的服务能在此时间内响应。


* **快速验证 URL 是否符合标准**：
   1. 前往 [实时对话式 AI 体验馆](https://demo.volcvideo.com/aigc) ，开始通话。
   2. 点击右侧的 **修改 AI 人设**，然后切换至**第三方模型**，并填入 URL 进行快速验证。
   若验证失败可前往文档[接入第三方大模型/Agent](https://www.volcengine.com/docs/6348/1399966)，查看接口标准并通过验证工具查看详细报错。
* **拼接参数**：如果需要在每次请求时传递一些简单的、非敏感的参数（如 session_id），可以直接将它们作为查询参数拼接到此 URL 中。
* **如需使用 HTTP 域名进行测试**：可在下方 `Feature` 参数中填入 `{"Http":true}`，但无法保证服务质量。


**ModelName ** <span data-label="purple">String</span> `可选` 示例值：`name1`
第三方大模型/Agent 的名称。


**APIKey ** <span data-label="purple">String</span> `可选` 示例值：`pat*****123231`
Bearer Token 认证方式的大模型鉴权 Token。


**MaxTokens ** <span data-label="purple">Integer</span> `可选` 示例值：`1024`
输出文本的最大 token 限制。默认值为 `1024`。


**Temperature ** <span data-label="purple">Float</span> `可选` 示例值：`0.1`
采样温度，用于控制生成文本的随机性和创造性，值越大随机性越高。取值范围为 `(0, 1]`，默认值为 `0.1`。


**TopP ** <span data-label="purple">Float</span> `可选` 示例值：`0.3`
采样的选择范围，控制输出 token 的多样性。模型将从概率分布中累计概率超过该取值的标记中进行采样，以确保采样的选择范围不会过宽，值越大输出的 token 类型越丰富。
取值范围为 `[0, 1]`，默认值为 `0.3`。


**SystemMessages ** <span data-label="purple">String[]</span> `可选` 示例值：`["你是小宁，性格幽默又善解人意。你在表达时需简明扼要，有自己的观点。"]`
系统提示词。用于输入控制大模型行为方式的指令，定义了模型的角色、行为准则，特定的输出格式等。


**UserPrompts ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
用户提示词。可用于增强模型的回复质量，模型回复时会优先参考此处内容，引导模型生成特定的输出或执行特定的任务。
:::warning
`UserPrompts` 设有自动逐出机制：当对话总数超过 `HistoryLength` 限制时，最早的 `UserPrompts` 会被自动逐出，为新的对话历史腾出空间。
示例：若 `HistoryLength`设置为 3 且已预存 2 轮对话。在用户与 AI 完成第 1 轮真实对话后，上下文总轮数为 3（2 预存 + 1 用户），此时无需逐出；当用户发起第 2 轮对话时，总轮数变为 4 超过限制，系统会自动移除最早的一轮预存内容，使上下文始终只保留最近的 3 轮记录。

:::
**Role ** <span data-label="purple">String</span> `可选` 示例值：`user`
发送消息的角色。支持取值 system、user 和 assistant。其中 user 和 assistant 必须成对出现（一问一答），否则大模型可能会出现未定义行为。


**Content ** <span data-label="purple">String</span> `可选` 示例值：`你是谁？`
消息内容。



**HistoryLength ** <span data-label="purple">Integer</span> `可选` 示例值：`3`
对话上下文保留轮数。默认值为 `3`。AI 在回复时会参考最近 N 轮的历史对话，以保证多轮对话的连贯性。
:::warning
需确保发送给大模型的总 Token 数不超过模型的上下文上限（如 8k）。即 **SystemMessages + 当前生效的 UserPrompts + HistoryLength 轮对话  <  模型最大上下文长度**。
:::
例如：历史问题轮数为 3，LLM 上下文限制为 8k，UserPrompts 预先存储了两轮对话，用户输入了第一轮会话的问题，此时  **SystemMessages + UserPrompts + 第一轮会话问题**总长度不超过 8k。


**Tools ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
声明一组可供模型在 Function Calling 功能中调用的工具，目前仅支持函数作为工具。功能详细使用方法，请参见 [Function Calling](https://www.volcengine.com/docs/6348/1554654)。
:::warning

* 请确保您的第三方模型支持 Function Calling 功能。
* 请确保您已在业务代码中实现了具体的函数逻辑。Function Calling 的作用是让模型 “决策” 调用哪个函数并传入什么参数，而函数的执行则由您的代码负责。例如，想实现天气查询，您需要自己实现一个能查询并返回天气信息的函数。


:::
**type ** <span data-label="purple">String</span> %%require%%示例值：`function`
工具类型。目前固定取值 `function`，表示函数调用。


**function ** <span data-label="purple">Object</span> %%require%%示例值：`-`
模型可以调用的函数列表。

**name ** <span data-label="purple">String</span> %%require%%示例值：`get_current_weather`
函数的名称。
建议使用清晰、能体现函数作用的英文名。如 `get_current_weather`，而不是 `tool_1` 或 `my_func`。


**description ** <span data-label="purple">String</span> `可选` 示例值：`获取指定城市的天气信息`
函数用途的描述。
大模型会参考该字段来选择是否使用该函数。建议用一句话清晰概述参数的用途、格式要求，并提供示例。


**parameters ** <span data-label="purple">JSONMap</span> `可选` 示例值：`-`
函数的请求参数。大模型会参考该字段来提取函数的入参；如果函数不需要输入参数，则无需指定 `parameters` 参数。
该字段必须遵循  [JSON Schema](https://json-schema.org/understanding-json-schema) 格式，其核心结构如下：

* `type`：必须是 "object"。
* `properties`：列出支持的所有参数名及其类型。
   * `参数名`：须为英文字符串，且不能重复。
   * `type`：需遵循 [JSON 规范](https://json-schema.org/docs)，支持类型包括 string、number、boolean、integer、object、array。
   * `description`：对参数的清晰描述。引导模型正确提取值，建议包含用途和格式示例。
* `required`：指定函数中必填的参数名，未在此列出的参数则被视为可选。

示例：
```JSON
{
  "type": "object",
  "properties": {
    "location": {
      "type": "string",
      "description": "需要查询天气的城市名，例如：'北京市'"
    },
    "date": {
      "type": "string",
      "description": "查询的日期，格式应为 YYYY-MM-DD。如果省略，则表示查询当天天气。"
    }
  },
  "required": ["location"]
}
```





**EnableParallelToolCalls ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
单次请求，是否允许模型的返回包含多个待调用的工具。

* `true`（默认值）：允许返回多个待调用的工具。
* `false`：模型最多返回一个待调用的工具。


**MCP ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
配置 MCP，用于接入知识库等外部工具服务。详细配置说明，请参见[接入 MCP](./1856160)。
:::warning

* MCP Server 返回必须支持流式 SSE 协议。
* 如果你的 MCP Server 配置了自定义请求头（如 Authorization），则必须将请求头信息配置在 `LLMConfig.ExtraHeader`字段中。系统会将这些 Headers 随请求一同转发至你的 MCP Server。


:::
**URL ** <span data-label="purple">String</span> %%require%%示例值：`https://knowledge-mcp-server.com/test/123`
远端 MCP Server 的访问地址。
> 火山引擎提供了一些常用的 MCP 工具，你可以直接使用。具体使用方法，请参见 [MCP MarketPlace](https://www.volcengine.com/mcp-marketplace)。


**ComfortWords ** <span data-label="purple">String</span> `可选` 示例值：`正在处理中...`
当调用 MCP 工具时，向用户播放的安抚语内容。默认为空。


**InterestedTools ** <span data-label="purple">String[]</span> `可选` 示例值：`["search_knowledge"]`
指定要添加到 LLM 上下文中的工具列表，以供 LLM 决策和调用。

* 若为空或不传：MCP Server 提供的所有工具都将被添加到 LLM 上下文中。
* 若指定了工具：则仅将指定的工具添加到 LLM 上下文中。


**Name ** <span data-label="purple">String</span> %%require%%示例值：`knowledge`
自定义一个唯一的名称，用于标识该 MCP 服务。
该名称供 LLM 区分工具来源，且系统会根据该名称将工具调用请求路由至对应的 MCP Server。
:::warning
该名称不能与联网问答 Agent（`WebSearchAgentConfig.FunctionName`）和 Function Calling（`Tools.function.name`）里定义的工具重名。

:::


**Feature ** <span data-label="purple">String</span> `可选` 示例值：`{\"Http\":true}`
使用 HTTP 域名进行测试，该参数固定取值：`{\"Http\":true}`。


**Prefill ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
将 ASR 中间结果提前送入大模型进行处理：

* `true`：开启。将 ASR 识别中间结果提前送入大模型进行处理，以降低延时。
* `false`：关闭。需等待 ASR 模块识别出完整的一句话后，再将其整体送入大模型处理。

默认值为 `false`。
:::warning
开启后会产生额外模型消耗。

:::

**VisionConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
视觉理解能力配置。支持理解 RTC 实时视频流或外部图片。[如何使用视觉理解能力？](./1408245)

**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启视觉理解功能。

* `false`：不开启。
* `true`：开启。

默认值为 `false`。


**SnapshotConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
抽帧截图配置。系统会按照配置策略在后台自动抽帧截图送入大模型以供理解。

**StreamType ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
截图流类型。

* `0`：主流。指来自摄像头的实时视频画面。
* `1`：屏幕共享流。指用户共享的设备屏幕内容（如桌面、应用窗口、PPT 等）。

默认值为 `0`。


**ImageDetail ** <span data-label="purple">String</span> `可选` 示例值：`auto`
图片处理模式。取值及含义如下：

* `high`：高细节模式。适用于需要理解图像细节信息的场景，如对图像的多个局部信息/特征提取、复杂/丰富细节的图像理解等场景，理解更全面。
* `low`：低细节模式。适用于简单的图像分类/识别、整体内容理解/描述等场景，理解更快速。
* `auto`：自动模式。根据图片分辨率，自动选择适合的模式。

默认值为 `auto`。


**Height ** <span data-label="purple">Integer</span> `可选` 示例值：`640`
送入大模型的截图视频帧高度，取值范围为 `[0, 1792]`，单位为像素。
不填或传 `0` 时自动修改为 `360`。
传入大模型视频帧宽度自动按传入高度计算。


**Interval ** <span data-label="purple">Integer</span> `可选` 示例值：`1000`
相邻截图之间的间隔时间，取值范围为 `[100, 5000]`，单位为毫秒。默认值为 `1000`。


**ImagesLimit ** <span data-label="purple">Integer</span> `可选` 示例值：`2`
单次送大模型图片数。取值范围为 `[0, 50]`。
不传或传 `0` 时自动修改为 `2`。


**AutoSelect ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否启用自动选帧。
启用后，系统会自动输入的视频中选取质量较高的帧送入 LLM，解决因移动抖动或失焦导致的识别不准问题。

* `true`：启用。
* `false`（默认值）：关闭。

:::warning
启用后，截图间隔 `Interval` 固定为 166ms（每秒采样 6 张图片），用户自定义的 `Interval`会失效。

:::


**StorageConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
截图存储相关配置。
**Type ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
存储类型。

* `0`（默认值）：Base 64 编码存入本地，会话结束后自动删除。
* `1`：TOS。使用 TOS 存储前需前往 [TOS 控制台](https://console.volcengine.com/tos/?)开通该服务。


**TosConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
TOS 存储配置。
&nbsp;

**AccountId ** <span data-label="purple">String</span> `可选` 示例值：`account_id`
火山引擎平台账号 ID，例如：`200000000`。

* 火山引擎平台账号 ID 查看路径参看[查看和管理账号信息](https://www.volcengine.com/docs/6261/64929)。
* 此账号 ID 为火山引擎主账号 ID。
* 若你调用 OpenAPI 鉴权过程中使用的 AK、SK 为子用户 AK、SK，账号 ID 也必须为火山引擎主账号 ID，不能使用子用户账号 ID。


**Region ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
不同存储平台支持的 Region 不同，具体参看 [Region对照表](https://www.volcengine.com/docs/6348/1167931#region)。
默认值为 `0`。


**Bucket ** <span data-label="purple">String</span> `可选` 示例值：`bucket`
存储桶名称。前往 [TOS 控制台](https://console.volcengine.com/tos/bucket?)创建或查询。





**EnableRoundId ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
请求第三方模型/Agent 接口时，是否在请求体中携带字段 `round_id`（对话轮次 ID）：

* `false`（默认值）：不携带。
* `true`：携带。系统会在发送给你自研接口的 Request Body 中，自动添加一个 `round_id` 字段。你可以解析该字段，用于日志追踪、问题排查和数据审计等。

> round_id 是系统为每一轮“用户\-AI”的交互生成的唯一标识。


**Custom ** <span data-label="purple">String</span> `可选` 示例值：`-`
自定义 JSON 字符串，可传入业务自定义参数。默认为空。


**ExtraHeader ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"custom_header": "value"}`
自定义透传 Header。一个 JSON 对象，其键值对将作为额外的 HTTP Header 字段，透传到你的自定义模型服务请求中，可用于鉴权或其他自定义逻辑。默认为空。




**SubtitleConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
获取实时字幕（对话记录）。
在与 AI 对话过程中，系统会自动生成用户和 AI 的对话文本。您可以通过客户端或服务端实时获取该数据，用于实时展示或存储分析。详细说明，参见[实时字幕（对话记录）](https://www.volcengine.com/docs/6348/1337284)。

**DisableRTSSubtitle ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否关闭房间内客户端字幕回调。

* `true`：不通过客户端接收字幕消息。
* `false`（默认值）：通过客户端接收字幕消息。开启后，还需在客户端实现监听 [onRoomBinaryMessageReceived](https://www.volcengine.com/docs/6348/70081#IRTCRoomEventHandler-onroombinarymessagereceived)（以 Android 为例），并解析字幕。

:::warning
如需通过服务端接收字幕回调，请配置 `AgentConfig.ServerMessageUrlForRTS` 和 `AgentConfig.ServerMessageSignatureForRTS`。

:::

**SubtitleMode ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
字幕回调时是否需要对齐音频时间戳。

* `0`（默认值）：对齐音频时间戳。
* `1`：不对齐音频时间戳。取 `1` 时可更快回调字幕信息。

:::warning

* 使用`数字人服务`、`豆包语音端到端实时语音大模型` 后，该字段必须取值为 `1`，取值为 `0` 时字幕不生效。
* 使用语音合成大模型 2.0 或声音复刻大模型 2.0 时，若需设置 `SubtitleMode: 0`（对齐音频时间戳），必须关闭 `enable_latex_tn`（播报 LaTeX 公式）功能。
* 当 `SubtitleMode` 为1时，字幕收到下面中斜体`{"definite": true, "paragraph": true, "roundId": 4, "text": ""}`是符合预期的。

:::


**FunctionCallingConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
通过业务服务器接收 Function calling 调用通知和调用指令消息。详细配置说明，请参见[函数调用 Function Calling](https://www.volcengine.com/docs/6348/1554654)。
> 当您配置了 `LLMConfig.Tools` 后，当 LLM 识别到工具调用意图时，会下发 FC 调用通知和调用指令消息。默认情况下指令可由客户端接收处理；如果您希望在后端服务器上接收并处理这些指令则必须配置此项。


**ServerMessageUrl ** <span data-label="purple">String</span> %%require%%示例值：`https://example-domain8080/m2`
您的业务服务器地址（URL），用于接收  Function calling 调用通知和调用指令消息。

* URL 地址要求：
   * 必须为公网可访问的域名地址。若使用 HTTPS，请确保 SSL 证书合法且完整。
   * 请确保该 URL 指向的服务端能够正常处理无 Content\-Type 的 POST 请求。
* 消息接收和解析说明：参见[服务端实现 Function Calling 功能](https://www.volcengine.com/docs/6348/1554654#.5pyN5Yqh56uv5a6e546w)。

:::tip
您可以使用以下命令快速校验回调地址是否满足要求：`curl -v -X POST <url>`。

* 若返回 301 或 302：说明 URL 地址不可用。此时 POST 请求会被降级为 GET 请求，导致数据丢失。该问题通常是由于填写的 HTTP 地址发生了跳转（如强制跳转至 HTTPS），建议直接配置最终跳转后的 HTTPS 地址。
* 若返回 307 或 308：说明 URL 地址可用。虽然发生了重定向，但机制允许保持 POST 方法和请求体，回调可正常接收。

:::

**ServerMessageSignature ** <span data-label="purple">String</span> %%require%%示例值：`TestSignature`
签名密钥。用于验证回调请求的真实性，由您自定义。
当平台向您的 `ServerMessageUrl ` 发送回调请求时，会在请求体返回 `signature` 字段，其值为您配置的密钥。您的服务端必须校验收到的 `signature`  的值是否与您预设的密钥一致，以确保请求来源可靠。



**InterruptMode ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
是否启用语音打断（发声即打断）：

* `0`：开启。开启后，一旦检测到用户发出声音， AI 立刻停止输出。
* `1`：关闭。关闭后， AI 说话期间，用户语音输入内容会被忽略不做处理，不会打断 AI 讲话。

默认值为 `0`。


**AvatarConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
配置数字人。仅支持接入火山引擎数字人。

**Enabled ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否启用火山引擎数字人。

* `true`：开启。
* `false`（默认值）：不开启。

:::warning
若需开启，请确保已按照要求准备好数字人资源。详见[开通并准备数字人资源](./1848567#48b7a2ba)。

:::

**AvatarAppID ** <span data-label="purple">String</span> `可选` 示例值：`zt****ubf`
数字人服务 AppID。

> * 当 `Enabled` 为 `true` 时，该字段为必填。
> * 联系技术支持开通直播互动数字人并购买并发后，技术支持会提供该信息。


**AvatarToken ** <span data-label="purple">String</span> `可选` 示例值：`zOpP1FFZ****ZQi9GHn`
数字人服务 Token。

> * 当 `Enabled` 为 `true` 时，该字段为必填。
> * 联系技术支持开通直播互动数字人并购买并发后，技术支持会提供该信息。


**AvatarType ** <span data-label="purple">String</span> `可选` 示例值：`3min`
数字人类型。此参数目前为固定值 `3min`，表示 3min 克隆数字人。
> 当 `Enabled` 为 `true` 时，该字段为必填。


**AvatarRole ** <span data-label="purple">String</span> `可选` 示例值：`250623-****-linyunzhi`
数字人形象唯一 ID。[创建克隆数字人形象](https://www.volcengine.com/docs/85128/1773809)时生成的 `resource_id`，可通过[查询接口](https://www.volcengine.com/docs/85128/1773809?lang=zh#Q3FMrSnj)获取。
> 当 `Enabled` 为 `true` 时，该字段为必填。


**AvatarUserID ** <span data-label="purple">String</span> `可选` 示例值：`BotName01_Avatar`
数字人在房间内的 ID，用于标识数字人。

* **默认值**：`AgentConfig.UserId` + `_Avatar` 。
* **自定义命名规则**：
   * 支持大小写字母（A\-Z、a\-z）、数字（0\-9）、下划线（_）、短横线（\-）、句点（.）和 @ 组成，最大长度为 128 个字符。
   * `AvatarUserID` 的值不能与 `AgentConfig.UserId`（智能体 ID）和 `TargetUserId`（真人用户 ID）相同。
* **关于使用：**
   启用数字人功能后，RTC 房间内会存在三个用户：**真人用户**、**AI 智能体**（系统创建）、**数字人**（系统创建）。为了确保交互逻辑正确，请按以下规则区分使用两个虚拟 ID：
   * 当需要发送控制指令时（如手动打断、更新上下文等），如调用 `sendUserBinaryMessage` 接口发送指令时，目标 `userId` 为 AI 智能体 ID `AgentConfig.UserId`。
   * 当需要处理数字人的画面渲染、流状态回调等时，对应的目标 userId 为数字人 ID ** **  `AvatarUserID`。


**BackgroundUrl ** <span data-label="purple">String</span> `可选` 示例值：`https://tos-tools.tos-cn-beijing.volces.com/misc/sample.png`
数字人背景图 URL。该 URL 需公网可访问，且需要带有图片格式后缀，如 `.png`、`.jpg`。


**VideoBitrate ** <span data-label="purple">Integer</span> `可选` 示例值：`3000`
数字人视频码率，单位为 kbps，取值范围 `[100, 8000]`。
默认值为 `2000`。



**WebSearchAgentConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
联网问答 Agent 配置。
将火山联网问答 Agent 作为内置工具接入（通过 Function calling 机制），让 AI 实时从互联网检索信息并进行总结回答的能力。例如，查询最新资讯、获取天气信息、询问实时股价等。详细配置，请参见[接入联网问答 Agent](https://www.volcengine.com/docs/6348/1856161)。
:::warning

* 仅支持 Function calling 的第三方大模型或火山方舟模型支持该功能。具体支持的方舟模型，请参见 [模型列表-工具调用](https://www.volcengine.com/docs/82379/1330310?#f44ceef7)。
* 不建议使用 `doubao-seed-1.6-thinking`，该模型会强制开启思考模式，且不可关闭，可能造成较高时延。


:::
**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否启用联网问答能力。

* `false`（默认）：不开启。
* `true`：开启。

:::warning
开启前，请确保已[创建一个联网问答 Agent 并正式开通](https://console.volcengine.com/ask-echo/my-agent)。

:::

**APIKey ** <span data-label="purple">String</span> `可选` 示例值：`your_agent_apikey`
联网问答 Agent 服务的 API Key。可在[联网问答 Agent 控制台](https://console.volcengine.com/ask-echo/api-key)创建并获取。
> 仅当 `Enable` 为 `true` 时必填。


**ParamsString ** <span data-label="purple">String</span> `可选` 示例值：`{"bot_id": "742..."}`
透传联网问答 Agent 服务的参数（JSON 字符串）。仅当 `Enable` 为 `true` 时必填。
如何填写：

1. 参考 [联网问答 Agent API 文档](https://www.volcengine.com/docs/85508/1510834)，在请求参数 `ChatCompletionRequest` 中选取所需参数，构建 JSON 字符串。
   * `bot_id`：必选。联网问答 Agent ID。可在[联网问答 Agent 控制台](https://console.volcengine.com/ask-echo/my-agent)获取。
   * `stream`：必选，且必须设置为 `true`。
   * 其他参数：按需选择并配置。
   示例：
   ```JSON
   {
      "bot_id": "7429...747",
      "stream": true
   }
   ```

2. 将JSON 对象转换为 JSON 字符串，如 `{\"bot_id\":\"7429...747\",\"stream\":true}`。


**FunctionName ** <span data-label="purple">String</span> `可选` 示例值：`WebSearch`
自定义名称，用于标识此联网工具，作为 AI 触发联网时调用的函数名。
:::warning

* 仅当 `Enable` 为 `true` 时必填。
* 该名称不能与 Function calling （`Tools.function.name`）和 MCP（`MCP.Name`）里定义的工具重名。

:::

**FunctionDescription ** <span data-label="purple">String</span> `可选` 示例值：`查询实时信息，如今天的天气、最新的新闻、A 股票的当前价格等`
用自然语言描述你希望 AI 在什么情况下触发联网搜索。它会作为 Prompt 的一部分，帮助 LLM 更精准地判断是否需要触发联网搜索。
> 仅当 `Enable` 为 `true`时必填。


**ComfortWords ** <span data-label="purple">String</span> `可选` 示例值：`正在为您联网查询，请稍等...`
安抚语。当触发联网搜索时，会先通过 TTS 播报这段安抚语，提高用户在等待搜索结果时的体验。如果留空，则不播报。
:::warning
安抚语结尾需要带标点符号。

:::

**DisableImageSearch ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否关闭联网图搜功能。

* `false`（默认值）：开启。开启后，当模型启用了视觉理解能力后，触发联网搜索时会携带当前缓存的图片（截图或外部图片）。
* `true`：关闭。联网搜索时仅发送文本，不携带图片。

:::warning
联网图搜仅在模型支持且开启视觉理解能力时生效（`VisionConfig.Enable` 为 `true`）。

:::


**MemoryConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
记忆库配置。通过接入火山记忆库（基于向量数据库 VikingDB），赋予智能体跨会话的长期记忆能力。
:::warning
配置前，请确保你已经创建创建了记忆库并完成授权。具体操作，请参见[接入记忆库（长期记忆）](./1899860)。

:::
**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启记忆库检索。

* `false`（默认值）：不开启。
* `true`：开启。智能体在回复前会先检索记忆库，并将「用户问题 + 过渡语（`transition_words`）+ 所有被采纳的记忆（由字段 `Score` 控制） 」一同作为上下文提供给 LLM。


**Provider ** <span data-label="purple">String</span> `可选` 示例值：`volc`
记忆库服务提供商。当前固定取值为 `volc`，表示火山记忆库。
> 当 `Enable` 为 `true` 时为必填。


**ProviderParams ** <span data-label="purple">Object</span> `可选` 示例值：`-`
记忆库详细配置，用于定义记忆库的检索目标和规则。
> 当 `Enable` 为 `true` 时为必填。


**collection_name ** <span data-label="purple">String</span> `可选` 示例值：`customer_service_memory`
要检索的记忆库名称。需与在火山记忆库控制台中配置的记忆库名称保持一致。记忆库名称支持[在控制台获取](https://console.volcengine.com/vikingdb/region:vikingdb+cn-beijing/home)。
> 当 `Enable` 为 `true` 时为必填。


**filter ** <span data-label="purple">Object</span> `可选` 示例值：`-`
检索过滤条件。用于精确筛选需要召回的记忆。
> 当 `Enable` 为 `true` 时为必填。


**user_id ** <span data-label="purple">String[]</span> `可选` 示例值：`["user1", "user2"]`
用户 ID 列表。用于筛选特定用户的记忆。

> * `user_id` 和 `assistant_id` 至少填写一个。
> * 此字段对应 VikingDB 的 [AddSession](https://www.volcengine.com/docs/84313/1783353) 接口中 `default_user_id` 或 `role_id` 的值。


**assistant_id ** <span data-label="purple">String[]</span> `可选` 示例值：`["agent007"]`
Assistant ID。用于筛选特定智能体产生或参与的记忆。

> * `user_id` 和 `assistant_id` 至少填写一个。
> * 此字段对应 VikingDB 的 [AddSession](https://www.volcengine.com/docs/84313/1783353) 接口中 `default_assistant_id` 或 `role_id` 的值。


**memory_type ** <span data-label="purple">String[]</span> `可选` 示例值：`your_event_type`
记忆抽取规则。当前仅支持事件规则，请填入你在创建记忆库时定义的**事件规则名称**。

> * 当 `Enable` 为 `true` 时为必填。
> * 事件规则名称可[在控制台获取](https://console.volcengine.com/vikingdb/region:vikingdb+cn-beijing/home)，或通过 API [CollectionInfo](https://www.volcengine.com/docs/84313/1783349) 获取。


**group_id ** <span data-label="purple">String[]</span> `可选` 示例值：`group_A`
群组 ID。支持传入单个或多个群组 ID。
> 此字段对应 VikingDB 的 [AddSession](https://www.volcengine.com/docs/84313/1783353) 接口中 `group_id` 的值。


**session_id ** <span data-label="purple">String[]</span> `可选` 示例值：`session_123`
会话 ID。支持传入单个或多个会话 ID。
> 此字段对应 VikingDB 的 [AddSession](https://www.volcengine.com/docs/84313/1783353) 接口中 `session_id` 的值。


**start_time ** <span data-label="purple">Integer</span> `可选` 示例值：`672502400000`
检索记忆的起始时间（毫秒级 Unix 时间戳）。


**end_time ** <span data-label="purple">Integer</span> `可选` 示例值：`1675180800000`
检索记忆的终止时间（毫秒级 Unix 时间戳）。



**limit ** <span data-label="purple">Integer</span> `可选` 示例值：`10`
指定单次召回记忆的最大条数。默认为 10，取值范围 [1, 5000]。


**transition_words ** <span data-label="purple">String</span> `可选` 示例值：`查询到的记忆内容如下：`
过渡语。 此文本会插入到用户问题和召回的记忆内容之间，作为上下文一同发送给大模型，用于引导 LLM 理解和组织回复。例如：`“小明对比赛结果有什么判断？（**查询到的记忆内容是**：********）”`。



**Score ** <span data-label="purple">Float</span> `可选` 示例值：`0.7`
召回的记忆的置信度阈值，可用于过滤与当前问题相关性较低的记忆，从而提升回复精准性。
一次检索可能召回多条记忆（由 `limit` 参数控制）。系统会为每条记忆计算一个“相关性得分”，只有得分不低于设定阈值的记忆会被采纳；低于设定阈值的记忆会被丢弃。

* **取值范围**：`[0.0, 1.0]`。
* **默认值**：`0`，表示不过滤，所有召回的记忆都会被作为上下文。



**S2SConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
端到端语音模型配置。
相较于 ASR+LLM+TTS 方案，端到端模型可直接完成语音输入输出，降低模块间的处理与传输延迟，从而提供更流畅、更自然的对话体验。
:::warning

* 目前仅支持接入豆包端到端实时语音大模型。在使用前，您需要先在[豆包语音控制台](https://console.volcengine.com/speech/service/10017)开通“豆包端到端实时语音大模型”服务并获取 appid 和 token。
* 如果配置了 `S2SConfig`，`ASRConfig` 和 `TTSConfig` 失效；通过服务端 API  `UpdateVoiceChat` 或 客户端 API `sendUserBinaryMessage`发送的 ExternalPromptsForLLM 和 ExternalTextToLLM 指令不生效。


:::
**Provider ** <span data-label="purple">String</span> %%require%%示例值：`volcano`
端到端语音模型服务提供商。
当前仅支持取值 `volcano`，表示豆包端到端实时语音大模型。


**OutputMode ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
输出模式：

* `0`（默认值）：纯端到端模式。对话仅由端到端模型处理，不经过 LLMConfig 中的大模型。此模式延迟最低，适用于纯闲聊场景。
* `1`：混合编排模式（端到端模型+LLM）。用户语音会同时发送给端到端模型和在 LLMConfig 配置的模型。系统根据 LLMConfig 是否触发函数调用（Function Calling）来决定输出：若触发函数调用，则采用 LLMConfig 的输出；否则采用端到端模型的输出。

:::warning
采用混合编排模式时，`LLMConfig`仅支持使用火山方舟大模型，且不支持视频和图片理解。

:::

**ProviderParams ** <span data-label="purple">Object</span> %%require%%示例值：`-`
语音端到端模型的详细配置。

**app ** <span data-label="purple">Object</span> %%require%%示例值：`-`
应用鉴权配置。

**appid ** <span data-label="purple">String</span> %%require%%示例值：`94****11`
开通豆包端对端语音大模型后获取的 APP ID，用于标识应用。可在[豆包语音控制台](https://console.volcengine.com/speech/service/10017)获取。


**token ** <span data-label="purple">String</span> %%require%%示例值：`OaO****ws1`
与 APP ID 对应的 Access Token。可在[豆包语音控制台](https://console.volcengine.com/speech/service/10017)获取。



**dialog ** <span data-label="purple">Object</span> %%require%%示例值：`-`
对话相关配置。

**extra ** <span data-label="purple">Object</span> %%require%%示例值：`-`
高级配置，比如模型版本、联网搜索、安全审核等级等。

**model ** <span data-label="purple">String</span> %%require%%示例值：`1.2.1.1`
端到端实时语音大模型版本。

* `1.2.1.1`：O2.0 版本。
* `2.2.0.0`：SC2.0 版本。


**strict_audit ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
安全审核等级：

* `true`（默认值）：严格审核。
* `false`：普通审核。


**audit_response ** <span data-label="purple">String</span> `可选` 示例值：`抱歉这个问题我无法回答，你可以换个其他话题，我会尽力为你提供帮助`
当触发安全审核时，AI 的自定义回复内容。


**enable_volc_websearch ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否启用火山的[联网搜索 API 服务](https://www.volcengine.com/docs/87772/2272949?lang=zh)。

* `true`：启用。
* `false`（默认值）：不启用。


**volc_websearch_api_key ** <span data-label="purple">String</span> `可选` 示例值：`your_api_key`
联网搜索 API Key。可在[联网搜索 API 控制台](https://console.volcengine.com/search-infinity/api-key)创建并获取。
> 该字段在 `enable_volc_websearch` 为 `true `时为必填。


**volc_websearch_type ** <span data-label="purple">String</span> `可选` 示例值：`web_summary`
联网类型。

* `web_summary`（默认值）：总结版。
* `web`：普通版。
* `web_agent`：搜索 Agent。


**volc_websearch_result_count ** <span data-label="purple">Integer</span> `可选` 示例值：`10`
联网搜索返回的结果数量，最多 10 条，默认 10 条。


**volc_websearch_no_result_message ** <span data-label="purple">String</span> `可选` 示例值：`网络上没有找到相关信息。`
安抚语，即当联网搜索无结果时的回复内容。默认为空。


**enable_music ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启音乐播放能力。开启后，模型会检索曲库并播放音乐。

* `true`：不开启。
* `false`（默认值）：开启。


**enable_loudness_norm ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启响度均衡。开启后，系统会自动调节输出音频的音量一致性，防止声音忽大忽小。

* `true`：不开启
* `false`（默认值）：开启。


**enable_conversation_truncate ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启上下文截断。开启后，允许客户端主动截断历史对话，优化长对话性能。

* `true`：不开启。
* `false`（默认值）：开启。


**enable_user_query_exit ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启结束对话意图识别。开启后，系统能识别用户是否想结束对话（如说“再见”），并下发特定信号。

* `true`：不开启。
* `false`（默认值）：开启。



**bot_name ** <span data-label="purple">String</span> `可选` 示例值：`豆包`
智能体名称，用于基础人设。长度不超过 20 个字符。



**system_role ** <span data-label="purple">String</span> `可选` 示例值：`你是大灰狼、用户是小红帽，用户逃跑时你会威胁吃掉他。`
背景人设信息，描述角色的来源、设定等。



**speaking_style ** <span data-label="purple">String</span> `可选` 示例值：`你说话偏向林黛玉`
模型对话风格，例如“你说话偏向林黛玉。”、“你口吻拽拽的。”等。


**dialog_id ** <span data-label="purple">String</span> `可选` 示例值：`dialog_123`
对话 ID，用于加载相同 `dialog_id` 的对话记录，进而提升模型上下文记忆能力。

* 最多支持最近 20 轮 QA 对。
* ID 需要保持全局唯一。

如未设置，会默认生成一个唯一的 ID。


**character_manifest ** <span data-label="purple">String</span> `可选` 示例值：`-`
模型所扮演角色的描述信息，只针对 SC 版本生效。
:::warning
仅当 `extra.model`为 SC 版本（取值 2.2.0.0），且使用自定义复刻音色时生效；使用官方预设的克隆音色时，无需设置该字段。

:::

**location ** <span data-label="purple">Object</span> `可选` 示例值：`-`
地理位置信息。用于客户端传入用户位置信息，以提升联网搜索结果的精准度，关闭内置联网时候无需此字段。

**longitude ** <span data-label="purple">Float</span> `可选` 示例值：`39.9042`
用户所处位置的经度。


**latitude ** <span data-label="purple">Float</span> `可选` 示例值：`116.4074`
用户所处位置的纬度。


**country ** <span data-label="purple">String</span> `可选` 示例值：`中国`
用户所在国家。默认为`中国`。


**country_code ** <span data-label="purple">String</span> `可选` 示例值：`CN`
用户所在国家编号


**province ** <span data-label="purple">String</span> `可选` 示例值：`北京市`
用户所在省份。


**city ** <span data-label="purple">String</span> `可选` 示例值：`杭州市`
用户所在城市。


**district ** <span data-label="purple">String</span> `可选` 示例值：`海淀区`
用户所在区/县。


**town ** <span data-label="purple">String</span> `可选` 示例值：`中关村街道`
用户所在的镇/街道。


**address ** <span data-label="purple">String</span> `可选` 示例值：`北京市海淀区中关村`
具体地址信息。



**dialog_context ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
初始化对话上下文。数组长度必须为偶数，且需按 `user`、`assistant` 的问答对顺序传入。

**role ** <span data-label="purple">String</span> %%require%%示例值：`user`
角色。`user` 或 `assistant`。


**text ** <span data-label="purple">String</span> %%require%%示例值：`你好`
消息内容。


**timestamp ** <span data-label="purple">String</span> `可选` 示例值：`1675180800000`
消息时间戳（毫秒）。若不传，则填充为当前时间。




**asr ** <span data-label="purple">Object</span> `可选` 示例值：`-`
内置的 ASR 模块参数。

**extra ** <span data-label="purple">Object</span> `可选` 示例值：`-`
配置判停。

**end_smooth_window_ms ** <span data-label="purple">Integer</span> `可选` 示例值：`1500`
判停时间。用户停顿时间若高于该值，则认为一句话结束。取值范围 [500, 50000]，单位为毫秒，默认 1500。


**enable_asr_twopass ** <span data-label="purple">String</span> `可选` 示例值：`true`
是否开启非流式模型二遍识别能力：

* `true`：开启。在流式识别基础上，对检测到的完整语句片段进行二次非流式识别，兼顾实时性与准确性。
* `false`（默认值）：仅使用流式识别。


**boosting_table_id ** <span data-label="purple">String</span> `可选` 示例值：`your_boosting_table_id`
热词词表 ID。需先在[豆包语音控制台_热词管理](https://console.volcengine.com/speech/hotword)创建热词词表，并获取热词表 ID。
如果某些词汇（比如人名、产品名等）的识别准确率较低，可以将其作为热词传入模型，提高输入词汇的识别准确率。例如传入"雨伞"作为热词，发音相似的词会优先识别为“雨伞”。
:::warning
仅在 `enable_asr_twopass` 为 `true`时生效。

:::

**boosting_table_name ** <span data-label="purple">String</span> `可选` 示例值：`your_boosting_table_name`
热词词表名称。需先在[豆包语音控制台_热词管理](https://console.volcengine.com/speech/hotword)创建热词词表，并获取热词表名称。


**regex_correct_table_i ** <span data-label="purple">String</span> `可选` 示例值：`your_regex_correct_table_id`
正则替换词表 ID。需先在[豆包语音控制台_替换词管理](https://console.volcengine.com/speech/correctword)创建正则词表，并获取 ID。


**regex_correct_table_name ** <span data-label="purple">String</span> `可选` 示例值：`your_regex_correct_table_name`
正则替换词表名称。需先在[豆包语音控制台_替换词管理](https://console.volcengine.com/speech/correctword)创建正则词表，并获取名称。


**context ** <span data-label="purple">Object</span> `可选` 示例值：`-`
直传自定义热词或替换词。
词表配置与 context 内配置同时传值时自动合并，所有规则叠加生效。

**hotwords ** <span data-label="purple">Object[]</span> `可选` 示例值：`[{"word": "火山引擎"}]`
直传热词。

* 格式为 `[{"word":"xxx"}]`。
* 仅在 `enable_asr_twopass` 为 `true` 时生效。


**correct_words ** <span data-label="purple">JSONMap</span> `可选` 示例值：`{"火上": "火山"}`
直传替换词。格式为 ` {"正则原文本":"替换后文本"}`。





**tts ** <span data-label="purple">Object</span> `可选` 示例值：`-`
内置的 TTS 模块参数。

**speaker ** <span data-label="purple">String</span> `可选` 示例值：`zh_female_vv_jupiter_bigtts`
音色。支持的音色如下：

* `zh_female_vv_jupiter_bigtts`（默认值）：对应 vv 音色，活泼灵动的女声，有很强的分享欲。
* `zh_female_xiaohe_jupiter_bigtts`：对应 xiaohe 音色，甜美活泼的女声，有明显的台湾口音。
* `zh_male_yunzhou_jupiter_bigtts`：对应 yunzhou 音色，清爽沉稳的男声。
* `zh_male_xiaotian_jupiter_bigtts`：对应 xiaotian 音色，清爽磁性的男声。


**audio_config ** <span data-label="purple">Object</span> `可选` 示例值：`-`
音频配置。

**channel ** <span data-label="purple">Integer</span> `可选` 示例值：`1`
声道数。目前仅支持 `1`（单声道）。


**format ** <span data-label="purple">String</span> `可选` 示例值：`pcm_s16le`
音频编码格式。支持 `pcm` (32bit) 和 `pcm_s16le` (16bit)。


**sample_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`24000`
采样率。目前仅支持 `24000Hz`。


**speech_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
语速。取值范围 `[-50, 100]`，取值越大语速越快。

* `100`：2.0 倍速。
* `-50`：0.5 倍速。
* `0`（默认值）：原语速。

:::warning
仅 2.0 版本模型支持该功能。

:::

**loudness_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
音量。取值范围 `[-50, 100]`，取值越大语音量越快。

* `100`：2.0 倍音量。
* `-50`：0.5 倍音量。
* `0`（默认值）：原音量。

:::warning
仅 2.0 版本模型支持该功能。

:::





**MusicAgentConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
AI 音乐 Agent 配置。启用后，AI 可根据用户指令，为用户播放音乐或控制音乐播放（如：上一首、下一首、暂停播放、停止播放、继续播放等）。
:::warning

* 仅具备 Function Calling 功能的方舟或第三方大模型支持该功能。
* 该功能目前为限时免费公测阶段。音乐来源于火山引擎内部 AI 音乐曲库，不包含有明确版权的明星歌曲。
* 音乐音频流的处理逻辑与普通对话音频流一致，支持被语音或手动打断。


:::
**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否启用 AI 音乐 Agent：

* `true`：启用。
   * **下一步操作**：AI 音乐 Agent 是以内置工具的形式提供，启用后，您还需在 `LLMConfig.SystemMessages` 中添加提示词，引导模型准确调用该内置工具。
   * **提示词示例**：当用户意图为播放音乐或控制音乐播放时（如：上一首、下一首、暂停播放、停止播放、继续播放等），才触发 `music_player` 工具调用。如果用户仅说“暂停”、“停止”、“停一下”等模糊指令时，需先判断上下文。若上一轮问题与音乐播放无关，应视为用户要求“停止对话”，此时应直接以文字回应，禁止调用工具 `music_player` 。
* `false`（默认值）：关闭。




**AgentConfig ** <span data-label="purple">Object</span> %%require%%示例值：`-`
AI Bot 相关配置，包括欢迎词、状态回调等信息。

**TargetUserId ** <span data-label="purple">String[]</span> %%require%%示例值：`["user1"]`
真人用户 ID。需使用客户端 SDK 进房的真人用户的 UserId。仅支持传入一个 UserId，即单个房间内，仅支持一个用户与AI Bot 一对一通话。
:::warning
`UserId` 的值不能与 `AgentConfig.TargetUserId`（真人用户 ID）和 `AvatarUserID`（数字人 ID）相同。

:::

**UserId ** <span data-label="purple">String</span> %%require%%示例值：`BotName001`
智能体的 ID。由你自定义。
**命名规则**：

* 支持由大小写字母（A\-Z、a\-z）、数字（0\-9）、下划线（_）、短横线（\-）、句点（.）和 @ 组成，最大长度为 128 个字符。
* 同一 AppId 下 UserId 全局唯一。若同一 AppId 下不同房间内 AI Bot 名称相同，会导致使用服务端回调的功能异常，如字幕、Function Calling 和状态回调功能。
* `UserId` 的值不能与 `AgentConfig.TargetUserId`（真人用户 ID）和 `AvatarUserID`（数字人 ID）相同。


**WelcomeMessage ** <span data-label="purple">String</span> `可选` 示例值：`Hello`
启动后的欢迎词。


**EnableConversationStateCallback ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
是否开启 AI Bot 状态变化消息回调（二进制格式），以获取 AI Bot 关键状态（如“聆听中”、“思考中”、“说话中”、“被打断”等）。

* `true`：开启。启用后，消息可通过二进制格式回调给客户端或服务端。
   * 回调给客户端：还需在客户端实现监听回调 [onRoomBinaryMessageReceived](https://www.volcengine.com/docs/6348/70081#IRTCRoomEventHandler-onroombinarymessagereceived)（以 Android 端为例）。
   * 回调给服务端：还需配置字段 `ServerMessageURLForRTS` 和 `ServerMessageSignatureForRTS`。
   消息为二进制，接收后还需解析。具体解析操作，参见[获取 AI 状态](https://www.volcengine.com/docs/6348/1415216)。
* `false`（默认值）：关闭。


**ServerMessageURLForRTS ** <span data-label="purple">String</span> `可选` 示例值：`https://example-domain.com/vertc/callback`
您的业务服务器地址（URL），用于接收服务端回调消息（包括 AI Bot 状态变化和实时字幕）。
URL 地址要求：

* 公网可访问的域名地址。若使用 HTTPS，请确保 SSL 证书合法且完整。
* 该 URL 指向的服务端能够正常处理无 Content\-Type 的 POST 请求。

:::tip
您可以使用以下命令模拟回调请求，快速校验服务器配置是否满足要求：`curl -v -X POST <url>`。

* 若返回 301 或 302：说明 URL 地址不可用。此时 POST 请求会被降级为 GET 请求，导致数据丢失。该问题通常是由于填写的 HTTP 地址发生了跳转（如强制跳转至 HTTPS），建议直接配置最终跳转后的 HTTPS 地址。
* 若返回 307 或 308：说明 URL 地址可用。虽然发生了重定向，但机制允许保持 POST 方法和请求体，回调可正常接收。

:::

**ServerMessageSignatureForRTS ** <span data-label="purple">String</span> `可选` 示例值：`b4****d6a`
签名密钥。用于验证服务端回调请求（包括 AI Bot 状态变化和实时字幕）真实性，由您自定义。
当平台向您的 `ServerMessageURLForRTS` 发送回调请求时，会在请求体返回 `signature` 字段，其值为您配置的密钥。您的服务端必须校验 `signature` 的值是否与您预设的密钥一致，以确保请求来源可靠。


**UseLicense ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否为 License 用户。

* `true`：是。
* `false`：否。

默认值为 `false`。
若为 License 用户，你需要：

1. 联系[技术支持](https://console.volcengine.com/workorder/create?step=2&SubProductID=P00000081)开通白名单。
2. 前往[控制台硬件场景服务](https://console.volcengine.com/rtc/aigc/hardwareService)获取你需要的 ASR、TTS 和 LLM 相关参数值。注意你必须使用在此处获取的 ASR、TTS 和 LLM 参数值。
3. 如果你使用大模型流式语音识别和大模型语音合成，在调用 `StartVoiceChat` 接口时，`ASRConfig.ProviderParams.AccessToken` 和 `TTSConfig.ProviderParams.AccessToken`无需填入。


**Burst ** <span data-label="purple">Object</span> `可选` 示例值：`-`
配置音频快速发送，以提高弱网或网络抖动环境下的播放流畅度，减少卡顿。
> 为应对弱网或网络抖动环境，启用此功能后，系统在会话开始时预先发送一段音频数据到客户端，建立播放缓冲区，从而显著减少播放卡顿，提升播放流畅度。

:::warning
该功能仅在嵌入式硬件场景下支持，且嵌入式 Linux SDK 版本不低于 1.57。

:::
**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启音频快速发送功能。

* `false`：关闭。
* `true`：开启。开启后，在单轮会话回复开始时，服务端会将指定时长（由 `BufferSize` 决定）的音频数据一次性“突发”给客户端，在客户端快速建立一个播放缓冲区，用以对抗网络抖动。

默认值为 `false`。


**BufferSize ** <span data-label="purple">Integer</span> `可选` 示例值：`500`
服务端在突发阶段一次性发送的初始音频时长。
取值范围为 `[10, 3600000]`，单位为 ms，默认值为 `500`。


**Interval ** <span data-label="purple">Integer</span> `可选` 示例值：`10`
突发结束后，服务端给客户端发送后续音频数据的时间间隔。后续服务端以这个速率均匀发送数据给客户端。
取值范围 `[10, 600]`，单位为 ms，默认值为 `10`。



**IdleTimeout ** <span data-label="purple">Integer</span> `可选` 示例值：`180`
空闲等待超时时间（单位：秒）。默认值为 180s。
定义当房间内没有真人用户（即 `TargetUserId`离线）时，AI Bot 自动退出的等待时长。超过该时间，AI Bot 退出房间且任务自动停止。可避免因用户异常掉线导致长时间空转，产生不必要的费用。建议根据业务场景合理设置。


**AnsMode ** <span data-label="purple">Integer</span> `可选` 示例值：`1`
AI 降噪。对音频进行智能降噪处理，适用于不具备或不便开启端侧 AI 降噪能力的终端。例如：若物联网、智能硬件设备算力有限，无法运行复杂的端侧降噪算法的场景。
可根据实际噪声环境选择不同级别的降噪模式：

* `0`（默认值）：禁用 AI 降噪。
* `1`：轻度降噪。适用于抑制微弱、平稳的背景噪声。
* `2`：中度降噪。适用于抑制中度平稳噪声，如空调声、风扇声。
* `3`：重度降噪。适用于抑制嘈杂、非平稳的动态噪音，如键盘敲击声、物体碰撞声、动物叫声等。


**VoicePrint ** <span data-label="purple">Object</span> `可选` 示例值：`-`
声纹配置（包含声纹降噪和声纹识别）。
:::warning

* 声纹功能目前为免费公测阶段，算法还在进一步优化。
* 使用声纹功能时，仅支持流式 ASR，且 `StreamMode` 不能为 `1`（流式输入非流式输出）。
* 使用声纹功能时，建议不要开启 AI 降噪，以免影响声纹降噪/声纹识别的效果。


:::
**Mode ** <span data-label="purple">Integer</span> `可选` 示例值：`1`
声纹模式：

* `0`（默认值）：关闭声纹功能。
* `1`：声纹降噪。从混合人声中分离并增强目标说话人的声音，抑制其他背景人声的干扰。适用于背景人声干扰较强的场景（如嘈杂办公室），或需要对操作者身份进行验证的场景。如车载语音助手，防止儿童或乘客误操作。
* `2`：声纹识别。通过声纹比对识别出当前正在说话的人是谁。适用于多用户共享同一个 AI 设备或服务的场景，以提供个性化服务。


**IdList ** <span data-label="purple">String[]</span> `可选` 示例值：`["vp_id_123"]`
预注册的声纹 ID 列表。

* **当 Mode = 1 时（声纹降噪）** ：
   * **传入 1 个预注册声纹 ID（使用预注册声纹）** ：系统加载该声纹作为目标说话人模板，仅保留匹配的人声。仅支持传入 1 个声纹 ID。
   * **空或不传（自动注册声纹）** ：系统在通话开始后自动学习 `TargetUserId` 的声音特征。当用户累计说话时长达到 `VoiceDuration`（有效语音时长）后，生成一个临时声纹，用于本次通话的降噪。
* **当 Mode = 2 时（声纹识别）** ：传入 1～3 个已注册的声纹 ID。

:::tip

* 声纹可通过 [RegisterVoicePrint](./1804905) 和 [ListVoicePrint](./1804908) 预注册或获取（对应字段 `VoicePrintId`）。
* 为保证最佳效果，建议注册声纹与实际通话使用相同的音频采集设备。

:::

**VoiceDuration ** <span data-label="purple">Integer</span> `可选` 示例值：`12`
声纹降噪模式下，自动注册声纹时所需的有效语音时长。单位为秒。

* 取值范围：[4, 33]。
* 默认值：12。

:::warning
该字段仅在 `Mode` 为 `1` 且 `IdList`为空时生效。

:::

**EnableSV ** <span data-label="purple">Boolean</span> `可选` 示例值：`false`
&nbsp;
声纹降噪模式下，是否验证说话人身份：

* `false`（默认值）：关闭。
* `true`：开启。系统会实时提取说话人的声纹特征，并与 `IdList` 中预注册或自动注册的声纹比对。仅当匹配成功时，才将 ASR 识别结果送入 LLM；否则将丢弃该段语音，不触发后续业务逻辑，从而避免背景人声误触发 AI。

:::warning
该字段仅在启用声纹降噪（即 Mode 为 1）时生效。

:::

**Score ** <span data-label="purple">Integer</span> `可选` 示例值：`40`
声纹识别模型下，声纹的置信度阈值。可用于判断当前说话人是否为目标用户。
配置后，系统会计算实时语音与预注册声纹的“相似度分数”。只有当分数不低于设定阈值时，才会判定说话人为目标用户。

* 取值范围：[1, 100]。
* 推荐值：40 ~ 60。
* 默认为空，不进行置信度过滤，所有识别结果都会被判定为目标用户。

:::warning
该字段仅在启用声纹识别（即 Mode 为 2 且 IdList 有值）时生效。

:::



<span id=".6L-U5Zue5Y-C5pWw"></span>
## 返回参数
本接口无特有的返回参数。公共返回参数请见[返回结构](https://www.volcengine.com/docs/6348/1178322)。
其中返回值 `Result` 仅在请求成功时返回 `ok`，失败时为空。
