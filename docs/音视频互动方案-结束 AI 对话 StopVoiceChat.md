调用本接口，主动停止一个正在运行的智能体任务。
:::warning
调用 `StopVoiceChat` 接口仅会使智能体离开房间，真人用户不会离开房间，仍会产生音视频费用。如需完整结束通话，客户端还需调用 RTC SDK 接口 `leaveRoom` 使真人用户离开房间，并调用 `destroyRTCEngine` 销毁引擎实例。
:::
<span id=".5L2_55So6K-05piO"></span>
## 使用说明
<span id=".6LCD55So5o6l5Y-j"></span>
### 调用接口
关于调用接口的请求结构、公共参数、签名方法、返回结构，参看[如何调用 OpenAPI](https://www.volcengine.com/docs/6348/1899868)。
<span id=".5rOo5oSP5LqL6aG5"></span>
## 注意事项

* 请求频率：QPS 不得超过 60。
* 请求接入地址：固定为 `rtc.volcengineapi.com`。

<span id=".6K-35rGC6K-05piO"></span>
## 请求说明

* 请求方式：POST
* 请求地址：https://rtc.volcengineapi.com?Action=StopVoiceChat&Version=2025\-06\-01

<span id=".6LCD6K-V"></span>
## 调试
<APILink link="https://api.volcengine.com/api-explorer/debug?action=StopVoiceChat&serviceCode=rtc&version=2025-06-01&groupName=" description="API Explorer 您可以通过 API Explorer 在线发起调用，无需关注签名生成过程，快速获取调用结果。"></APILink>
<span id=".6K-35rGC5Y-C5pWw"></span>
## 请求参数
<span id="Query"></span>
### Query


**Action** <span data-label="purple"> String </span> %%require%% `示例值：StopVoiceChat`
接口名称。当前 API 的名称为 `StopVoiceChat`。


**Version** <span data-label="purple"> String </span> %%require%% `示例值：2025-06-01`
接口版本。当前 API 的版本为 `2025-06-01`。


<span id="Body"></span>
### Body


**AppId** <span data-label="purple"> String </span> %%require%% `示例值：69*****c9`
应用的唯一标志。
需与调用 `StartVoiceChat` 启动任务时使用的 `AppId` 保持一致。可在[音视频互动智能体_应用管理](https://console.volcengine.com/conversational-ai/devTools/appIdManage)获取。


**RoomId** <span data-label="purple"> String </span> %%require%% `示例值：Room1`
通话房间 ID。
需与调用 `StartVoiceChat` 启动任务时使用的 `RoomId` 保持一致。


**TaskId** <span data-label="purple"> String </span> %%require%% `示例值：task1`
目标智能体任务的 ID。
需与调用 `StartVoiceChat` 启动任务时定义的 `TaskId` 保持一致。


<span id=".6L-U5Zue5Y-C5pWw"></span>
## 返回参数
本接口无特有的返回参数。公共返回参数请见[返回结构](./1178322)。
其中返回值 `Result` 仅在请求成功时返回 `ok`,失败时为空。
