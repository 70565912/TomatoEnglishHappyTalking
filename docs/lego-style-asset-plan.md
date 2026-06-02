# Lego mascot asset baseline

本文记录当前项目视觉资产的主基准。后续生成动图帧、元素图、背景图时，优先遵守这里的规则。

## 主基准图

- 主基准：`docs/design-previews/generated-tomato-mascot-lego-preview.png`
- 不作为基准：`docs/design-previews/generated-tomato-mascot-lego-refined-preview.png`

## 角色规则

- 主角是乐高游戏风格番茄，不是纯 PixelLab 像素头像，也不是圆润 clay/toy refined 版本。
- 身体是大圆红色番茄，由可见的积木块面组成，保留 glossy plastic / LEGO brick 质感。
- 顶部是绿色弧形积木叶片，中央有一段较高的块状绿色茎。
- 手臂和腿必须是短、细、深蓝黑色线条，不要变成长粗管状四肢。
- 手是红色乐高 minifigure C 型夹手。
- 鞋是红色乐高积木鞋，带深色鞋底和圆形积木钉。
- 眼睛必须是像素块风格：阶梯状白色外轮廓、黑色块状瞳孔、方块高光。禁止光滑圆眼、玻璃娃娃眼、圆润 anime 眼。
- 表情可以变化，但要保留黑色块状眉毛和亲和的儿童学习 App 气质。

## 本轮生成预览

目录：`docs/design-previews/lego-preview-baseline-v3/`

- `lego-wave-animation-sheet-v3.png`：挥手 idle 动图帧表。
- `lego-speaking-animation-sheet-v3.png`：说话 / 跟读动图帧表。
- `lego-success-animation-sheet-v3.png`：成功庆祝动图帧表。
- `lego-character-state-sheet-v3.png`：听、说、庆祝、思考、困倦、成功等角色状态。
- `lego-props-element-sheet-v3.png`：奖励星、番茄道具、麦克风、耳机、书本、火箭、盾牌、计时器等元素图。
- `lego-background-scene-sheet-v3.png`：学习桌、故事花园、星空闯关、录音舞台背景方向。

项目可引用副本：

- `web_ui/public/assets/ui/lego/`
- `app/assets/web/assets/ui/lego/`

新增或调整 LEGO 资源后，必须同步检查 Flutter 打包配置和 Windows 发布目录。具体排查步骤见 `docs/build-and-release-pitfalls.md`，尤其是 `app/pubspec.yaml` 中的嵌套资源目录和 `release/windows/tomato_english_happy_talking/` 是否已真正更新。

逐帧动画 PNG：

- `animations/wave/frame-01.png` 到 `frame-08.png`
- `animations/speaking/frame-01.png` 到 `frame-08.png`
- `animations/success/frame-01.png` 到 `frame-08.png`

动画预览：

- `lego-wave-animation-v3.gif`
- `lego-wave-animation-v3.webp`
- `lego-speaking-animation-v3.gif`
- `lego-speaking-animation-v3.webp`
- `lego-success-animation-v3.gif`
- `lego-success-animation-v3.webp`

动画清单：

- `animations/manifest.json`

这些逐帧 PNG 是从生成帧表裁切出来的，不是 SVG 或代码绘制；后续可用 CSS `steps()`、canvas、GIF/WebP 或 Flutter/WebView 动画逻辑播放。

## 工具依赖

根目录 `package.json` 只用于项目工具脚本，不属于 Web UI 浏览器运行依赖。

- `sharp`：裁切帧表、补齐帧尺寸、转换动画 WebP。
- `gifenc`：把逐帧 PNG 编码为 GIF。

常用命令：

```powershell
npm install
npm run assets:app-icons
npm run assets:lego-props
npm run assets:lego-animations
```

`npm run assets:app-icons` 会从 LEGO 番茄道具图生成 Windows `.ico` 和 Android launcher 图标。程序图标会额外去掉底部投影，并为 Windows 16/24/32px 小尺寸生成专用平面番茄，避免 Explorer 列表模式继续显示旧蓝色图标或小图糊成一团。

如果道具图标出现切片黑线、边界线或网格线，先重跑 `npm run assets:lego-props`。该脚本会去掉从切片边缘连进来的浅色背景和深色帧表边界线。

如果本机默认 npm cache 没有写权限，可改用工作区缓存：

```powershell
npm install --cache .tmp\npm-cache
```

## 后续生成提示词核心

```text
Use the generated-tomato-mascot-lego-preview.png version as the sole style baseline.
Polished 3D LEGO video game style, glossy plastic brick material, visible square brick facets.
Big round red tomato body, green curved brick leaves, tall blocky green stem.
Very short thin dark navy line arms and legs, red LEGO C-shaped hands, red brick shoes with dark soles and studs.
Eyes must be pixel-art block eyes: stepped square white eye shapes, black square/block pupils, square white highlight pixels.
Avoid the refined smoother version, smooth round eyes, long limbs, thick tube limbs, SVG/vector drawing, flat pixel-art-only output.
No text, no labels, no watermark.
```
