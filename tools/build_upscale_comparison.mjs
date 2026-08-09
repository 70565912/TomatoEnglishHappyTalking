import path from 'node:path';
import { fileURLToPath } from 'node:url';

import sharp from 'sharp';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(scriptDir, '..');
const evidenceDir = path.join(root, 'docs', 'readme', 'upscale-evidence');
const inputPath = path.join(evidenceDir, 'input-320x180.png');
const outputPath = path.join(evidenceDir, 'output-1280x720.png');
const comparisonPath = path.join(
  root,
  'docs',
  'readme',
  'upscale-comparison.webp',
);

const canvasWidth = 1800;
const canvasHeight = 1715;
const colors = {
  background: '#f4f7fb',
  panel: '#ffffff',
  ink: '#17233f',
  muted: '#5f6f86',
  line: '#d7e0eb',
  input: '#ef6b55',
  output: '#2878d0',
  note: '#eaf3ff',
};

const regions = [
  {
    key: 'A',
    label: '爱丽丝面部与发丝 / Alice face and hair',
    input: { left: 18, top: 75, width: 144, height: 81 },
  },
  {
    key: 'B',
    label: '鳄鱼眼睛、牙齿与轮廓 / Eye, teeth and outline',
    input: { left: 86, top: 24, width: 160, height: 90 },
  },
];

const escapeXml = (value) => String(value)
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;');

const text = ({ x, y, value, size, weight = 600, fill = colors.ink }) =>
  `<text x="${x}" y="${y}" font-family="Microsoft YaHei, Segoe UI, sans-serif" `
  + `font-size="${size}" font-weight="${weight}" fill="${fill}">${escapeXml(value)}</text>`;

const panel = ({ x, y, width, height, stroke = colors.line }) =>
  `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="18" `
  + `fill="${colors.panel}" stroke="${stroke}" stroke-width="3"/>`;

const baseSvg = `
<svg width="${canvasWidth}" height="${canvasHeight}" xmlns="http://www.w3.org/2000/svg">
  <rect width="100%" height="100%" fill="${colors.background}"/>
  ${panel({ x: 52, y: 142, width: 690, height: 388 })}
  <rect x="772" y="142" width="976" height="388" rx="18" fill="${colors.note}"/>
  ${panel({ x: 52, y: 584, width: 828, height: 520, stroke: colors.input })}
  ${panel({ x: 920, y: 584, width: 828, height: 520, stroke: colors.output })}
  ${panel({ x: 52, y: 1165, width: 828, height: 520, stroke: colors.input })}
  ${panel({ x: 920, y: 1165, width: 828, height: 520, stroke: colors.output })}
</svg>`;

const contextX = 72;
const contextY = 162;
const contextWidth = 650;
const contextHeight = 366;

const detailPanels = [
  { region: regions[0], y: 584 },
  { region: regions[1], y: 1165 },
];

const overlayParts = [
  text({ x: 52, y: 64, value: 'Real-ESRGAN 4x：同一区域细节放大对比', size: 38, weight: 800 }),
  text({ x: 52, y: 108, value: 'Same field of view · true 320×180 input vs 1280×720 model output', size: 24, fill: colors.muted }),
  text({ x: 800, y: 196, value: '如何阅读 / How to read', size: 28, weight: 800 }),
  text({ x: 800, y: 244, value: '• 上图仅用于定位两个裁剪区域。', size: 23 }),
  text({ x: 800, y: 286, value: '• 下方左右使用完全相同的画面范围。', size: 23 }),
  text({ x: 800, y: 328, value: '• 输入侧采用最近邻放大，不隐藏原始像素。', size: 23 }),
  text({ x: 800, y: 370, value: '• 输出侧来自 bundled realesr-animevideov3-x4。', size: 23 }),
  text({ x: 800, y: 428, value: '重点观察：发丝、眼睑、牙齿、背部轮廓和水面线条。', size: 23, weight: 700, fill: colors.output }),
  text({ x: 800, y: 474, value: '点击 README 中的图片可打开 1800 px 原图。', size: 21, fill: colors.muted }),
];

for (const { region, y } of detailPanels) {
  const outputRegion = {
    left: region.input.left * 4,
    top: region.input.top * 4,
    width: region.input.width * 4,
    height: region.input.height * 4,
  };
  const boxX = contextX + (outputRegion.left / 1280) * contextWidth;
  const boxY = contextY + (outputRegion.top / 720) * contextHeight;
  const boxWidth = (outputRegion.width / 1280) * contextWidth;
  const boxHeight = (outputRegion.height / 720) * contextHeight;
  const color = region.key === 'A' ? colors.input : colors.output;

  overlayParts.push(
    `<rect x="${boxX}" y="${boxY}" width="${boxWidth}" height="${boxHeight}" `
      + `fill="none" stroke="${color}" stroke-width="7"/>`,
    `<rect x="${boxX + 8}" y="${boxY + 8}" width="42" height="42" rx="8" fill="${color}"/>`,
    text({ x: boxX + 20, y: boxY + 39, value: region.key, size: 28, weight: 800, fill: '#ffffff' }),
    text({ x: 72, y: y - 23, value: `${region.key}  ${region.label}`, size: 25, weight: 800 }),
    text({ x: 78, y: y + 38, value: `输入 Input · ${region.input.width}×${region.input.height} px · nearest-neighbor zoom`, size: 21, weight: 700, fill: colors.input }),
    text({ x: 946, y: y + 38, value: `4x 输出 Output · ${outputRegion.width}×${outputRegion.height} px · same field of view`, size: 21, weight: 700, fill: colors.output }),
  );
}

const overlaySvg = `
<svg width="${canvasWidth}" height="${canvasHeight}" xmlns="http://www.w3.org/2000/svg">
  ${overlayParts.join('\n  ')}
</svg>`;

const inputMetadata = await sharp(inputPath).metadata();
const outputMetadata = await sharp(outputPath).metadata();
if (inputMetadata.width !== 320 || inputMetadata.height !== 180) {
  throw new Error(`Expected 320x180 input, got ${inputMetadata.width}x${inputMetadata.height}`);
}
if (outputMetadata.width !== 1280 || outputMetadata.height !== 720) {
  throw new Error(`Expected 1280x720 output, got ${outputMetadata.width}x${outputMetadata.height}`);
}

const composites = [
  {
    input: await sharp(outputPath)
      .resize(contextWidth, contextHeight, { fit: 'fill', kernel: sharp.kernel.lanczos3 })
      .png()
      .toBuffer(),
    left: contextX,
    top: contextY,
  },
];

for (const { region, y } of detailPanels) {
  const outputRegion = {
    left: region.input.left * 4,
    top: region.input.top * 4,
    width: region.input.width * 4,
    height: region.input.height * 4,
  };
  composites.push(
    {
      input: await sharp(inputPath)
        .extract(region.input)
        .resize(788, 443, { fit: 'fill', kernel: sharp.kernel.nearest })
        .png()
        .toBuffer(),
      left: 72,
      top: y + 62,
    },
    {
      input: await sharp(outputPath)
        .extract(outputRegion)
        .resize(788, 443, { fit: 'fill', kernel: sharp.kernel.lanczos3 })
        .png()
        .toBuffer(),
      left: 940,
      top: y + 62,
    },
  );
}

await sharp(Buffer.from(baseSvg))
  .composite([
    ...composites,
    { input: Buffer.from(overlaySvg), left: 0, top: 0 },
  ])
  .webp({ lossless: true, effort: 6 })
  .toFile(comparisonPath);

console.log(JSON.stringify({
  input: { path: inputPath, width: inputMetadata.width, height: inputMetadata.height },
  output: { path: outputPath, width: outputMetadata.width, height: outputMetadata.height },
  comparison: { path: comparisonPath, width: canvasWidth, height: canvasHeight },
}, null, 2));
