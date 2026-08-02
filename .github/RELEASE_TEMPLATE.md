# Tomato English Happy Talking {{VERSION}}

## 本次亮点

- 用普通用户能理解的语言说明最重要的变化。
- 只列出已经验证并随本版本发布的能力。
- 功能型版本附三张脱敏真实截图：主要流程、主要结果、跨平台或导出结果。

## 下载

| 平台 | 文件 | 安装说明 |
| --- | --- | --- |
| Windows x64 | `tomato_english_happy_talking-windows-{{VERSION}}.zip` | 解压后运行 EXE；需要 WebView2 Runtime |
| Android | `tomato_english_happy_talking-android-{{VERSION}}.apk` | 侧载安装；正式签名前注明测试签名 |
| 校验 | `SHA256SUMS.txt` | 使用 SHA-256 核对两个安装包 |

## 升级注意事项

- 说明数据库、缓存、素材目录或设置是否需要迁移。
- Windows 覆盖程序文件前备份重要本地数据，不要把旧运行数据打入公开 ZIP。

## 已知限制

- Windows 本地超分需要 Vulkan；Android 当前不支持本地 Real-ESRGAN 超分。
- 云 AI 能力需要用户自己的账号和 API Key，并由供应商计费。
- Android 使用测试签名时必须明确说明，不得描述为商店正式版。

## 发布检查

- [ ] Windows ZIP 与 Android APK 来自同一提交。
- [ ] Windows ZIP 不含数据库、缓存、日志、生成媒体、账号或密钥。
- [ ] APK 签名类型已在说明中准确标注。
- [ ] `SHA256SUMS.txt` 与上传资产一致。
- [ ] 截图不含密钥、账号、本机路径或私人内容。
- [ ] 下载和升级步骤已在未登录状态下验证。
