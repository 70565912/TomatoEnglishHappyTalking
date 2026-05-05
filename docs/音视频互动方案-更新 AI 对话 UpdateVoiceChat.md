通过 StartVoiceChat 成功启动一个智能体任务后，你可以在对话进行中的任何时刻调用本接口发送实时任务指令或更新任务配置。

* **发送实时指令：**
   * [手动打断智能体](./1511927#.5omL5Yqo5omT5pat)：立即打断智能体当前的语音播报。
   * [回传 Function Calling 的工具调用结果](./1554654)：向 LLM 回传 Function Calling 的工具调用结果。
   * [手动触发智能体响应](./1544164)：结束当前用户的语音输入，立即触发新一轮对话。
   * [自定义语音播放](./1449206)：让智能体主动播报一段指定的文本。
   * [动态传入上下文](https://www.volcengine.com/docs/6348/1511926?lang=zh#.5Yqo5oCB5Lyg5YWl5LiK5LiL5paH)：向 LLM 传入下一轮对话的背景信息（不立即回复）。
   * [传入文本直接提问](https://www.volcengine.com/docs/6348/2129096)：通过文本直接向智能体提问。
   * [图片理解](./1408245#.5aSW6YOo5Zu-54mH55CG6Kej)：向具备视觉能力的 LLM 传入图片。
   * [动态传入情绪指令标签](https://www.volcengine.com/docs/6348/2139328)：注入指令标签，来控制智能体下一轮回复播报的语气（如欢快、伤心）、语速和音量等。
* **更新任务配置（如TTS、LLM 等）：** 具体支持更新的配置项，以 `Parameters` 对象为准。更新配置不影响正在进行的回答，会在下一次提问的时候生效。

<span id=".6LCD55So5o6l5Y-j"></span>
## 调用方法
关于调用接口的请求结构、公共参数、签名方法、返回结构，参看[如何调用 OpenAPI](https://www.volcengine.com/docs/6348/1899868)。
<span id="pZpt3OBA"></span>
## 注意事项

* 请求频率：单账号下 QPS 不得超过 60。
* 请求接入地址：仅支持 `rtc.volcengineapi.com`。

<span id=".6K-35rGC6K-05piO"></span>
## 请求说明

* 请求方式：POST
* 请求地址：https://rtc.volcengineapi.com?Action=UpdateVoiceChat&Version=2025\-06\-01

<span id="ZkPGvWG9"></span>
## 请求参数
下表仅列出该接口特有的请求参数和部分公共参数。更多信息请见[公共参数](./1178321)。
<span id="Query"></span>
### Query


**Action ** <span data-label="purple">String</span> %%require%%示例值：`UpdateVoiceChat`
接口名称。当前 API 的名称为 `UpdateVoiceChat`。


**Version ** <span data-label="purple">String</span> %%require%%示例值：`2025-06-01`
接口版本。当前 API 的版本为 `2025-06-01`。


<span id="Body"></span>
### Body


**AppId ** <span data-label="purple">String</span> %%require%%示例值：`661e****543cf`
应用的唯一标志。
需与调用 `StartVoiceChat` 启动任务时使用的 `AppId` 保持一致。可在[音视频互动智能体_应用管理](https://console.volcengine.com/conversational-ai/devTools/appIdManage)获取。


**RoomId ** <span data-label="purple">String</span> %%require%%示例值：`Room1`
通话房间 ID。
需与调用 `StartVoiceChat` 启动任务时使用的 `RoomId` 保持一致。


**TaskId ** <span data-label="purple">String</span> %%require%%示例值：`Task1`
目标智能体任务的 ID。
需与调用 `StartVoiceChat` 启动任务时定义的 `TaskId` 保持一致。


**Command ** <span data-label="purple">String</span> %%require%%示例值：`interrupt`
要执行的指令，决定本次请求的操作意图：

* `interrupt`：打断智能体说话。使用方法参见[手动打断](https://www.volcengine.com/docs/6348/1511927#.5omL5Yqo5omT5pat)。
* `function`：用于 Function Calling 场景，回传工具执行结果。使用方法，可参见 [函数调用 Function Calling](./1554654)。
* `ExternalTextToSpeech`：将指定文本直接送入 TTS 让智能体主动播报（需配合 `Message` 和`InterruptMode` ** ** 字段）。使用方法参看[自定义语音播放](https://www.volcengine.com/docs/6348/1449206)。
* `ExternalPromptsForLLM`：发送自定义文本作为背景信息，与用户的下一轮语音输入拼接后一同送入 LLM（需配合 `Message` 字段）。使用方法，可参见[动态传入上下文](https://www.volcengine.com/docs/6348/1511926?lang=zh#.5Yqo5oCB5Lyg5YWl5LiK5LiL5paH)。**注意：此指令在启用端到端语音模型（S2SConfig）时无效**。
* `ExternalTextToLLM`：向 LLM 发送文本或图片信息，直接触发 LLM 回复。**注意：此指令在启用端到端语音模型（S2SConfig）时无效**。
   * **文本提问**：配合使用 `Message` 字段，作为当前轮次的用户文本输入。使用方法，可参见[通过文本直接提问](https://www.volcengine.com/docs/6348/2129096)。
   * **图片理解**：传入 `ImageConfig` 字段（必填）发送图片，可同时配合 `Message` 字段（选填）传入关于图片的文本问题。使用方法，可参见[外部图片理解](https://www.volcengine.com/docs/6348/1408245#.5aSW6YOo5Zu-54mH55CG6Kej)。
* `FinishSpeechRecognition`：强制结束当前对话，触发新一轮对话。使用方法，可参见[判停与对话触发](./1544164)。
* `UpdateParameters`：更新智能体配置，需配合 `Parameters` 字段使用。
* SetTTSContext：为下一轮对话动态设置 TTS 指令标签，使播报具备情感。需配合 Message 字段使用。具体使用方法，请参见[情绪识别与生成](https://www.volcengine.com/docs/6348/2139328)。
   :::warning

   SetTTSContext指令仅在使用火山语音合成大模型（流式输入流式输出），且在 StartVoiceChat 配置 Context.TagParse 为 ture 时生效。

   :::
* `UpdateVoicePrintSV`：更新声纹降噪配置，包括开启或关闭实时声纹验证、更新实时声纹注册时长。**注意**：该指令仅在 [StartVoiceChat](https://www.volcengine.com/docs/6348/2123348) 中 `VoicePrint.Mode` 为 0，且  `VoicePrint.IdList ` 为空时生效。
* `UpdateFarfieldConfig`：更新远场人声抑制配置。**注意**：该指令仅在使用火山语音识别大模型或火山声音复刻大模型时生效。


**Message ** <span data-label="purple">String</span> `可选` 示例值：`"{"ToolCallID":"call_cx","Content":"上海天气是台风"}"`
指令内容。该字段是否必填及内容格式，取决于 `Command` 的取值：

* `Command` 为 `function`：**必填**。填入工具执行结果（JSON 字符串）。示例：`"{\"ToolCallID\":\"call_cx**\",\"Content\":\"上海今天台风\"}"`。
* `Command` 为 `ExternalTextToSpeech`：**必填**。填入需智能体播报的普通文本。建议长度不超过 200 个字符，以避免合成延迟过高影响体验。
* `Command` 为 `ExternalPromptsForLLM`：**必填**。填入需注入 LLM 的背景提示词文本。
* `Command` 为 `ExternalTextToLLM`：
   * **纯文本提问**：**必填**。填入文本问题。
   * **图片理解**：**分场景。**
      * 若传入 Message：作为图片关联的文本问题（如“这张图里有什么？”），系统会将图片 + 文本送入 LLM，并触发 LLM 生成回复。
      * 若传入 Message：系统仅将图片缓存到当前轮次（`GroupID`）的上下文中，不触发 LLM 回复，等待后续指令。适用于分片上传或多图上传场景。
* 当 `Command` 为 `SetTTSContext` 时：**必填**。填入要设置的 TTS 标签（必须为 JSON 转义字符串），该标签仅对下一轮回答生效。`Message` 格式取决于您在 `StartVoiceChat` 中通过 `ResourceId` 指定的 TTS 模型版本：
   * 语音合成大模型 2.0：`"{\"Tag\":{\"additions\":{\"context_texts\":[\"你的语气再欢乐一点\"]}}}"`
   * 语音合成大模型 1.0：`"{\"Tag\":{\"audio_params\":{\"emotion\":\"happy\",\"emotion_scale\":5}}}"`
   详细说明，请参见[情绪识别与生成](https://www.volcengine.com/docs/6348/2139328)。
* 当 `Command` 为 `UpdateVoicePrintSV` 时：**必填。** 一个 JSON 转义字符串，示例：`"{\"Enable\": true, \"VoiceDuration\": 10}"`。
   * `Enable` (Boolean)：开启或关闭实时声纹验证。
   * `VoiceDuration`：新的注册时长要求，取值为 [4, 33]，单位为秒。
* 当 `Command` 为 `UpdateFarfieldConfig` 时，**必填。** 一个 JSON 转义字符串，示例：`{\"Enable\": true, \"Level\": \"Medium\", \"Threshold\": 0, \"FixedSource\": false}"`。参数说明及取值要求，参见 [StartVoiceChat](https://www.volcengine.com/docs/6348/1558163) 中的 `FarfieldConfig`。
* 其他 `Command`：此字段可忽略，无需填写。


**InterruptMode ** <span data-label="purple">Integer</span> `可选` 示例值：`1`
指令处理优先级。用于控制当智能体当前正在进行交互（如正在说话或思考）时，如何处理本次请求传入的内容。
:::warning
仅当 `command` 为 `ExternalTextToSpeech` 或 `ExternalTextToLLM`时生效且必填。
:::
取值说明：

* `1`：高优先级。强制终止智能体当前的动作（说话或思考），立即执行本次指令。
* `2`：中优先级。不打断当前交互，等待智能体完成当前回应后，再执行本次指令。
* `3`：低优先级。如果智能体处于交互状态，则直接丢弃本次传入的文本或图片信息；如果智能体未在交互，则执行本次指令。


**ImageConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
图片配置。用于向具备视觉能力的 LLM 传入图片数据（URL），实现图片问答。
:::warning
仅确保 `Command` 为 `ExternalTextToLLM`。

:::
**Action ** <span data-label="purple">String</span> %%require%%示例值：`insert`
对图片的操作类型，取值如下：

* `insert`：传入图片。将图片发送给 LLM 进行理解。系统会暂时缓存这些图片，以便与后续的文本问题关联。还需填 `Images`（URL列表）和 `GroupID`。
* `delete`：删除指定 `GroupID` 下已缓存的图片数据。


**GroupID ** <span data-label="purple">Integer</span> %%require%%示例值：`2`
图片轮次 ID。`Action` 取值不同作用不同：

* `Action` 为 `insert` 时：用于将图片或后续的文本问题关联到同一轮对话中。该 ID 由您自定义和维护，需保证 ID 单调递增。
* `Action` 为 `delete` 时：使用 `GroupID` 来指定要清除哪一轮的图片缓存。


**ImageType ** <span data-label="purple">String</span> `可选` 示例值：`url`
图片数据格式。目前固定为 `url`。
:::warning
仅当 `Action` 为 `insert`时生效且必填。

:::

**Images ** <span data-label="purple">String[]</span> `可选` 示例值：`["https://your-tos-bucket.volces.com/path/to/image.jpg"]`
指定要传入的图片 URL 地址，必须确保 URL 可被公网访问，否则大模型无法下载解析。
:::warning
仅当 `Action` 为 `insert`时生效且必填。

:::


**Parameters ** <span data-label="purple">Object</span> `可选` 示例值：`-`
智能体配置参数。
:::warning
请确保 `Command` 为 `UpdateParameters`。

:::
**Config ** <span data-label="purple">Object</span> `可选` 示例值：`-`
包含 LLM、TTS 等模块的具体配置。

**LLMConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
大模型相关配置。

**SystemMessages ** <span data-label="purple">String[]</span> `可选` 示例值：`["你是小宁，性格幽默又善解人意。你在表达时需简明扼要，有自己的观点。"]`
系统提示词。用于定义智能体的角色设定、行为准则、回复语气及输出格式等。

* **更新**：传入新的字符串数组，将覆盖旧配置。
* **清除**：传入空数组 `[]` 或 `null`，可清除当前预设的系统提示词。


**UserPrompts ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
用户提示词。即预设的用户输入与回答，用于引导模型生成特定的输出或设定对话背景。

* **更新**：传入包含 `Role` 和 `Content` 的对象数组，将全量覆盖旧配置。
* **清除**：传入空数组 `[]` 或 `null`，可清除当前预设的用户提示词。

:::warning
`UserPrompts` 设有自动逐出机制：当对话总数超过 HistoryLength 限制时，最早的 `UserPrompts` 会被自动逐出，为新的对话历史腾出空间。
示例：若 HistoryLength 设置为 3 且已预存 2 轮对话。在用户与智能体完成第 1 轮真实对话后，上下文总轮数为 3（2 预存 + 1 用户），此时无需逐出；当用户发起第 2 轮对话时，总轮数变为 4 超过限制，系统会自动移除最早的一轮预存内容，使上下文始终只保留最近的 3 轮记录。

:::
**Role ** <span data-label="purple">String</span> `可选` 示例值：`user`
发送消息的角色。支持取值 system、user 和 assistant。其中 user 和 assistant 必须成对出现（一问一答），否则大模型可能会出现未定义行为。


**Content ** <span data-label="purple">String</span> `可选` 示例值：`你是谁？`
消息内容。



**Tools ** <span data-label="purple">Object[]</span> `可选` 示例值：`-`
更新 Function Calling 工具列表，或关闭 Function Calling 功能。

* **更新工具**：传入包含新工具定义的数组，覆盖旧配置。
* **关闭 Function Calling 功能**：设为 `null` 或 `[]`，即可。例如 ` {"Tools": null}`。


**type ** <span data-label="purple">String</span> `可选` 示例值：`function`
工具类型。目前固定取值 `function`，表示函数调用。


**function ** <span data-label="purple">Object</span> `可选` 示例值：`-`
指定模型可以调用的函数列表。

**name ** <span data-label="purple">String</span> `可选` 示例值：`get_current_weather`
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





**VisionConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
视觉理解能力配置。可更新视觉理解配置，或关闭视觉理解。

* **更新/开启：** 配置 `Enable` 和 `SnapshotConfig`。[如何使用视觉理解能力？](https://www.volcengine.com/docs/6348/1408245)
* **关闭**：将 `VisionConfig` 设置为 `null`，或将 `VisionConfig.Enable` 设置为 `false`。


**Enable ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否开启视觉理解功能。

* `false`：不开启。
* `true`：开启。

默认值为 `false`。


**SnapshotConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
抽帧截图配置。智能体会按照配置策略在后台自动抽帧截图送入大模型以供理解。

**StreamType ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
截图流类型。

* `0`：主流。指来自摄像头的实时视频画面。
* `1`：屏幕共享流。指用户共享的设备屏幕内容（如桌面、应用窗口、PPT 等）。

默认值为 `0`。





**TTSConfig ** <span data-label="purple">Object</span> `可选` 示例值：`-`
语音合成（TTS）相关配置。你可以按需进行以下操作：

* **修改当前 TTS 服务配置**：若保持当前 TTS 服务不变，仅需传入要修改的字段（如只传 `speed_ratio`）。
* **切换 TTS 服务**：如从火山引擎“语音合成”切到“声音复刻”，必须同时将 `Provider` 和 `ProviderParams` 更换为新服务对应值和支持的字段，以确保覆盖旧配置。


**Provider ** <span data-label="purple">String</span> `可选` 示例值：`volcano`
语音合成服务提供商。
使用不同语音合成服务时，取值不同。支持使用的语音合成服务及对应取值如下：

* `volcano`（服务自上而下语音生成速度递减，情感表现力递增）
   * 火山引擎语音合成
   * 火山引擎语音合成大模型（非流式输入流式输出）
   * 火山引擎声音复刻大模型（非流式输入流式输出）
* `volcano_bidirection`（服务自上而下语音生成速度递减，情感表现力递增）
   * 火山引擎语音合成大模型（流式输入流式输出）
   * 火山引擎声音复刻大模型（流式输入流式输出）
* `minimax`：MiniMax 语音合成
* `ai_gateway`：自定义语音合成模型（通过火山边缘大模型网关接入的）


**ProviderParams ** `可选` 示例值：`-`
配置所选的语音合成服务。不同服务下，需配置的字段不同：

* [火山语音合成](#volctts)
* [火山语音合成大模型（非流式输入流式输出）](#volcanobittsconfig)
* [火山语音合成大模型（流式输入流式输出）](#volcanobigbittsconfig)
* [火山声音复刻大模型（非流式输入流式输出）](#volcanoduttsconfig)
* [火山声音复刻大模型（流式输入流式输出）](#volcanodubittsconfig)
* [MiniMax 语音合成](#minimaxtts)
* [自定义语音合成](#thirdpartyttsconfig)


<span id="volctts"></span>
#### 火山引擎语音合成 <span data-label="purple">Object</span>
使用火山引擎语音合成时，`TTSConfig.ProviderParams` 包含以下字段：

**app ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成服务应用配置。

**cluster ** <span data-label="purple">String</span> `可选` 示例值：`volcano_tts`
集群标识（Cluster ID），固定为 `volcano_tts`。



**audio ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成服务音频配置。

**voice_type ** <span data-label="purple">String</span> `可选` 示例值：`BV001_streaming`
音色。支持的音色及对应的 voice_type 请参见[音色列表](https://www.volcengine.com/docs/6561/97465?lang=zh)。


**speed_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值范围为 `[0.2, 3]`，默认值为 `1.0`，通常保留一位小数即可。取值越大，语速越快。


**volume_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音量。取值范围为 `[0.1, 3]`，默认值为 `1.0`，通常保留一位小数即可。取值越大，音量越高。


**pitch_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音高。取值范围为 `[0.1, 3]`，默认值为 `1.0`，通常保留一位小数即可。取值越大，音调越高。




<span id="volcanobittsconfig"></span>
#### 火山引擎语音合成大模型（非流式输入流式输出） <span data-label="purple">Object</span>
使用火山引擎语音合成大模型（非流式输入流式输出）时，`TTSConfig.ProviderParams` 包含以下字段：

**app ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成大模型服务应用配置。

**cluster ** <span data-label="purple">String</span> `可选` 示例值：`volcano_tts`
集群标识（Cluster ID），固定为 `volcano_tts`。



**audio ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> `可选` 示例值：`zh_female_meilinvyou_moon_bigtts`
音色。填入音色对应的标识 `Voice_type`，可在[豆包语音控制台-语音合成大模型](https://console.volcengine.com/speech/service/10007?)获取。
:::warning
音色需与 `ResourceId` 中的模型版本匹配，即语音合成大模型 1.0 仅适用于豆包语音合成模型 1.0 音色，2.0 仅适用于豆包语音合成模型 2.0 音色。详情可参见[音色列表](https://www.volcengine.com/docs/6561/1257544)。

:::

**speed_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值范围为`[0.2, 3]`，默认值为 `1.0`，通常保留一位小数即可。




<span id="volcanobigbittsconfig"></span>
#### 火山语音合成大模型（流式输入流式输出） <span data-label="purple">Object</span>
此方式封装了语音合成大模型（流式输入流式输出）部分通用参数，接入简单，但无法使用该服务的全部功能。直传模型参数时， `TTSConfig.ProviderParams` 包含以下字段：

**audio ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> `可选` 示例值：`BV001_streaming`
音色。填入音色对应的标识 voice_type，需与在 `ResourceId` 中指定的模型版本匹配：

* 使用语音合成大模型 1.0 服务仅支持 1.0 支持的音色。
* 使用语音合成大模型 2.0 服务仅支持 2.0 支持的音色。

详情请参见[音色列表](https://www.volcengine.com/docs/6561/1257544)。


**speech_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
语速。取值范围 `[-50, 100]`，取值越大，语速越快。

* `100`：2.0 倍速。
* `-50`：0.5 倍速。
* `0`（默认值）：原语速。



**ResourceId ** <span data-label="purple">String</span> `可选` 示例值：`volc.service_type.10029`
指定要使用的语音合成大模型的版本：

* `seed-tts-1.0` 或 `volc.service_type.10029`（默认值）：语音合成大模型 1.0 字符版
* `seed-tts-2.0`：语音合成大模型 2.0 字符版


**Additions ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎语音合成大模型服务高级配置。

**enable_latex_tn ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
播报 LaTeX 公式。启用后，智能体能够以自然语言朗读文本中的 LaTeX 格式的数学公式。

* `false`（默认值）：不播报。
* `true`：播报。 为`true` 时，`disable_markdown_filter` 也需为 `true` 才生效。

**效果示例：**
```Plain Text
LLM 返回：根据公式 a^2 + b^2 = c^2 可知...
智能体播放：根据公式 a 的平方加上 b 的平方等于 c 的平方 可知...
字幕显示：根据公式 a^2 + b^2 = c^2 可知...
```



**disable_markdown_filter ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
过滤 Markdown 格式。
启用后，语音合成时会自动过滤 LLM 返回文本中的 Markdown 格式符号（如加粗、标题等），确保语音播报的连贯性。

* `false`（默认值）：不过滤。
* `true`：过滤。

**效果示例**：
```Plain Text
LLM 返回：请执行 **grep** 命令查看日志。
智能体播放：请执行 grep 命令查看日志。
字幕显示：请执行 **grep** 命令查看日志。
```



**enable_language_detector ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否自动识别语种。[支持哪些语种？](https://www.volcengine.com/docs/6561/1257543)

* `true`：自动识别。
* `false`：不自动识别。

默认值为 `false`。




<span id="volcanoduttsconfig"></span>
#### 火山声音复刻大模型（非流式输入流式输出） <span data-label="purple">Object</span>
使用火山引擎声音复刻大模型（非流式输入流式输出）时，`TTSConfig.ProviderParams` 包含以下字段：

**app ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎声音复刻大模型服务应用配置。

**cluster ** <span data-label="purple">String</span> `可选` 示例值：`volcano_icl`
集群标识（Cluster ID），固定为 `volcano_icl`。



**audio ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎声音复刻大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> `可选` 示例值：`S_****k1`
经过训练后的复刻声音 ID。你需要先进行以下操作：

1. [购买声音复刻资源](https://console.volcengine.com/conversational-ai/purchase)（选择 1.0 版本）。
2. [训练音色并获取声音 ID](https://console.volcengine.com/conversational-ai/myVoice/voiceCloning)。
   <span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_ecc579b4ca43d705a0b7c359a9f164d3.png =418x) </span>


**speed_ratio ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
语速。取值范围为 `[0.8, 2]`，通常保留一位小数即可，取值越大，语速越快。
默认值为 `1.0` 表示原语速。




<span id="volcanodubittsconfig"></span>
#### 火山声音复刻大模型（流式输入流式输出） <span data-label="purple">Object</span>
此方式封装了声音复刻大模型（流式输入流式输出）部分通用参数，接入简单，但无法使用该 服务的全部功能。直传模型参数时，`TTSConfig.ProviderParams` 包含以下字段：

**audio ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎声音复刻大模型服务音频配置。

**voice_type ** <span data-label="purple">String</span> `可选` 示例值：`S_N****T7k1`
经过训练后的复刻声音 ID。请确保你已经进行以下操作：

1. [购买声音复刻资源](https://console.volcengine.com/conversational-ai/purchase)。
   * 1.0 版本：适合对合成速度要求高的场景。
   * 2.0 版本：适合对音色表现力要求高，希望生成更具个性化和情感化语音的场景。
2. [训练音色并获取声音 ID](https://console.volcengine.com/conversational-ai/myVoice/voiceCloning)。
   <span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_ecc579b4ca43d705a0b7c359a9f164d3.png =427x) </span>


**speech_rate ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
语速。取值范围 `[-50, 100]`，取值越大，语速越快。

* `100`：2.0 倍速。
* `-50`：0.5 倍速。
* `0`（默认值）：原语速。



**ResourceId ** <span data-label="purple">String</span> `可选` 示例值：`seed-icl-2.0`
指定要使用的声音复刻大模型服务版本。需要与您在 `voice_type` 中指定的音色版本一致：

* `seed-icl-1.0` ：声音复刻 1.0 字符版
* `seed-icl-2.0`：声音复刻 2.0 字符版


**Additions ** <span data-label="purple">Object</span> `可选` 示例值：`-`
火山引擎声音复刻大模型服务高级配置。

**enable_latex_tn ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
播报 LaTeX 公式。启用后，智能体能够以自然语言朗读文本中的 LaTeX 格式的数学公式。

* `false`（默认值）：不播报。
* `true`：播报。 为`true` 时，`disable_markdown_filter` 也需为 `true` 才生效。

**效果示例：**
```Plain Text
LLM 返回：根据公式 a^2 + b^2 = c^2 可知...
智能体播放：根据公式 a 的平方加上 b 的平方等于 c 的平方 可知...
字幕显示：根据公式 a^2 + b^2 = c^2 可知...
```



**disable_markdown_filter ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
过滤 Markdown 格式。
启用后，语音合成时会自动过滤 LLM 返回文本中的 Markdown 格式符号（如加粗、标题等），确保语音播报的连贯性。

* `false`（默认值）：不过滤。
* `true`：过滤。

**效果示例**：
```Plain Text
LLM 返回：请执行 **grep** 命令查看日志。
智能体播放：请执行 grep 命令查看日志。
字幕显示：请执行 **grep** 命令查看日志。
```



**enable_language_detector ** <span data-label="purple">Boolean</span> `可选` 示例值：`true`
是否自动识别语种。

* `true`：自动识别。
* `false`：不自动识别。

默认值为 `false`。




<span id="minimaxtts"></span>
#### MiniMax 语音合成 <span data-label="purple">Object</span>
使用 MiniMax 语音合成时， `TTSConfig.ProviderParams` 包含以下字段：

**Authorization ** <span data-label="purple">String</span> `可选` 示例值：`eyJhbG****SUzI1N`
API 密钥。前往 [Minimax 账户管理-接口密钥](https://platform.minimaxi.com/login)获取。


**Groupid ** <span data-label="purple">String</span> `可选` 示例值：`983*****669`
用户所属组 ID。前往 [Minimax 账号信息-基本信息](https://platform.minimaxi.com/login)获取。


**model ** <span data-label="purple">String</span> `可选` 示例值：`speech-01-turbo`
发起请求的模型版本：

* `speech-01-turbo`：最新模型，拥有出色的效果与时延表现。
* `speech-01-240228`：稳定版本模型，效果出色。
* `speech-01-turbo-240228`：稳定版本模型，时延更低。


**URL ** <span data-label="purple">String</span> `可选` 示例值：`https://api.minimax.chat/v1/t2a_v2`
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



<span id="thirdpartyttsconfig"></span>
#### 自定义语音合成 <span data-label="purple">Object</span>
使用自定义语音合成时，`TTSConfig.ProviderParams` 包含以下字段：

**URL ** <span data-label="purple">String</span> `可选` 示例值：`wss://ai-gateway.vei.volces.com/v1/realtime?model=ttsname`
:::warning
**配置前，请确保：**

1. 已准备好定义 TTS 接口，并满足[自定义语音合成（TTS）模型接口协议](https://www.volcengine.com/docs/6893/1593361)。
2. 已将定义 TTS 接入到火山边缘智能大模型网关。具体操作，请参见 [调用自部署模型](https://www.volcengine.com/docs/6893/1528786)。

:::
边缘大模型网关的服务接入点 URL。StartVoiceChat 会通过此地址连接到网关，网关再将请求转发给你的定义 TTS 服务。
URL 为固定格式：`wss://ai-gateway.vei.volces.com/v1/realtime?model=<TTS 调用名称>`
其中，<TTS 调用名称\> 需替换为在边缘大模型网关控制台中自定义的模型调用名称，获取路径：[边缘大模型网关_大模型管理](https://console.volcengine.com/vei/aigateway/llm-list)。
<span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_fc7e321f92178ebced9a3bcc4f8e9262.png =589x) </span>


**APIKey ** <span data-label="purple">String</span> `可选` 示例值：`sk-xxxxxx`
网关访问密钥。将自定义模型接入边缘大模型网关时所配置的，获取路径如下：[边缘大模型网关_网关访问密钥](https://console.volcengine.com/vei/aigateway/tokens-list)。
<span>![图片](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_6a5b014e0d9dc3598313f752395af14f.png) </span>


**Voice ** <span data-label="purple">String</span> `可选` 示例值：`-`
音色。填入自定义 TTS 服务所支持的音色名称。


**OutputAudioSpeedRate ** <span data-label="purple">Float</span> `可选` 示例值：`0`
语速。


**OutputAudioVolume ** <span data-label="purple">Float</span> `可选` 示例值：`1.0`
音量。


**OutputAudioPitchRate ** <span data-label="purple">Float</span> `可选` 示例值：`0`
音调。


**ExtraData ** <span data-label="purple">JSONMap</span> `可选` 示例值：`-`
传入自定义参数，将以 JSON 格式透传给你的自定义 TTS 服务。


**ExtraHeader ** <span data-label="purple">JSONMap</span> `可选` 示例值：`-`
自定义透传 Header。一个 JSON 对象，其键值对将作为额外的 HTTP Header 字段，透传到您的自定义 TTS 服务请求中，可用于鉴权或其他自定义逻辑。


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
   * `Chinese,Yue`：粤语。`Chinese,Yue` 仅当 `MiniMaxTTSConfig.model=speech-01-turbo` 时生效。

默认值为空。




**IgnoreBracketText ** <span data-label="purple">String[]</span> `可选` 示例值：`[1,2]`
过滤 LLM 返回内容中指定括号内的文字，再进行语音合成。
适用于过滤 LLM 返回的情绪标记（如“开心”）、动作描写（如“点头”）或场景备注，避免 TTS 将这些辅助信息朗读出来，提升对话的沉浸感。
支持取值（默认为空，表示不过滤）：

* `1`：中文括号 `（）`
* `2`：英文括号 `()`
* `3`：中文方括号 `【】`
* `4`：英文方括号 `[]`
* `5`：英文花括号 `{}`

**使用方法**

* **字段更新说明**：
   * **设置/更新**：传入新取值，将**全量覆盖**旧配置。请同步更新 LLM 的系统提示词，引导大模型将不需要朗读的内容（如心理活动、动作）放入指定的括号中。详细说明，可参见[控制语音播报内容](https://www.volcengine.com/docs/6348/1350596)。
   * **取消过滤**：传入 `null` 或空数组 `[]`。
* **长度限制**：单组括号内的内容长度上限为 500 字符，超出限制的内容将无法被过滤。
* **字幕显示**：一般情况下，被过滤的内容仍会显示在字幕中，但不会被播放。若括号内容位于回复的**最末端**，且被判定为独立句子（其后无其他有效语义），则会显示在字幕中。
   * `...我知无不言！(自信满满）。` → `(自信满满）。`不会显示在字幕中。
   * `...我知无不言（自信满满）！` → `(自信满满）！` 会显示在字幕中。



**InterruptMode ** <span data-label="purple">Integer</span> `可选` 示例值：`0`
是否启用语音打断（发声即打断）：

* `0`：开启。开启后，一旦检测到用户发出声音，智能体立刻停止输出。
* `1`：关闭。关闭后，智能体说话期间，用户语音输入内容会被忽略不做处理，不会打断智能体讲话。

默认值为 `0`。




<span id=".6L-U5Zue5Y-C5pWw"></span>
## 返回参数
本接口无特有的返回参数。公共返回参数请见[返回结构](./1178322)。
其中返回值 `Result` 仅在请求成功时返回 `ok`，失败时为空。
&nbsp;
&nbsp;
