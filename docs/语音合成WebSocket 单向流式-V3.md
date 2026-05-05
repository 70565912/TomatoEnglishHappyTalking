<span id="14e55b8d"></span>
# 语音合成大模型API列表
根据具体场景选择合适的语音合成大模型API。

| | | | | \
|**接口** |**推荐场景** |**接口功能** |**文档链接** |
|---|---|---|---|
| | | | | \
|`wss://openspeech.bytedance.com/api/v3/tts/bidirection ` |WebSocket协议，实时交互场景，支持文本实时流式输入，流式输出音频。 |语音合成、声音复刻、混音 |[V3 WebSocket双向流式文档](https://www.volcengine.com/docs/6561/1329505) |
| | | | | \
|`wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream` |WebSocket协议，一次性输入合成文本，流式输出音频。 |语音合成、声音复刻、混音 |[V3 WebSocket单向流式文档](https://www.volcengine.com/docs/6561/1719100) |
| | | | | \
|`https://openspeech.bytedance.com/api/v3/tts/unidirectional ` |HTTP Chunked协议，一次性输入全部合成文本，流式输出音频。 |语音合成、声音复刻、混音 |[V3 HTTP Chunked单向流式文档](https://www.volcengine.com/docs/6561/1598757?lang=zh#_2-http-chunked%E6%A0%BC%E5%BC%8F%E6%8E%A5%E5%8F%A3%E8%AF%B4%E6%98%8E) |
| | | | | \
|`https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse` |HTTP SSE协议，一次性输入全部合成文本，流式输出音频。 |语音合成、声音复刻、混音 |[V3 Server Sent Events（SSE）单向流式文档](https://www.volcengine.com/docs/6561/1598757?lang=zh#_3-sse%E6%A0%BC%E5%BC%8F%E6%8E%A5%E5%8F%A3%E8%AF%B4%E6%98%8E) |

<span id="e27cb745"></span>
# 1 接口功能
单向流式API为用户提供文本转语音的能力，支持多语种、多方言，同时支持WebSocket协议流式输出。
<span id="7b9267e4"></span>
## 1.1 最佳实践
推荐使用链接复用，可降低耗时约70ms左右。
对比v1单向流式接口，不同的音色优化程度不同，以具体测试结果为准，理论上相对会有几十ms的提升。
<span id="cbd635a6"></span>
# 2 接口说明
<span id="ebc43a76"></span>
## 2.1 请求Request
<span id="879dd657"></span>
### 请求路径
`wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream`
<span id="b4537ed1"></span>
### 建连&鉴权
<span id="7d2a2880"></span>
#### 鉴权Request Headers
在 websocket 建连的 HTTP 请求头（Request Header 中）添加以下信息
使用[新版控制台](https://console.volcengine.com/speech/new)时，推荐采用以下更简化的鉴权方式。

| | | | | | \
|Key |说明 |参数类型 |是否必须 |Value示例 |
|---|---|---|---|---|
| | | | | | \
|X-Api-Key |使用火山引擎控制台获取的API Key，可参考 [控制台API Key管理](https://www.volcengine.com/docs/6561/2119699?lang=zh#ew1HctnP) |string |必须 |"your-api-key" |
| | | | | | \
|X-Api-Resource-Id |\
| |表示调用服务的资源信息 ID，可以用来选择不同的模型版本效果，也决定了计费方式。 |\
| | |string |必须 |**豆包语音合成大模型** |\
| | | | |语音合成接口通过 `X-Api-Resource-Id` 参数来选择不同的版本效果： |\
| | | | | |\
| | | | |* `seed-tts-2.0`仅支持调用["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544?lang=zh#%E8%B1%86%E5%8C%85%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90%E6%A8%A1%E5%9E%8B2-0-%E9%9F%B3%E8%89%B2%E5%88%97%E8%A1%A8) |\
| | | | |* `seed-tts-1.0` / `seed-tts-1.0-concurr`仅支持调用["豆包语音合成模型1.0"的音色](https://www.volcengine.com/docs/6561/1257544?lang=zh#%E8%B1%86%E5%8C%85%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90%E6%A8%A1%E5%9E%8B1-0-%E9%9F%B3%E8%89%B2%E5%88%97%E8%A1%A8) |\
| | | | | |\
| | | | |同时，`X-Api-Resource-Id` 也决定了计费方式： |\
| | | | | |\
| | | | |* `seed-tts-2.0`：对应计费商品为 “语音合成2.0字符版“ |\
| | | | |* `seed-tts-1.0`：对应计费商品为“语音合成1.0字符版” |\
| | | | |* `seed-tts-1.0-concurr`：对应计费商品为“语音合成1.0并发版“ |\
| | | | | |\
| | | | |**豆包声音复刻大模型** |\
| | | | |语音合成接口通过 `X-Api-Resource-Id` 参数来选择不同的版本效果： |\
| | | | | |\
| | | | |* `seed-icl-2.0`：对应声音复刻2.0 版本效果 |\
| | | | |* `seed-icl-1.0` / `seed-icl-1.0-concurr`：对应声音复刻1.0 版本效果 |\
| | | | | |\
| | | | |同时，`X-Api-Resource-Id` 也决定了计费方式： |\
| | | | | |\
| | | | |* `seed-icl-2.0`：对应计费商品为“声音复刻2.0 字符版” |\
| | | | |* `seed-icl-1.0`：对应计费商品为“声音复刻1.0 字符版” |\
| | | | |* `seed-icl-1.0-concurr`：对应计费商品为“声音复刻1.0 并发版” |
| | | | | | \
|X-Api-Request-Id |标识客户端请求ID，uuid随机字符串 |string |可选 |“67ee89ba-7050-4c04-a3d7-ac61a63499b3” |

```Python
headers = {
    "X-Api-Key": "your-api-key",
    "X-Api-Resource-Id": "seed-tts-2.0"
}
```

若使用[旧版控制台](https://console.volcengine.com/speech/app)，鉴权方式如下。建议尽快切换至新版，以体验更便捷的鉴权流程。

| | | | | | \
|Key |说明 |参数类型 |是否必须 |Value示例 |
|---|---|---|---|---|
| | | | | | \
|X-Api-App-Id |\
| |使用火山引擎控制台获取的APP ID，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)（旧版控制台使用，新版控制台只需要X-Api-Key即可） |string |必须 |\
| | | | |“123456789” |\
| | | | | |
| | | | | | \
|X-Api-Access-Key |\
| |使用火山引擎控制台获取的Access Token，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)（旧版控制台使用，新版控制台只需要X-Api-Key即可） |string |必须 |\
| | | | |“your-access-key” |\
| | | | | |
| | | | | | \
|X-Api-Resource-Id |\
| |表示调用服务的资源信息 ID，可以用来选择不同的模型版本效果，也决定了计费方式。 |\
| | |string |必须 |\
| | | | |**豆包语音合成大模型** |\
| | | | |语音合成接口通过 `X-Api-Resource-Id` 参数来选择不同的版本效果： |\
| | | | | |\
| | | | |* `seed-tts-2.0`仅支持调用["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544?lang=zh#%E8%B1%86%E5%8C%85%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90%E6%A8%A1%E5%9E%8B2-0-%E9%9F%B3%E8%89%B2%E5%88%97%E8%A1%A8) |\
| | | | |* `seed-tts-1.0` / `seed-tts-1.0-concurr`仅支持调用["豆包语音合成模型1.0"的音色](https://www.volcengine.com/docs/6561/1257544?lang=zh#%E8%B1%86%E5%8C%85%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90%E6%A8%A1%E5%9E%8B1-0-%E9%9F%B3%E8%89%B2%E5%88%97%E8%A1%A8) |\
| | | | | |\
| | | | |同时，`X-Api-Resource-Id` 也决定了计费方式： |\
| | | | | |\
| | | | |* `seed-tts-2.0`：对应计费商品为 “语音合成2.0字符版“ |\
| | | | |* `seed-tts-1.0`：对应计费商品为“语音合成1.0字符版” |\
| | | | |* `seed-tts-1.0-concurr`：对应计费商品为“语音合成1.0并发版“ |\
| | | | | |\
| | | | |**豆包声音复刻大模型** |\
| | | | |语音合成接口通过 `X-Api-Resource-Id` 参数来选择不同的版本效果： |\
| | | | | |\
| | | | |* `seed-icl-2.0`：对应声音复刻2.0 版本效果 |\
| | | | |* `seed-icl-1.0` / `seed-icl-1.0-concurr`：对应声音复刻1.0 版本效果 |\
| | | | | |\
| | | | |同时，`X-Api-Resource-Id` 也决定了计费方式： |\
| | | | | |\
| | | | |* `seed-icl-2.0`：对应计费商品为“声音复刻2.0 字符版” |\
| | | | |* `seed-icl-1.0`：对应计费商品为“声音复刻1.0 字符版” |\
| | | | |* `seed-icl-1.0-concurr`：对应计费商品为“声音复刻1.0 并发版” |
| | | | | | \
|X-Api-Request-Id |标识客户端请求ID，uuid随机字符串 |string |可选 |“67ee89ba-7050-4c04-a3d7-ac61a63499b3” |

```Python
headers = {
    "X-Api-App-Id": "123456789",
    "X-Api-Access-Key": "your-access-key",
    "X-Api-Resource-Id": "seed-tts-2.0"
}
```

<span id="13810a23"></span>
### 额外Request Headers

| | | | | \
|Key |说明 |是否必须 |Value示例 |
|---|---|---|---|
| | | | | \
|X-Control-Require-Usage-Tokens-Return |请求消耗的用量返回控制标记。当携带此字段，在SessionFinish事件（152）中会携带用量数据 |否 |* 设置为*，表示返回已支持的用量数据。 |\
| | | |* 也设置为具体的用量数据标记，如text_words；多个用逗号分隔 |\
| | | |* 当前已支持的用量数据 |\
| | | |   * text_words，表示计费字符数 |

<span id="eb9333bb"></span>
### Response Headers
在 websocket 握手成功后，会返回这些 Response header

| | | | \
|Key |说明 |Value示例 |
|---|---|---|
| | | | \
|X-Tt-Logid |服务端返回的 logid，建议用户获取和打印方便定位问题 |2025041513355271DF5CF1A0AE0508E78C |

<span id="1ed7c9ef"></span>
### WebSocket 二进制协议
WebSocket 使用二进制协议传输数据。
协议的组成由至少 4 个字节的可变 header、payload size 和 payload 三部分组成，其中

* header 描述消息类型、序列化方式以及压缩格式等信息；
* payload size 是 payload 的长度；
* payload 是具体负载内容，依据消息类型不同 payload 内容不同；

需注意：协议中整数类型的字段都使用**大端**表示。
<span id="10007f84"></span>
##### 二进制帧

| | | | | \
|Byte |Left 4-bit |Right 4-bit |说明 |
|---|---|---|---|
| | | | | \
|0 - Left half |Protocol version | |目前只有v1，始终填0b0001 |
| | | | | \
|0 - Right half | |Header size (4x) |目前只有4字节，始终填0b0001 |
| | | | | \
|1 - Left half |Message type | |固定为0b001 |
| | | | | \
|1 - Right half | |Message type specific flags |在sendText时，为0 |\
| | | |在finishConnection时，为0b100 |
| | | | | \
|2 - Left half |Serialization method | |0b0000：Raw（无特殊序列化方式，主要针对二进制音频数据）0b0001：JSON（主要针对文本类型消息） |
| | | | | \
|2 - Right half | |Compression method |0b0000：无压缩0b0001：gzip |
| | || | \
|3 |Reserved | |留空（0b0000 0000） |
| | || | \
|[4 ~ 7] |[Optional field,like event number,...] | |取决于Message type specific flags，可能有、也可能没有 |
| | || | \
|... |Payload | |可能是音频数据、文本数据、音频文本混合数据 |

<span id="e09e1c0e"></span>
###### payload请求参数

| | | | | | \
|字段 |描述 |是否必须 |类型 |默认值 |
|---|---|---|---|---|
| | | | | | \
|user |用户信息 | | | |
| | | | | | \
|user.uid |用户uid | | | |
| | | | | | \
|event |请求的事件 | | | |
| | | | | | \
|namespace |请求方法 | |string |BidirectionalTTS |
| | | | | | \
|req_params.text |输入文本 | |string | |
| | | | | | \
|req_params.model |\
| |模型版本，传`seed-tts-1.1`较默认版本音质有提升，并且延时更优，不传为默认效果。 |\
| |注：若使用1.1模型效果，在复刻场景中会放大训练音频prompt特质，因此对prompt的要求更高，使用高质量的训练音频，可以获得更优的音质效果。 |\
| | |\
| |以下参数仅针对声音复刻2.0的音色生效，即音色ID的前缀为`saturn_`的音色。音色的取值为以下两种： |\
| | |\
| |* `seed-tts-2.0-expressive`：表现力较强，支持QA和Cot能力，不过可能存在抽卡的情况。 |\
| |* `seed-tts-2.0-standard`：表现力上更加稳定，但是不支持QA和Cot能力。如果此时使用QA或Cot能力，则拒绝请求。 |\
| |* 如果不传model参数，默认使用`seed-tts-2.0-expressive`模型。 | |string |\
| | | | | |
| | | | | | \
|req_params.ssml |* 当文本格式是ssml时，需要将文本赋值为ssml，此时文本处理的优先级高于text。ssml和text字段，至少有一个不为空 |\
| |* 当req_params.speaker 为["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544) 或者 豆包声音复刻模型2.0（icl 2.0）的音色时，req_params.additions.disable_markdown_filte 不可以设置为true; | |string | |
| | | | | | \
|req_params.speaker |发音人，具体见[发音人列表](https://www.volcengine.com/docs/6561/1257544) |√ |string | |
| | | | | | \
|req_params.audio_params |音频参数，便于服务节省音频解码耗时 |√ |object | |
| | | | | | \
|req_params.audio_params.format |音频编码格式，mp3/ogg_opus/pcm。<span style="background-color: rgba(255,233,40, 0.96)">接口传入wav并不会报错，在流式场景下传入wav会多次返回wav header，这种场景建议使用pcm。</span> | |string |mp3 |
| | | | | | \
|req_params.audio_params.sample_rate |音频采样率，可选值 [8000,16000,22050,24000,32000,44100,48000] | |number |24000 |
| | | | | | \
|req_params.audio_params.bit_rate |音频比特率，可传16000、32000等。 |\
| |bit_rate默认设置范围为64k～160k，传了disable_default_bit_rate为true后可以设置到64k以下 |\
| |GoLang示例：additions = fmt.Sprintf("{"disable_default_bit_rate":true}") |\
| |注：bit_rate只针对MP3格式，wav计算比特率跟pcm一样是 比特率 (bps) = 采样率 × 位深度 × 声道数 |\
| |目前大模型TTS只能改采样率，所以对于wav格式来说只能通过改采样率来变更音频的比特率 | |number | |
| | | | | | \
|req_params.audio_params.emotion |设置音色的情感。示例："emotion": "angry" |\
| |注：当前仅部分音色支持设置情感，且不同音色支持的情感范围存在不同。 |\
| |详见：[大模型语音合成API-音色列表-多情感音色](https://www.volcengine.com/docs/6561/1257544) | |string | |
| | | | | | \
|req_params.audio_params.emotion_scale |调用emotion设置情感参数后可使用emotion_scale进一步设置情绪值，范围1~5，不设置时默认值为4。 |\
| |注：理论上情绪值越大，情感越明显。但情绪值1~5实际为非线性增长，可能存在超过某个值后，情绪增加不明显，例如设置3和5时情绪值可能接近。 | |number |4 |
| | | | | | \
|req_params.audio_params.speech_rate |语速，取值范围[-50,100]，100代表2.0倍速，-50代表0.5倍数 | |number |0 |
| | | | | | \
|req_params.audio_params.loudness_rate |音量，取值范围[-50,100]，100代表2.0倍音量，-50代表0.5倍音量（mix音色暂不支持） | |number |0 |
| | | | | | \
|req_params.audio_params.enable_timestamp |设置 "enable_timestamp": true 返回句级别字的时间戳（默认为 false，参数传入 true 即表示启用） |\
| |开启后，在原有返回的事件`event=TTSSentenceEnd`中，新增该子句的时间戳信息。 |\
| | |\
| |* 一个子句的时间戳返回之后才会开始返回下一句音频。 |\
| |* 合成有多个子句会多次返回`TTSSentenceStart`和`TTSSentenceEnd`。开启字幕后字幕跟随`TTSSentenceEnd`返回。 |\
| |* 字/词粒度的时间戳，其中字/词是tn。具体可以看下面的例子。 |\
| |* 支持中、英，其他语种、方言暂时不支持。 |\
| | |\
| |注：该参数只在TTS1.0(["豆包语音合成模型1.0"的音色](https://www.volcengine.com/docs/6561/1257544))、ICL1.0生效。 | |bool |false |
| | | | | | \
|req_params.audio_params.enable_subtitle |设置 "enable_subtitle": true 返回句级别字的时间戳（默认为 false，参数传入 true 即表示启用） |\
| |开启后，新增返回事件`event=TTSSubtitle`，包含字幕信息。 |\
| | |\
| |* 在一句音频合成之后，不会立即返回该句的字幕。合成进度不会被字幕识别阻塞，当一句的字幕识别完成后立即返回。可能一个子句的字幕返回的时候，已经返回下一句的音频帧给调用方了。 |\
| |* 合成有多个子句，仅返回一次`TTSSentenceStart`和`TTSSentenceEnd`。开启字幕后会多次返回`TTSSubtitle`。 |\
| |* 字/词粒度的时间戳，其中字/词是原文。具体可以看下面的例子。 |\
| |* 支持中、英，其他语种、方言暂时不支持； |\
| |* latex公式不支持 |\
| |   * req_params.additions.enable_latex_tn为true时，不开启字幕识别功能，即不返回字幕； |\
| |* ssml不支持 |\
| |   * req_params.ssml 不传时，不开启字幕识别功能，即不返回字幕； |\
| | |\
| |注：该参数只在TTS2.0、ICL2.0生效。 | |bool |false |
| | | | | | \
|req_params.additions |用户自定义参数 | |jsonstring | |
| | | | | | \
|req_params.additions.silence_duration |设置该参数可在句尾增加静音时长，范围0~30000ms。（注：增加的句尾静音主要针对传入文本最后的句尾，而非每句话的句尾） | |number |0 |
| | | | | | \
|req_params.additions.enable_language_detector |自动识别语种 | |bool |false |
| | | | | | \
|req_params.additions.disable_markdown_filter |是否开启markdown解析过滤， |\
| |为true时，解析并过滤markdown语法，例如，`**你好**`，会读为“你好”， |\
| |为false时，不解析不过滤，例如，`**你好**`，会读为“星星‘你好’星星” | |bool |false |
| | | | | | \
|req_params.additions.disable_emoji_filter |开启emoji表情在文本中不过滤显示，默认为false，建议搭配时间戳参数一起使用。 |\
| |GoLang示例：`additions = fmt.Sprintf("{"disable_emoji_filter":true}")` | |bool |false |
| | | | | | \
|req_params.additions.mute_cut_remain_ms |该参数需配合mute_cut_threshold参数一起使用，其中： |\
| |"mute_cut_threshold": "400", // 静音判断的阈值（音量小于该值时判定为静音） |\
| |"mute_cut_remain_ms": "50", // 需要保留的静音长度 |\
| |注：参数和value都为string格式 |\
| |Golang示例：`additions = fmt.Sprintf("{"mute_cut_threshold":"400", "mute_cut_remain_ms": "1"}")` |\
| |特别提醒： |\
| | |\
| |* 因MP3格式的特殊性，句首始终会存在100ms内的静音无法消除，WAV格式的音频句首静音可全部消除，建议依照自身业务需求综合判断选择 |\
| |* ["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544) 暂不支持 |\
| |* 豆包声音复刻模型2.0（icl 2.0）的音色暂不支持 | |string | |
| | | | | | \
|req_params.additions.enable_latex_tn |是否可以播报latex公式，需将disable_markdown_filter设为true | |bool |false |
| | | | | | \
|req_params.additions.latex_parser |是否使用lid 能力播报latex公式，相较于latex_tn 效果更好； |\
| |值为“v2”时支持lid能力解析公式，值为“”时不支持lid； |\
| |需同时将disable_markdown_filter设为true； | |string | |
| | | | | | \
|req_params.additions.max_length_to_filter_parenthesis |是否过滤括号内的部分，0为不过滤，100为过滤 | |int |100 |
| | | | | | \
|req_params.additions.explicit_language（明确语种） |仅读指定语种的文本 |\
| |**精品音色和 声音复刻 ICL1.0场景：** |\
| | |\
| |* 不给定参数，正常中英混 |\
| |* `crosslingual` 启用多语种前端（包含`zh/en/ja/es-mx/id/pt-br`） |\
| |* `zh-cn` 中文为主，支持中英混  |\
| |* `en` 仅英文 |\
| |* `ja` 仅日文 |\
| |* `es-mx` 仅墨西 |\
| |* `id` 仅印尼 |\
| |* `pt-br` 仅巴葡 |\
| | |\
| |**DIT 声音复刻场景：** |\
| |当音色是使用model_type=2训练的，即采用dit标准版效果时，建议指定明确语种，目前支持： |\
| | |\
| |* 不给定参数，启用多语种前端`zh,en,ja,es-mx,id,pt-br,de,fr` |\
| |* `zh,en,ja,es-mx,id,pt-br,de,fr` 启用多语种前端 |\
| |* `zh-cn` 中文为主，支持中英混  |\
| |* `en` 仅英文 |\
| |* `ja` 仅日文 |\
| |* `es-mx` 仅墨西 |\
| |* `id` 仅印尼 |\
| |* `pt-br` 仅巴葡 |\
| |* `de` 仅德语 |\
| |* `fr` 仅法语 |\
| | |\
| |当音色是使用model_type=3训练的，即采用dit还原版效果时，必须指定明确语种，目前支持： |\
| | |\
| |* 不给定参数，正常中英混 |\
| |* `zh-cn` 中文为主，支持中英混  |\
| |* `en` 仅英文 |\
| | |\
| |**声音复刻 ICL2.0场景：** |\
| |当音色是使用model_type=4训练的 |\
| | |\
| |* 不给定参数，正常中英混 |\
| |* `zh-cn` 中文为主，支持中英混  |\
| |* `en` 仅英文 |\
| | |\
| |GoLang示例：`additions = fmt.Sprintf("{"explicit_language": "zh"}")` | |string | |
| | | | | | \
|req_params.additions.context_language（参考语种） |给模型提供参考的语种 |\
| | |\
| |* 不给定 西欧语种采用英语 |\
| |* id 西欧语种采用印尼 |\
| |* es 西欧语种采用墨西 |\
| |* pt 西欧语种采用巴葡 | |string | |
| | | | | | \
|req_params.additions.explicit_dialect |\
|（明确方言） |\
| |明确方言，目前仅`zh_female_vv_uranus_bigtts`音色支持以下三种方言： |\
| | |\
| |* dongbei（东北话） |\
| |* shaanxi（陕西话） |\
| |* sichuan（四川话） |\
| | |\
| |参数情况举例说明： |\
| | |\
| |1. speaker_id = `zh_female_xiaohe_uranus_bigtts`，explicit_language不传，explicit_dialect=dongbei，则报参数错误，即语种和方言不对应 |\
| |2. speaker_id =`zh_female_vv_uranus_bigtts`，explicit_language不传，explicit_dialect=dongbei，则正常完成东北方言的合成 |\
| |3. speaker_id = `zh_female_vv_uranus_bigtts`，explicit_language=ja，explicit_dialect=dongbei，则报参数错误，即语种和方言不对应 |\
| |4. speaker_id = `zh_female_vv_uranus_bigtts`，explicit_language=ja，explicit_dialect不传，则按照语种正常合成 | |string | |
| | | | | | \
|req_params.additions.unsupported_char_ratio_thresh |默认: 0.3，最大值: 1.0 |\
| |检测出不支持合成的文本超过设置的比例，则会返回错误。 | |float |0.3 |
| | | | | | \
|req_params.additions.aigc_watermark |默认：false |\
| |是否在合成结尾增加音频节奏标识 | |bool |false |
| | | | | | \
|req_params.additions.aigc_metadata （meta 水印） |在合成音频 header加入元数据隐式表示，支持 mp3/wav/ogg_opus | |object | |
| | | | | | \
|req_params.additions.aigc_metadata.enable |是否启用隐式水印 | |bool |false |
| | | | | | \
|req_params.additions.aigc_metadata.content_producer |合成服务提供者的名称或编码 | |string |"" |
| | | | | | \
|req_params.additions.aigc_metadata.produce_id |内容制作编号 | |string |"" |
| | | | | | \
|req_params.additions.aigc_metadata.content_propagator |内容传播服务提供者的名称或编码 | |string |"" |
| | | | | | \
|req_params.additions.aigc_metadata.propagate_id |内容传播编号 | |string |"" |
| | | | | | \
|req_params.additions.cache_config（缓存相关参数） |开启缓存，开启后合成相同文本时，服务会直接读取缓存返回上一次合成该文本的音频，可明显加快相同文本的合成速率，缓存数据保留时间1小时。 |\
| |（通过缓存返回的数据不会附带时间戳） |\
| |Golang示例：`additions = fmt.Sprintf("{"disable_default_bit_rate":true, "cache_config": {"text_type": 1,"use_cache": true}}")` | |object | |
| | | | | | \
|req_params.additions.cache_config.text_type（缓存相关参数） |和use_cache参数一起使用，需要开启缓存时传1 | |int |1 |
| | | | | | \
|req_params.additions.cache_config.use_cache（缓存相关参数） |和text_type参数一起使用，需要开启缓存时传true | |bool |true |
| | | | | | \
|req_params.additions.post_process |后处理配置 |\
| |Golang示例：`additions = fmt.Sprintf("{"post_process":{"pitch":12}}")` | |object | |
| | | | | | \
|req_params.additions.post_process.pitch |音调取值范围是[-12,12] | |int |\
| | | | |0 |
| | | | | | \
|req_params.additions.context_texts |\
|([仅TTS2.0支持](https://www.volcengine.com/docs/6561/1257544)) |语音合成的辅助信息，用于模型对话式合成，能更好的体现语音情感； |\
| |可以探索，比如常见示例有以下几种： |\
| | |\
| |1. 语速调整 |\
| |   1. 比如：context_texts: ["你可以说慢一点吗？"] |\
| |2. 情绪/语气调整 |\
| |   1. 比如：context_texts=["你可以用特别特别痛心的语气说话吗?"] |\
| |   2. 比如：context_texts=["嗯，你的语气再欢乐一点"] |\
| |3. 音量调整 |\
| |   1. 比如：context_texts=["你嗓门再小点。"] |\
| |4. 音感调整 |\
| |   1. 比如：context_texts=["你能用骄傲的语气来说话吗？"] |\
| | |\
| |注意： |\
| | |\
| |1. 该字段仅适用于["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544) |\
| |2. 当前字符串列表只第一个值有效 |\
| |3. 该字段文本不参与计费 | |string list |null |
| | | | | | \
|req_params.additions.section_id |\
|([仅TTS2.0支持](https://www.volcengine.com/docs/6561/1257544)) |其他合成语音的会话id(session_id)，用于辅助当前语音合成，提供更多的上下文信息； |\
| |取值，参见接口交互中的session_id |\
| |示例： |\
| | |\
| |1. section_id="bf5b5771-31cd-4f7a-b30c-f4ddcbf2f9da" |\
| | |\
| |注意： |\
| | |\
| |1. 该字段仅适用于["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544) |\
| |2. 历史上下文的session_id 有效期： |\
| |   1. 最长30轮 |\
| |   2. 最长10分钟 | |string |"" |
| | | | | | \
|req_params.additions.use_tag_parser |是否开启cot解析能力。cot能力可以辅助当前语音合成，对语速、情感等进行调整。 |\
| |注意： |\
| | |\
| |1. 音色支持范围：仅限声音复刻2.0复刻的音色 |\
| |2. 文本长度：单句的text字符长度最好小于64（cot标签也计算在内） |\
| |3. cot能力生效的范围是单句 |\
| | |\
| |示例： |\
| |支持单组和多组cot标签：`<cot text=急促难耐>工作占据了生活的绝大部分</cot>，只有去做自己认为伟大的工作，才能获得满足感。<cot text=语速缓慢>不管生活再苦再累，都绝不放弃寻找</cot>。` | |bool |false |
| | | | | | \
|[]req_params.mix_speaker |混音参数结构 |\
| |注意： |\
| | |\
| |1. 该字段仅适用于["豆包语音合成模型1.0"的音色](https://www.volcengine.com/docs/6561/1257544) | |object | |
| | | | | | \
|req_params.mix_speaker.speakers |混音音色名以及影响因子列表 |\
| |注意： |\
| | |\
| |1. 最多支持3个音色混音 |\
| |2. 音色风格差异较大的两个音色（如男女混），以0.5-0.5同等比例混合时，可能出现偶发跳变，建议尽量避免 |\
| |3. 使用Mix能力时，req_params.speaker = custom_mix_bigtts | |list |null |
| | | | | | \
|req_params.mix_speaker.speakers[i].source_speaker |混音源音色名 |\
| |注意： |\
| | |\
| |1. 支持["豆包语音合成模型1.0"的音色](https://www.volcengine.com/docs/6561/1257544)、["语音合成（小模型）"的音色](https://www.volcengine.com/docs/6561/97465?lang=zh)、声音复刻大模型的音色 |\
| |2. 使用声音复刻大模型音色时，使用`S_`开头的`speakerid`，或者使用查询接口获取的`icl_`的`speakerid`，不支持`DiT_`或者 `saturn_`开头的`speakerid` | |string |"" |
| | | | | | \
|req_params.mix_speaker.speakers[i].mix_factor |混音源音色名影响因子 |\
| |注意： |\
| | |\
| |1. 混音影响因子和必须=1 | |float |0 |

单音色请求参数示例：
```JSON
{
    "user": {
        "uid": "12345"
    },
    "req_params": {
        "text": "明朝开国皇帝朱元璋也称这本书为,万物之根",
        "speaker": "zh_female_shuangkuaisisi_moon_bigtts",
        "audio_params": {
            "format": "mp3",
            "sample_rate": 24000
        },
      }
    }
}
```

mix请求参数示例：
```JSON
{
    "user": {
        "uid": "12345"
    },
    "req_params": {
        "text": "明朝开国皇帝朱元璋也称这本书为万物之根",
        "speaker": "custom_mix_bigtts",
        "audio_params": {
            "format": "mp3",
            "sample_rate": 24000
        },
        "mix_speaker": {
            "speakers": [{
                "source_speaker": "zh_male_bvlazysheep",
                "mix_factor": 0.3
            }, {
                "source_speaker": "BV120_streaming",
                "mix_factor": 0.3
            }, {
                "source_speaker": "zh_male_ahu_conversation_wvae_bigtts",
                "mix_factor": 0.4
            }]
        }
    }
}
```

<span id="7196a9df"></span>
## 2.2 响应Response
<span id="4272eb93"></span>
### 建连响应
主要关注建连阶段 HTTP Response 的状态码和 Body

* 建连成功：状态码为 200
* 建连失败：状态码不为 200，Body 中提供错误原因说明

<span id="2d7a5370"></span>
### WebSocket 传输响应
<span id="141caac4"></span>
#### 二进制帧 - 正常响应帧

| | | | | \
|Byte |Left 4-bit |Right 4-bit |说明 |
|---|---|---|---|
| | | | | \
|0 - Left half |Protocol version | |目前只有v1，始终填0b0001 |
| | | | | \
|0 - Right half | |Header size (4x) |目前只有4字节，始终填0b0001 |
| | | | | \
|1 - Left half |Message type | |音频帧返回：0b1011 |\
| | | |其他帧返回：0b1001 |
| | | | | \
|1 - Right half | |Message type specific flags |固定为0b0100 |
| | | | | \
|2 - Left half |Serialization method | |0b0000：Raw（无特殊序列化方式，主要针对二进制音频数据）0b0001：JSON（主要针对文本类型消息） |
| | | | | \
|2 - Right half | |Compression method |0b0000：无压缩0b0001：gzip |
| | || | \
|3 |Reserved | |留空（0b0000 0000） |
| | || | \
|[4 ~ 7] |[Optional field,like event number,...] |\
| | | |取决于Message type specific flags，可能有、也可能没有 |
| | || | \
|... |Payload | |可能是音频数据、文本数据、音频文本混合数据 |

<span id="c7404398"></span>
##### payload响应参数

| | | | \
|字段 |描述 |类型 |
|---|---|---|
| | | | \
|data |返回的二进制数据包 |[]byte |
| | | | \
|event |返回的事件类型 |number |
| | | | \
|res_params.text |经文本分句后的句子 |string |

<span id="65eb0f21"></span>
#### 二进制帧 - 错误响应帧

| | | | | \
|Byte |Left 4-bit |Right 4-bit |说明 |
|---|---|---|---|
| | | | | \
|0 - Left half |Protocol version | |目前只有v1，始终填0b0001 |
| | | | | \
|0 - Right half | |Header size (4x) |目前只有4字节，始终填0b0001 |
| | | | | \
|1  |Message type |Message type specific flags |0b11110000 |
| | | | | \
|2 - Left half |Serialization method | |0b0000：Raw（无特殊序列化方式，主要针对二进制音频数据）0b0001：JSON（主要针对文本类型消息） |
| | | | | \
|2 - Right half | |Compression method |0b0000：无压缩0b0001：gzip |
| | || | \
|3 |Reserved | |留空（0b0000 0000） |
| | || | \
|[4 ~ 7] |Error code | |错误码 |
| | || | \
|... |Payload | |错误消息对象 |

<span id="37909556"></span>
## 2.3 event定义
在发送文本转TTS阶段，不需要客户端发送上行的event帧。event类型如下：

| | | | | \
|Event code |含义 |事件类型 |应用阶段：上行/下行 |
|---|---|---|---|
| | | | | \
|152 |SessionFinished，会话已结束（上行&下行） |\
| |标识语音一个完整的语音合成完成 |Session 类 |下行 |
| | | | | \
|350 |TTSSentenceStart，TTS 返回句内容开始 |数据类 |下行 |
| | | | | \
|351 |TTSSentenceEnd，TTS 返回句内容结束 |数据类 |下行 |
| | | | | \
|352 |TTSResponse，TTS 返回句的音频内容 |数据类 |下行 |

在关闭连接阶段，需要客户端传递上行event帧去关闭连接。event类型如下：

| | | | | \
|Event code |含义 |事件类型 |应用阶段：上行/下行 |
|---|---|---|---|
| | | | | \
|2 |FinishConnection，结束连接 |Connect 类 |上行 |
| | | | | \
|52 |ConnectionFinished 结束连接成功 |Connect 类 |下行 |

交互示例：
![Image](https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/a9005d7ddd564ad79ad6dda9699a4a65~tplv-goo7wpa0wc-image.image =419x)
<span id="71e5b133"></span>
## 2.4 不同类型帧举例说明
<span id="109f8def"></span>
### SendText
<span id="3544c657"></span>
#### 请求Request

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |0001 |0000 |Full-client request |with no event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || || \
|4 ~ 7 |uint32(...) | |len(payload_json) | |
| | || || \
|8 ~ ... |\
| |{...} |\
| | | |文本 |\
| | | | | |

payload
```JSON
{
    "user": {
        "uid": "12345"
    },
    "req_params": {
        "text": "明朝开国皇帝朱元璋也称这本书为,万物之根",
        "speaker": "zh_female_shuangkuaisisi_moon_bigtts",
        "audio_params": {
            "format": "mp3",
            "sample_rate": 24000
        },
      }
    }
}
```

<span id="9b307cb7"></span>
#### 响应Response
<span id="683ea12d"></span>
##### TTSSentenceStart

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |1001 |0100 |Full-client request |with event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || || \
|4 ~ 7 |TTSSentenceStart | |event type | |
| | || || \
|8 ~ 11 |uint32(12) | |len(<session_id>) | |
| | || || \
|12 ~ 23 |nxckjoejnkegf | |session_id | |
| | || || \
|24 ~ 27 |uint32( ...) | |len(text_binary) | |
| | || || \
|28 ~ ... |\
| |{...} | |text_binary | |

<span id="3da131c9"></span>
##### TTSResponse

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |1011 |0100 |Audio-only response |with event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || | | \
|4 ~ 7 |TTSResponse | |event type | |
| | || | | \
|8 ~ 11 |uint32(12) | |len(<session_id>) | |
| | || | | \
|12 ~ 23 |nxckjoejnkegf | |session_id | |
| | || | | \
|24 ~ 27 |uint32( ...) | |len(audio_binary) | |
| | || | | \
|28 ~ ... |{...} |\
| | | |audio_binary |\
| | | | | |

<span id="edc35acf"></span>
##### TTSSentenceEnd

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |1001 |0100 |Full-client request |with event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || || \
|4 ~ 7 |TTSSentenceEnd | |event type | |
| | || || \
|8 ~ 11 |uint32(12) | |len(<session_id>) | |
| | || || \
|12 ~ 23 |nxckjoejnkegf | |session_id | |
| | || || \
|24 ~ 27 |uint32( ...) | |len(payload) | |
| | || || \
|28 ~ ... |{...} |\
| | | |payload |\
| | | | | |

<span id="04a1a1b7"></span>
##### SessionFinished

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |1001 |0100 |Full-client request |with event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || | | \
|4 ~ 7 |SessionFinished | |event type | |
| | || || \
|8 ~ 11 |uint32(12) | |len(<session_id>) | |
| | || || \
|12 ~ 23 |nxckjoejnkegf | |session_id | |
| | || || \
|24 ~ 27 |uint32( ...) | |len(response_meta_json) | |
| | || || \
|28 ~ ... |{ |\
| | "status_code": 20000000, |\
| | "message": "ok"， |\
| |"usage": { |\
| |        "text_words"：4 |\
| |    } |\
| |} |\
| | | |response_meta_json |\
| | | | |\
| | | |* 仅含status_code和message字段 |\
| | | |* usage仅当header中携带X-Control-Require-Usage-Tokens-Return存在 | |

<span id="c2620002"></span>
#### FinishConnection
<span id="7b009499"></span>
##### 请求request

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |0001 |0100 |Full-client request |with event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || || \
|4-7 |uint32(...) | |len(payload_json) | |
| | || || \
|8 ~ ... |\
| |{...} |\
| | | |payload_json |\
| | | |扩展保留，暂留空JSON | |

<span id="9b812c2d"></span>
##### 响应response

| | | | || \
|Byte |Left 4-bit |Right 4-bit |说明 | |
|---|---|---|---|---|
| | | | | | \
|0 |0001 |0001 |v1 |4-byte header |
| | | | | | \
|1 |1001 |0100 |Full-client request |with event number |
| | | | | | \
|2 |0001 |0000 |JSON |no compression |
| | | | | | \
|3 |0000 |0000 | | |
| | || || \
|4 ~ 7 |ConnectionFinished | |event type | |
| | || || \
|8 ~ 11 |uint32(7) | |len(<connection_id>) | |
| | || || \
|12 ~ 15 |uint32(58) | |len(<response_meta_json>) | |
| | || || \
|28 ~ ... |{ |\
| | "status_code": 20000000, |\
| | "message": "ok" |\
| |} | |response_meta_json |\
| | | | |\
| | | |* 仅含status_code和message字段 |\
| | | | |\
| | | | | |

<span id="89bf6f66"></span>
## 2.5 时间戳句子格式说明

| | | | \
| |\
|<span id="532996f7"></span> |\
|#  |**TTS1.0** |\
| |**ICL1.0** |**TTS2.0** |\
| | |**ICL2.0** |
|---|---|---|
| | | | \
|事件交互区别 |合成有多个子句会多次返回`TTSSentenceStart`和`TTSSentenceEnd`。开启字幕后字幕跟随`TTSSentenceEnd`返回。 |合成有多个子句，仅返回一次`TTSSentenceStart`和`TTSSentenceEnd`。 |\
| | |开启字幕后会多次返回`TTSSubtitle`。 |
| | | | \
|返回时机 |一个子句的时间戳返回之后才会开始返回下一句音频。 |\
| | |在一句音频合成之后，不会立即返回该句的字幕。 |\
| | |合成进度不会被字幕识别阻塞，当一句的字幕识别完成后立即返回。 |\
| | |可能一个子句的字幕返回的时候，已经返回下一句的音频帧给调用方了。 |
| | | | \
|句子返回格式 |\
| |字幕信息是基于tn打轴 |\
| |:::tip |\
| |1. text字段对应于：原文 |\
| |2. words内文本字段对应于：tn |\
| |::: |\
| |第一句： |\
| |```JSON |\
| |{ |\
| |    "phonemes": [ |\
| |    ], |\
| |    "text": "2019年1月8日，软件2.0版本于格萨拉彝族乡应时而生。发布会当日，一场瑞雪将天地映衬得纯净无瑕。", |\
| |    "words": [ |\
| |        { |\
| |            "confidence": 0.8766515, |\
| |            "endTime": 0.295, |\
| |            "startTime": 0.155, |\
| |            "word": "二" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.95224416, |\
| |            "endTime": 0.425, |\
| |            "startTime": 0.295, |\
| |            "word": "零" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.9108828, |\
| |            "endTime": 0.575, |\
| |            "startTime": 0.425, |\
| |            "word": "一" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.9609025, |\
| |            "endTime": 0.755, |\
| |            "startTime": 0.575, |\
| |            "word": "九" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.96244556, |\
| |            "endTime": 1.005, |\
| |            "startTime": 0.755, |\
| |            "word": "年" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.85796577, |\
| |            "endTime": 1.155, |\
| |            "startTime": 1.005, |\
| |            "word": "一" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.8460129, |\
| |            "endTime": 1.275, |\
| |            "startTime": 1.155, |\
| |            "word": "月" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.90833753, |\
| |            "endTime": 1.505, |\
| |            "startTime": 1.275, |\
| |            "word": "八" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.9403977, |\
| |            "endTime": 1.935, |\
| |            "startTime": 1.505, |\
| |            "word": "日，" |\
| |        }, |\
| |         |\
| |        ... |\
| |         |\
| |        { |\
| |            "confidence": 0.9415791, |\
| |            "endTime": 10.505, |\
| |            "startTime": 10.355, |\
| |            "word": "无" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.903162, |\
| |            "endTime": 10.895, // 第一句结束时间 |\
| |            "startTime": 10.505, |\
| |            "word": "瑕。" |\
| |        } |\
| |    ] |\
| |} |\
| |``` |\
| | |\
| |第二句： |\
| |```JSON |\
| |{ |\
| |    "phonemes": [ |\
| | |\
| |    ], |\
| |    "text": "这仿佛一则自然寓言：我们致力于在不断的版本迭代中，为您带来如雪后初霁般清晰、焕然一新的体验。", |\
| |    "words": [ |\
| |        { |\
| |            "confidence": 0.8970245, |\
| |            "endTime": 11.6953745, |\
| |            "startTime": 11.535375, // 第二句开始时间，是相对整个session的位置 |\
| |            "word": "这" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.86508185, |\
| |            "endTime": 11.875375, |\
| |            "startTime": 11.6953745, |\
| |            "word": "仿" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.73354065, |\
| |            "endTime": 12.095375, |\
| |            "startTime": 11.875375, |\
| |            "word": "佛" |\
| |        }, |\
| |        { |\
| |            "confidence": 0.8525295, |\
| |            "endTime": 12.275374, |\
| |            "startTime": 12.095375, |\
| |            "word": "一" |\
| |        }... |\
| |    ] |\
| |} |\
| |``` |\
| | |字幕信息是基于原文打轴 |\
| | |:::tip |\
| | |1. text字段对应于：原文 |\
| | |2. words内文本字段对应于：原文 |\
| | |::: |\
| | |第一句： |\
| | |```JSON |\
| | |{ |\
| | |    "phonemes": [ |\
| | |    ], |\
| | |    "text": "2019年1月8日，软件2.0版本于格萨拉彝族乡应时而生。", |\
| | |    "words": [ |\
| | |        { |\
| | |            "confidence": 0.11120544, |\
| | |            "endTime": 0.615, |\
| | |            "startTime": 0.585, |\
| | |            "word": "2019" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.8413397, |\
| | |            "endTime": 0.845, |\
| | |            "startTime": 0.615, |\
| | |            "word": "年" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.2413961, |\
| | |            "endTime": 0.875, |\
| | |            "startTime": 0.845, |\
| | |            "word": "1" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.8487973, |\
| | |            "endTime": 1.055, |\
| | |            "startTime": 0.875, |\
| | |            "word": "月" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.509697, |\
| | |            "endTime": 1.225, |\
| | |            "startTime": 1.165, |\
| | |            "word": "8" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.9516253, |\
| | |            "endTime": 1.485, |\
| | |            "startTime": 1.225, |\
| | |            "word": "日，" |\
| | |        }, |\
| | |         |\
| | |        ... |\
| | |         |\
| | |        { |\
| | |            "confidence": 0.6933777, |\
| | |            "endTime": 5.435, |\
| | |            "startTime": 5.325, |\
| | |            "word": "而" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.921702, |\
| | |            "endTime": 5.695, // 第一句结束时间 |\
| | |            "startTime": 5.435, |\
| | |            "word": "生。" |\
| | |        } |\
| | |    ] |\
| | |} |\
| | |``` |\
| | | |\
| | | |\
| | |第二句： |\
| | |```JSON |\
| | |{ |\
| | |    "phonemes": [ |\
| | | |\
| | |    ], |\
| | |    "text": "发布会当日，一场瑞雪将天地映衬得纯净无瑕。", |\
| | |    "words": [ |\
| | |        { |\
| | |            "confidence": 0.7016578, |\
| | |            "endTime": 6.3550415, |\
| | |            "startTime": 6.2150416, // 第二句开始时间，是相对整个session的位置 |\
| | |            "word": "发" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.6800497, |\
| | |            "endTime": 6.4450417, |\
| | |            "startTime": 6.3550415, |\
| | |            "word": "布" |\
| | |        }, |\
| | |         |\
| | |        ... |\
| | |         |\
| | |        { |\
| | |            "confidence": 0.8818264, |\
| | |            "endTime": 10.145041, |\
| | |            "startTime": 9.945042, |\
| | |            "word": "净" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.87248623, |\
| | |            "endTime": 10.285042, |\
| | |            "startTime": 10.145041, |\
| | |            "word": "无" |\
| | |        }, |\
| | |        { |\
| | |            "confidence": 0.8069703, |\
| | |            "endTime": 10.505041, |\
| | |            "startTime": 10.285042, |\
| | |            "word": "瑕。" |\
| | |        } |\
| | |    ] |\
| | |} |\
| | |``` |\
| | | |\
| | | |
| | | | \
|语种 |中、英，不支持小语种、方言 |中、英，不支持小语种、方言 |
| | | | \
|latex |enable_latex_tn=true，有字幕返回 |enable_latex_tn=true，无字幕返回，接口不报错 |
| | | | \
|ssml |req_params.ssml不为空，有字幕返回 |req_params.ssml不为空，无字幕返回，接口不报错 |

<span id="8164feca"></span>
# 3 错误码

| | | | \
|Code |Message |说明 |
|---|---|---|
| | | | \
|20000000 |ok |音频合成结束的成功状态码 |
| | | | \
|45000000 |\
| |speaker permission denied: get resource id: access denied |音色鉴权失败，一般是speaker指定音色未授权或者错误导致 |\
| | | |
|^^| | | \
| |quota exceeded for types: concurrency |并发限流，一般是请求并发数超过限制 |
| | | | \
|55000000 |服务端一些error |服务端通用错误 |

<span id="00165867"></span>
# 4 调用示例

```mixin-react
return (<Tabs>
<Tabs.TabPane title="Python调用示例" key="iYrQ6gaeNz"><RenderMd content={`<span id="32c5df89"></span>
### 前提条件

* 调用之前，您需要获取以下信息：
   * \`<appid>\`：使用控制台获取的APP ID，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<access_token>\`：使用控制台获取的Access Token，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<voice_type>\`：您预期使用的音色ID，可参考 [大模型音色列表](https://www.volcengine.com/docs/6561/1257544)。

<span id="e50a7eed"></span>
### Python环境

* Python：3.9版本及以上。
* Pip：25.1.1版本及以上。您可以使用下面命令安装。

\`\`\`Bash
python3 -m pip install --upgrade pip
\`\`\`

<span id="57159ec2"></span>
### 下载代码示例
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/a67dd285912648c2980a853c486c560f~tplv-goo7wpa0wc-image.image" name="volcengine_unidirectional_stream_demo.tar.gz" ></Attachment>
<span id="b93a1eb6"></span>
### 解压缩代码包，安装依赖
\`\`\`Bash
mkdir -p volcengine_unidirectional_stream_demo
tar xvzf volcengine_unidirectional_stream_demo.tar.gz -C ./volcengine_unidirectional_stream_demo
cd volcengine_unidirectional_stream_demo
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
pip3 install -e .
\`\`\`

<span id="a0896222"></span>
### 发起调用
> \`<appid>\`替换为您的APP ID。
> \`<access_token>\`替换为您的Access Token。
> \`<voice_type>\`替换为您预期使用的音色ID，例如\`zh_female_cancan_mars_bigtts\`。

\`\`\`Bash
python3 examples/volcengine/unidirectional_stream.py --appid <appid> --access_token <access_token> --voice_type <voice_type> --text "你好，我是火山引擎的语音合成服务。这是一个美好的旅程。"
\`\`\`

`}></RenderMd></Tabs.TabPane>
<Tabs.TabPane title="Java调用示例" key="OeOm28iImI"><RenderMd content={`<span id="c778cfe1"></span>
### 前提条件

* 调用之前，您需要获取以下信息：
   * \`<appid>\`：使用控制台获取的APP ID，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<access_token>\`：使用控制台获取的Access Token，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<voice_type>\`：您预期使用的音色ID，可参考 [大模型音色列表](https://www.volcengine.com/docs/6561/1257544)。

<span id="28217763"></span>
### Java环境

* Java：21版本及以上。
* Maven：3.9.10版本及以上。

<span id="e56568a4"></span>
### 下载代码示例
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/ad93b596b83445de994f9dc991ef5a83~tplv-goo7wpa0wc-image.image" name="volcengine_unidirectional_stream_demo.tar.gz" ></Attachment>
<span id="25d4d614"></span>
### 解压缩代码包，安装依赖
\`\`\`Bash
mkdir -p volcengine_unidirectional_stream_demo
tar xvzf volcengine_unidirectional_stream_demo.tar.gz -C ./volcengine_unidirectional_stream_demo
cd volcengine_unidirectional_stream_demo
\`\`\`

<span id="c9ffd562"></span>
### 发起调用
> \`<appid>\`替换为您的APP ID。
> \`<access_token>\`替换为您的Access Token。
> \`<voice_type>\`替换为您预期使用的音色ID，例如\`zh_female_cancan_mars_bigtts\`。

\`\`\`Bash
mvn compile exec:java -Dexec.mainClass=com.speech.volcengine.UnidirectionalStream -DappId=<appid> -DaccessToken=<access_token> -Dvoice=<voice_type> -Dtext="**你好**，我是豆包语音助手，很高兴认识你。这是一个愉快的旅程。"
\`\`\`

`}></RenderMd></Tabs.TabPane>
<Tabs.TabPane title="Go调用示例" key="vZz5H44DbG"><RenderMd content={`<span id="0fc38f07"></span>
### 前提条件

* 调用之前，您需要获取以下信息：
   * \`<appid>\`：使用控制台获取的APP ID，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<access_token>\`：使用控制台获取的Access Token，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<voice_type>\`：您预期使用的音色ID，可参考 [大模型音色列表](https://www.volcengine.com/docs/6561/1257544)。

<span id="9984b64a"></span>
### Go环境

* Go：1.21.0版本及以上。

<span id="66b098f9"></span>
### 下载代码示例
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/00313795a9c041fda8d105ef9c6e2f47~tplv-goo7wpa0wc-image.image" name="volcengine_unidirectional_stream_demo.tar.gz" ></Attachment>
<span id="8303b57b"></span>
### 解压缩代码包，安装依赖
\`\`\`Bash
mkdir -p volcengine_unidirectional_stream_demo
tar xvzf volcengine_unidirectional_stream_demo.tar.gz -C ./volcengine_unidirectional_stream_demo
cd volcengine_unidirectional_stream_demo
\`\`\`

<span id="757d5902"></span>
### 发起调用
> \`<appid>\`替换为您的APP ID。
> \`<access_token>\`替换为您的Access Token。
> \`<voice_type>\`替换为您预期使用的音色ID，例如\`zh_female_cancan_mars_bigtts\`。

\`\`\`Bash
go run volcengine/unidirectional_stream/main.go --appid <appid> --access_token <access_token> --voice_type <voice_type> --text "**你好**，我是火山引擎的语音合成服务。"
\`\`\`

`}></RenderMd></Tabs.TabPane>
<Tabs.TabPane title="C#调用示例" key="ty6KpXuQRP"><RenderMd content={`<span id="ad8b79ae"></span>
### 前提条件

* 调用之前，您需要获取以下信息：
   * \`<appid>\`：使用控制台获取的APP ID，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<access_token>\`：使用控制台获取的Access Token，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<voice_type>\`：您预期使用的音色ID，可参考 [大模型音色列表](https://www.volcengine.com/docs/6561/1257544)。

<span id="c2214808"></span>
### C#环境

* .Net 9.0版本。

<span id="dc062b19"></span>
### 下载代码示例
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/ebca47d9446a436caf379cb5c08d5b47~tplv-goo7wpa0wc-image.image" name="volcengine_unidirectional_stream_demo.tar.gz" ></Attachment>
<span id="e8bce75a"></span>
### 解压缩代码包，安装依赖
\`\`\`Bash
mkdir -p volcengine_unidirectional_stream_demo
tar xvzf volcengine_unidirectional_stream_demo.tar.gz -C ./volcengine_unidirectional_stream_demo
cd volcengine_unidirectional_stream_demo
\`\`\`

<span id="a82d7a34"></span>
### 发起调用
> \`<appid>\`替换为您的APP ID。
> \`<access_token>\`替换为您的Access Token。
> \`<voice_type>\`替换为您预期使用的音色ID，例如\`zh_female_cancan_mars_bigtts\`。

\`\`\`Bash
dotnet run --project Volcengine/UnidirectionalStream/Volcengine.Speech.UnidirectionalStream.csproj -- --appid <appid> --access_token <access_token> --voice_type <voice_type> --text "**你好**，这是一个测试文本。我们正在测试文本转语音功能。"
\`\`\`

`}></RenderMd></Tabs.TabPane>
<Tabs.TabPane title="TypeScript调用示例" key="fsH2BSKG95"><RenderMd content={`<span id="dcc516e7"></span>
### 前提条件

* 调用之前，您需要获取以下信息：
   * \`<appid>\`：使用控制台获取的APP ID，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<access_token>\`：使用控制台获取的Access Token，可参考 [控制台使用FAQ-Q1](https://www.volcengine.com/docs/6561/196768#q1%EF%BC%9A%E5%93%AA%E9%87%8C%E5%8F%AF%E4%BB%A5%E8%8E%B7%E5%8F%96%E5%88%B0%E4%BB%A5%E4%B8%8B%E5%8F%82%E6%95%B0appid%EF%BC%8Ccluster%EF%BC%8Ctoken%EF%BC%8Cauthorization-type%EF%BC%8Csecret-key-%EF%BC%9F)。
   * \`<voice_type>\`：您预期使用的音色ID，可参考 [大模型音色列表](https://www.volcengine.com/docs/6561/1257544)。

<span id="cb1aa0a9"></span>
### node环境

* node：v24.0版本及以上。

<span id="abd541dd"></span>
### 下载代码示例
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/27e058ffbf9d4dac9bc91cb0258c459a~tplv-goo7wpa0wc-image.image" name="volcengine_unidirectional_stream_demo.tar.gz" ></Attachment>
<span id="ad736548"></span>
### 解压缩代码包，安装依赖
\`\`\`Bash
mkdir -p volcengine_unidirectional_stream_demo
tar xvzf volcengine_unidirectional_stream_demo.tar.gz -C ./volcengine_unidirectional_stream_demo
cd volcengine_unidirectional_stream_demo
npm install
npm install -g typescript
npm install -g ts-node
\`\`\`

<span id="e391c738"></span>
### 发起调用
> \`<appid>\`替换为您的APP ID。
> \`<access_token>\`替换为您的Access Token。
> \`<voice_type>\`替换为您预期使用的音色ID，例如\`<voice_type>\`。

\`\`\`Bash
npx ts-node src/volcengine/unidirectional_stream.ts --appid <appid> --access_token <access_token> --voice_type <voice_type> --text "**你好**，我是火山引擎的语音合成服务。"
\`\`\`

`}></RenderMd></Tabs.TabPane></Tabs>);
 ```


