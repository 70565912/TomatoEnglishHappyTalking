# PixelLab 图片资产生成

本项目的 Web UI 视觉图片集中在 `web_ui/public/assets/ui/`，Flutter 内置 Web 资源同步在 `app/assets/web/assets/ui/`。

当前主角色、怪物、奖励和动图资产已切换为 LEGO 游戏风格，见 `docs/lego-style-asset-plan.md`。PixelLab 清单现在只保留任务卡封面方向；早期 `tomato-*`、`monster-*`、`reward-*` 资产已从 App 打包资源中退役，避免和 LEGO 主风格混用。

PixelLab API 使用 `https://api.pixellab.ai/v2`，调用时需要 Bearer token。多数 Pro 端点是异步任务；本项目脚本优先使用同步的 `/create-image-pixflux` 生成 PNG，适合一次性生成番茄伙伴、任务卡和奖励图标。

主脚本是 `tools/generate_pixellab_assets.mjs`，PowerShell 入口 `tools/generate_pixellab_assets.ps1` 会转调 Node 版本。这样可以避开部分 Windows 环境下 `Invoke-RestMethod` / `curl.exe` 的 Schannel TLS 凭证问题。

## 生成方式

不要把 token 写入源码。二选一：

```powershell
$env:PIXELLAB_API_TOKEN = "你的 PixelLab token"
```

或在本机创建：

```text
security/pixellab-api-token.txt
```

然后运行：

```powershell
.\tools\generate_pixellab_assets.ps1
```

只生成单个资产：

```powershell
.\tools\generate_pixellab_assets.ps1 -AssetName tomato-wave -Force
```

也可以直接运行 Node 入口：

```powershell
node .\tools\generate_pixellab_assets.mjs --asset-name tomato-wave --force
```

## 资产清单

提示词和输出尺寸维护在 `tools/pixellab_assets.json`。当前清单只包含任务卡封面：

- `card-space-snacks.png`
- `card-daisy-diver.png`
- `card-rocket-race.png`

生成脚本默认把图片写入 `web_ui/public/assets/ui/`，并同步到 `app/assets/web/assets/ui/`。

## 动画工作流

当前 App 的角色动图使用 LEGO 帧表和裁切帧，见 `docs/lego-style-asset-plan.md`。PixelLab 动画清单 `tools/pixellab_animations.json` 已清空，不再引用早期退役的 `tomato-wave.png`。

如果以后要重新实验 PixelLab 动画，它不是直接返回 GIF。推荐使用 `/animate-with-text-v3`：

1. 提交首帧 PNG 和动作描述，例如 `prototype-idle-frame.png` + `gentle idle breathing loop`。
2. 接口返回 `background_job_id`。
3. 轮询 `/background-jobs/{background_job_id}`，直到 `status` 为 `completed`。
4. 从 `last_response.images` 取回多张 PNG 帧。
5. 在 Web UI 中用帧序列播放，或后续再打包为 GIF / APNG / spritesheet。

本项目的动画清单在 `tools/pixellab_animations.json`，生成脚本是：

```powershell
node .\tools\generate_pixellab_animation.mjs --animation-name tomato-wave-idle
```

输出目录：

- `web_ui/public/assets/ui/animations/<animation-name>/`
- `app/assets/web/assets/ui/animations/<animation-name>/`

每个动画目录包含 `frame-00.png`、`frame-01.png` 等帧图，以及 `manifest.json`。当前策略先保存帧序列，不直接提交 GIF，因为帧序列更适合 Web UI 控制播放速度、循环和状态切换。

参考限制：

- 首帧最大 256x256。
- `frame_count` 支持 4 到 16，且必须是偶数。
- `width * height * frame_count <= 524288`。
- 4 帧适合 idle / breathing，8 帧适合 walk / run，16 帧适合复杂动作。
- 典型耗时 30 到 180 秒。
