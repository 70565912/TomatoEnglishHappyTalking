<span id="81eaafc0"></span>
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

<span id="d7a28c45"></span>
# 1 接口功能
单向流式API为用户提供文本转语音的能力，支持多语种、多方言，同时支持http协议流式输出。
<span id="27edde0a"></span>
## 1.1最佳实践

* 客户端读取服务端流式返回的json数据，从中取出对应的音频数据；
* 音频数据返回的是base64格式，需要解析后拼接到字节数组即可组装音频进行播放；
* 可以使用对应编程语言的连接复用组件，避免重复建立tcp连接（火山服务端keep-alive时间为1分钟），例如python的session组件：

```JSON
session = requests.Session()
response = session.post(url, headers=headers, json=payload, stream=True)
```


<span id="14358605"></span>
# 2 HTTP Chunked格式接口说明
<span id="5495b4ca"></span>
## 2.1 请求Request
<span id="f38e3780"></span>
### 请求路径

* 服务对应的请求路径：`https://openspeech.bytedance.com/api/v3/tts/unidirectional`

<span id="1b6e0bd5"></span>
### 鉴权Request Headers
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

<span id="defbeb7a"></span>
### 额外Request Headers

| | | | | \
|Key |说明 |是否必须 |Value示例 |
|---|---|---|---|
| | | | | \
|X-Control-Require-Usage-Tokens-Return |请求消耗的用量返回控制标记。当携带此字段，在合成音频结束时的返回数据中会多一个usage的JSON Object字段，其中包含了所需的用量数据。 |否 |* 设置为*，表示返回已支持的用量数据。 |\
| | | |* 也设置为具体的用量数据标记，如text_words；多个用逗号分隔 |\
| | | |* 当前已支持的用量数据 |\
| | | |   * text_words，表示计费字符数 |

<span id="bf142291"></span>
### Response Headers

| | | | \
|Key |说明 |Value示例 |
|---|---|---|
| | | | \
|Transfer-Encoding |返回的传输编码，一般为chunked |chunked |
| | | | \
|X-Tt-Logid |服务端返回的 logid，建议用户获取和打印方便定位问题 |2025041513355271DF5CF1A0AE0508E78C |

<span id="1aa30415"></span>
## 2.2 请求Body

| | | | | | \
|字段 |描述 |是否必须 |类型 |默认值 |
|---|---|---|---|---|
| | | | | | \
|user |用户信息 | | | |
| | | | | | \
|user.uid |用户uid | | | |
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
| |* ["豆包语音合成模型2.0"的音色](https://www.volcengine.com/docs/6561/1257544) 暂不支持 |\
| |* 豆包声音复刻模型2.0（icl 2.0）的音色暂不支持 | |string | |
| | | | | | \
|req_params.speaker |发音人，具体见[发音人列表](https://www.volcengine.com/docs/6561/1257544) |√ |string | |
| | | | | | \
|req_params.audio_params |音频参数，便于服务节省音频解码耗时 |√ |object | |
| | | | | | \
|req_params.audio_params.format |音频编码格式，mp3/ogg_opus/pcm。<span style="background-color: rgba(255,246,122, 0.8)">接口传入wav并不会报错，在流式场景下传入wav会多次返回wav header，这种场景建议使用pcm。</span> | |string |mp3 |
| | | | | | \
|req_params.audio_params.sample_rate |音频采样率，可选值 [8000,16000,22050,24000,32000,44100,48000] | |number |24000 |
| | | | | | \
|req_params.audio_params.bit_rate |音频比特率，可传16000、32000等。 |\
| |bit_rate默认设置范围为64k～160k，传了disable_default_bit_rate为true后可以设置到64k以下 |\
| |GoLang示例：`additions = fmt.Sprintf("{"disable_default_bit_rate":true}")` |\
| |**注：​**bit_rate只针对MP3格式，wav计算比特率跟pcm一样是 比特率 (bps) = 采样率 × 位深度 × 声道数 |\
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
|req_params.audio_params.enable_timestamp |\
|([仅TTS1.0支持](https://www.volcengine.com/docs/6561/1257544)) |设置 "enable_timestamp": true 返回句级别字的时间戳（默认为 false，参数传入 true 即表示启用） |\
| |开启后，在原有返回的事件`event=TTSSentenceEnd`中，新增该子句的时间戳信息。 |\
| | |\
| |* 一个子句的时间戳返回之后才会开始返回下一句音频。 |\
| |* 合成有多个子句会多次返回`TTSSentenceStart`和`TTSSentenceEnd`。开启字幕后字幕跟随`TTSSentenceEnd`返回。 |\
| |* 字/词粒度的时间戳，其中字/词是tn。具体可以看下面的例子。 |\
| |* 支持中、英，其他语种、方言暂时不支持。 |\
| | |\
| |注：该字段仅适用于["豆包语音合成模型1.0"的音色](https://www.volcengine.com/docs/6561/1257544) | |bool |false |
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
| |**特别提醒：** |\
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
| |**语音合成 1.0 音色** |\
| | |\
| |* 根据音色列表中音色的支持范围指定对应语种 |\
| |* 不给定参数，正常中英混 |\
| | |\
| |**声音复刻ICL1.0场景：** |\
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
| |**语音合成 2.0 音色** |\
| | |\
| |* 根据音色列表中音色的支持范围指定对应语种 |\
| |* 不给定参数，正常中英混 |\
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
|req_params.additions.cache_config（缓存相关参数） |开启缓存，开启后合成**相同文本**时，服务会直接读取缓存返回上一次合成该文本的音频，可明显加快相同文本的合成速率，缓存数据保留时间1小时。 |\
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
|req_params.additions.post_process.pitch |音调取值范围是[-12,12] | |int |0 |
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

<span id="5557b1c1"></span>
## 2.3 响应Response

* 音频响应数据，其中data对应合成音频base64音频数据：

```JSON
{
    "code": 0,
    "message": "",
    "data" : {{STRING}}
}
```


* 文本响应数据，其中sentence对应合成文本数据（包含时间戳）：

```JSON
{
    "code": 0,
    "message": "",
    "data" : null,
    "sentence": <object>
}
```

示例json：
```JSON
{
    "code": 0,
    "message": "",
    "data": null,
    "sentence": {
        "text": "其他人。",
        "words": [
            {
                "confidence": 0.8531248,
                "endTime": 0.315,
                "startTime": 0.205,
                "word": "其"
            },
            {
                "confidence": 0.9710379,
                "endTime": 0.515,
                "startTime": 0.315,
                "word": "他"
            },
            {
                "confidence": 0.9189944,
                "endTime": 0.815,
                "startTime": 0.515,
                "word": "人。"
            }
        ]
    }
}
```


* 合成音频结束对应的成功响应：
   * 其中usage字段默认不存在，仅在header中插入需要返回用量的标记后会新增。

```JSON
{
    "code": 20000000,
    "message": "ok",
    "data": null,
    "usage": {"text_words":10}
}
```

<span id="96ebcb5c"></span>
## 2.4 时间戳相关说明

| | | | \
| |**TTS1.0** |\
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

<span id="35d1be27"></span>
## 2.5 实例samples
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/b86fde682e2649e1a5498bfd71f21be3~tplv-goo7wpa0wc-image.image" name="tts_http_demo.py" ></Attachment>
<span id="d8a0ebce"></span>
# 3 SSE格式接口说明
<span id="8c718473"></span>
## 3.1 请求Request
<span id="e33029c9"></span>
### 请求路径

* 服务对应的请求路径：`https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse`

<span id="9e794140"></span>
### Request Headers

*  同2.1节中的HTTP Chunked格式接口的Request Headers中内容一样

<span id="d9de0c79"></span>
## 3.2 请求Body

* 同2.2节中的HTTP Chunked格式接口的Request Body的内容一样， 示例也同2.2节中的HTTP Chunked格式接口所示。

<span id="488db789"></span>
## 3.3 响应Response
<span id="88eefd58"></span>
### Response Headers

| | | | \
|Key |说明 |Value示例 |
|---|---|---|
| | | | \
|Content-Type |返回的数据类型，一般为event-stream |text/event-stream |
| | | | \
|X-Tt-Logid |服务端返回的 logid，建议用户获取和打印方便定位问题 |2025041513355271DF5CF1A0AE0508E78C |

<span id="451fd02c"></span>
## 3.4 Response Body

* 单个返回内容同2.2节中HTTP Chunked格式接口的Response内容， 包含由code、message、data等字段组成的对象。
* 整体返回示例如下

```JSON
event: 352
data: {"code":0,"message":"","data":"二进制音频流xxxx"}

event: 351
data: {"code":0,"message":"","data":null,"sentence":{"phonemes":[],"text":"音频文件能够正常播放。","words":[]}}

event: 152
data: {"code":20000000,"message":"OK","data":null,"usage":{"text_words":11}}
```


* event 表示云端响应的事件ID。以下为常见的事件，仅供参考使用。
   * 351 - TTSSentenceEnd （TTS 语句处理结束）
   * 352 - TTSResponse (TTS的合成内容，一般多包含二进制字符串流）
   * 151 - SessionCancel （会话被取消）
   * 152 - SessionFinish （会话结束）
   * 153 - SessionFailed （会话失败）

<span id="f1598651"></span>
## 3.5 使用限制

   * 目前本接口仅支持以SSE的格式返回数据，对其常规能力，如重连、断点续传等能力暂不支持。

<span id="a3fef8a2"></span>
## 3.6 示例Samples
<Attachment link="https://p9-arcosite.byteimg.com/tos-cn-i-goo7wpa0wc/ab89ee3d0d40492e879a1a760dd8133f~tplv-goo7wpa0wc-image.image" name="tts_http_sse_demo.py" ></Attachment>
<span id="60a09161"></span>
# 4 错误码

| | | | \
|Code |Message |说明 |
|---|---|---|
| | | | \
|20000000 |ok |音频合成结束的成功状态码 |
| | | | \
|40402003 |TTSExceededTextLimit:exceed max limit |提交文本长度超过限制 |
| | | | \
|45000000 |\
| |speaker permission denied: get resource id: access denied |音色鉴权失败，一般是speaker指定音色未授权或者错误导致 |\
| | | |
|^^| | | \
| |quota exceeded for types: concurrency |并发限流，一般是请求并发数超过限制 |
| | | | \
|55000000 |服务端一些error |服务端通用错误 |



