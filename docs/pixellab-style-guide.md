# PixelLab 视觉风格基准

本文件记录 2026-06-01 通过 PixelLab 生成的早期参考图。当前主视觉基准已切换为乐高游戏风格番茄，见 `docs/lego-style-asset-plan.md`；不要再把本文件里的 PixelLab 像素风作为主角色生成基准。

## 基准资产

生成目录：

- `web_ui/public/assets/ui/`
- `app/assets/web/assets/ui/`

早期基准图包括番茄伙伴、听说读写状态、奖励图标和三张任务卡封面。当前 App 打包资源已移除早期 `tomato-*`、`monster-*`、`reward-*` 角色/奖励 PNG，避免和 LEGO 主风格混用；生成清单 `tools/pixellab_assets.json` 现在只保留任务卡封面。

## 风格规则

- 儿童英语学习 App 风格，整体明亮、圆润、友好。
- 角色是玩具感像素插画，不走写实路线。
- 主角色使用番茄红身体、绿色叶子、超大眼睛、小手小脚。
- 辅助角色使用绿色圆润小伙伴，比例矮胖，表情积极。
- 轮廓使用深色单色描边，重要五官和道具也要描边。
- 色彩以番茄红、天空蓝、柠檬黄、薄荷绿和白色高光为主。
- 角色图使用透明背景，中心构图，四周保留足够 padding。
- 任务卡封面使用完整背景，尺寸保持 360x220，主体在小尺寸下仍然可读。
- 图片中不要生成文字、字母、水印或 UI 文案。
- 用作按钮/奖励的小图必须是单一物体图标，避免生成头像或人物徽章。

## 后续直接生成提示词模板

```text
Bright child-friendly pixel art for a cheerful English speaking practice app.
Clean silhouette, rounded toy-like shapes, crisp pixels, expressive face,
thick single-color dark outline, saturated tomato red, sky blue, lemon yellow,
mint green, and white highlights. Centered composition with generous padding.
No text, no letters, no watermark.
```

角色透明 PNG：

```text
Create a transparent-background PNG of the Tomato English mascot.
The mascot is a cute red tomato with green leafy hair, large friendly eyes,
small arms, small shoes, and an encouraging expression.
Use the project PixelLab baseline style: rounded toy-like pixel art,
thick dark outline, bright saturated colors, no text, no watermark.
```

任务卡封面：

```text
Create a 360x220 story card illustration in the project PixelLab baseline style.
Use a full colorful background, one clear story subject, crisp pixel art,
high readability at thumbnail size, no text, no watermark.
```

奖励图标：

```text
Create one centered reward icon only, transparent background, no face,
no person, no badge portrait, no text. Use bright toy-like pixel art,
thick outline, simple readable silhouette.
```

## 当前人工复核记录

- `tomato-*`、`monster-*` 系列仅作为历史参考，不再作为 App 主角色或辅助伙伴资源。
- `card-space-snacks.png` 和 `card-rocket-race.png` 可用；`card-daisy-diver.png` 更像海底场景，后续若要强调人物，需要在提示词中写明“visible cheerful child diver as the main subject”。
- `reward-star.png`、`reward-brick.png` 已退役；奖励图标使用 LEGO 道具资源。
