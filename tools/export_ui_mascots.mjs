import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const roots = [
  path.resolve('web_ui/public/assets/ui/lego'),
  path.resolve('app/assets/web/assets/ui/lego'),
];

const sheet = path.resolve('docs/design-previews/lego-preview-baseline-v3/lego-speaking-animation-sheet-v3.png');
const cols = 4;
const rows = 2;
const canvas = 512;
const targetBodyCenter = { x: 256, y: 290 };

const mascotFrames = [
  { name: 'mascot-ui-idle.png', frameIndex: 6 },
  { name: 'mascot-ui-blink.png', frameIndex: 5 },
];

for (const root of roots) {
  await fs.mkdir(root, { recursive: true });
}

const metadata = await sharp(sheet).metadata();
if (!metadata.width || !metadata.height) {
  throw new Error(`Could not read image dimensions: ${sheet}`);
}

for (const frame of mascotFrames) {
  const exported = await exportFrame(frame.frameIndex, metadata);

  for (const root of roots) {
    await fs.writeFile(path.join(root, frame.name), exported);
  }
}

async function exportFrame(frameIndex, metadata) {
  const col = frameIndex % cols;
  const row = Math.floor(frameIndex / cols);
  const left = Math.round((col * metadata.width) / cols);
  const right = Math.round(((col + 1) * metadata.width) / cols);
  const top = Math.round((row * metadata.height) / rows);
  const bottom = Math.round(((row + 1) * metadata.height) / rows);
  const width = right - left;
  const height = bottom - top;

  const crop = await sharp(sheet)
    .extract({ left, top, width, height })
    .png()
    .toBuffer();
  const transparent = await removeConnectedLightBackground(crop);
  const { data, info } = await sharp(transparent)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const bodyBox = findRedBodyBounds(data, info);
  const bodyCenter = {
    x: (bodyBox.minX + bodyBox.maxX) / 2,
    y: (bodyBox.minY + bodyBox.maxY) / 2,
  };
  const output = await sharp({
    create: {
      width: canvas,
      height: canvas,
      channels: 4,
      background: { r: 255, g: 255, b: 255, alpha: 0 },
    },
  })
    .composite([
      {
        input: transparent,
        left: Math.round(targetBodyCenter.x - bodyCenter.x),
        top: Math.round(targetBodyCenter.y - bodyCenter.y),
      },
    ])
    .png()
    .toBuffer();

  return output;
}

async function removeConnectedLightBackground(input) {
  const image = sharp(input).ensureAlpha();
  const { data, info } = await image.raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  const visited = new Uint8Array(width * height);
  const queue = [];

  const enqueue = (x, y) => {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    const index = y * width + x;
    if (visited[index]) return;
    const offset = index * channels;
    if (!isLightBackground(data[offset], data[offset + 1], data[offset + 2])) return;
    visited[index] = 1;
    queue.push(index);
  };

  for (let x = 0; x < width; x += 1) {
    enqueue(x, 0);
    enqueue(x, height - 1);
  }
  for (let y = 0; y < height; y += 1) {
    enqueue(0, y);
    enqueue(width - 1, y);
  }

  for (let cursor = 0; cursor < queue.length; cursor += 1) {
    const index = queue[cursor];
    const x = index % width;
    const y = Math.floor(index / width);
    enqueue(x + 1, y);
    enqueue(x - 1, y);
    enqueue(x, y + 1);
    enqueue(x, y - 1);
  }

  for (let index = 0; index < visited.length; index += 1) {
    if (!visited[index]) continue;
    data[index * channels + 3] = 0;
  }

  return sharp(data, { raw: { width, height, channels } })
    .png()
    .toBuffer();
}

function findRedBodyBounds(data, info) {
  const { width, height, channels } = info;
  const bounds = { minX: width, minY: height, maxX: -1, maxY: -1 };

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * channels;
      if (data[offset + 3] === 0) continue;
      if (!isTomatoBody(data[offset], data[offset + 1], data[offset + 2])) continue;
      bounds.minX = Math.min(bounds.minX, x);
      bounds.minY = Math.min(bounds.minY, y);
      bounds.maxX = Math.max(bounds.maxX, x);
      bounds.maxY = Math.max(bounds.maxY, y);
    }
  }

  if (bounds.maxX < 0) {
    throw new Error('Could not find tomato body pixels for frame alignment.');
  }

  return bounds;
}

function isTomatoBody(r, g, b) {
  return r > 130 && g < 120 && b < 110 && r - g > 50 && r - b > 60;
}

function isLightBackground(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  return r > 198 && g > 192 && b > 188 && max - min < 42;
}
