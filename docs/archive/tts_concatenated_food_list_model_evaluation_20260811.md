# TTS 连写食品清单模型评测特例

日期：2026-08-11
来源：《柳林风声》E02 `The River Bank (2)`
用途：未来选择或更换英语 TTS 引擎、模型、音色时的人工听感回归；不是正文改写规则。

## 原文特例

原书用不加空格和逗号的连续写法表现角色一口气报出野餐食品：

```text
"coldtonguecoldhamcoldbeefpickledgherkinssaladfrenchrolls–
cresssandwichespottedmeatgingerbeerlemonadesodawater—"
```

语义上的朗读词组为：

```text
cold tongue, cold ham, cold beef, pickled gherkins, salad, French rolls—
cress sandwiches, potted meat, ginger beer, lemonade, soda water—
```

字幕、英文正文和分句审计必须保留原书连写形式，不得为了 TTS 改写持久化正文。该样例专门检查
语音引擎能否直接从原始连写字符串恢复自然的英语词界和列举节奏。

## 已验证基线（跨模型）

- 平台：火山引擎 Doubao TTS 2.0
- Resource ID：`seed-tts-2.0`
- 音色：`en_female_dacey_uranus_bigtts`（Dacey，美式英语）
- 生成时间：2026-08-03
- 用户人工试听结论：火山引擎能够自行正确处理该连写特例，评审通过。
- 前半缓存键：`tts_257322d100796b4ed1bd81358fce783ebf9123488c72e6d7cd79a266141d40f1`
- 后半缓存键：`tts_eff8f0183db110c8d61aa0a6957a719852749548bd874be3be56dc0cef8d49c5`
- 平台：阿里云百炼 CosyVoice
- 模型：`cosyvoice-v3-flash`
- 音色：`loongabby_v3`（Abby，中英双语）
- 生成时间：2026-08-11
- 用户人工试听结论：阿里云也能够自行正确处理该连写特例，评审通过。
- 对比测试音频：`.tmp/tts_food_compare_20260811/aliyun_en_abby.mp3`
- 对比音频 SHA-256：`d364f2123f03bc706fb58089f96c7d565d721ac7783a5953cbfa53e825e7c60f`

本结论证明上述两组具体的模型、音色和实际音频组合均已人工通过，能够从原始连写文本自行恢复词界；
不能外推到同平台其它音色、其它模型，也不能仅凭“接口成功返回 MP3”宣布通过。

## 后续模型验收方法

1. 使用原始连写文本直接合成，不预先插入空格或逗号。
2. 人工核对是否依次、完整地读出 11 组食品名称，不漏读、不拼字母、不制造错误词界。
3. 检查列举节奏、停顿和语速是否仍适合童话朗读；不能只依赖 ASR 文本判断。
4. 至少重复两次或使用两个稳定请求，排除偶然输出；记录平台、模型、音色、请求文本、缓存键和音频。
5. 新模型未通过时，可在不修改正文和字幕的前提下评估 TTS 专用朗读文本；该回退必须单独记录，
   不得把空格或逗号写回《柳林风声》英文正文。

## 与分句和复用的关系

V3.6 将引语合并为一个持久化句槽。旧音频仍是两个句槽，不能因为本特例的发音已经通过就直接
拼接或冒充新版单句缓存；后续是否复用仍遵守整句朗读词序、缓存句柄和视频时间轴规则。本文件只
保存跨 TTS 模型的发音能力基线。
