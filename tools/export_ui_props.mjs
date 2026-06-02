import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const roots = [
  path.resolve('web_ui/public/assets/ui/lego'),
  path.resolve('app/assets/web/assets/ui/lego'),
];

const sheet = path.resolve('docs/design-previews/lego-preview-baseline-v3/lego-props-element-sheet-v3.png');
const cols = 4;
const rows = 3;
const props = [
  'prop-star.png',
  'prop-tomato.png',
  'prop-microphone.png',
  'prop-headphones.png',
  'prop-pencil.png',
  'prop-book.png',
  'prop-speech-bubble.png',
  'prop-rocket.png',
  'prop-monster.png',
  'prop-shield.png',
  'prop-clock.png',
  'prop-bricks.png',
];

for (const root of roots) {
  await fs.mkdir(root, { recursive: true });
}

const metadata = await sharp(sheet).metadata();
if (!metadata.width || !metadata.height) {
  throw new Error(`Could not read image dimensions: ${sheet}`);
}

for (const [index, name] of props.entries()) {
  const png = await exportProp(index, metadata, name);

  for (const root of roots) {
    await fs.writeFile(path.join(root, name), png);
  }
}

async function exportProp(index, metadata, name) {
  const col = index % cols;
  const row = Math.floor(index / cols);
  const left = Math.round((col * metadata.width) / cols);
  const right = Math.round(((col + 1) * metadata.width) / cols);
  const top = Math.round((row * metadata.height) / rows);
  const bottom = Math.round(((row + 1) * metadata.height) / rows);

  const crop = await sharp(sheet)
    .extract({ left, top, width: right - left, height: bottom - top })
    .png()
    .toBuffer();

  const withoutLightBackground = await removeConnectedBackground(
    crop,
    isLightBackground,
  );
  const transparent = await removeConnectedBackground(
    withoutLightBackground,
    isDarkSheetBorder,
  );
  const clean = ['prop-star.png', 'prop-bricks.png'].includes(name)
    ? await removeEveryMatchingPixel(transparent, isDarkSheetBorder)
    : transparent;
  return fitTransparentContent(clean, 384, 24);
}

async function removeConnectedBackground(input, isBackgroundPixel) {
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
    if (
      !isBackgroundPixel(
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
      )
    ) {
      return;
    }
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

async function removeEveryMatchingPixel(input, isBackgroundPixel) {
  const image = sharp(input).ensureAlpha();
  const { data, info } = await image.raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;

  for (let index = 0; index < width * height; index += 1) {
    const offset = index * channels;
    if (
      isBackgroundPixel(
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
      )
    ) {
      data[offset + 3] = 0;
    }
  }

  return sharp(data, { raw: { width, height, channels } })
    .png()
    .toBuffer();
}

function isLightBackground(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  return r > 198 && g > 192 && b > 188 && max - min < 42;
}

function isDarkSheetBorder(r, g, b, a) {
  if (a === 0) return false;
  return r < 48 && g < 48 && b < 48;
}

async function fitTransparentContent(input, size, padding) {
  const { data, info } = await sharp(input)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const bounds = findAlphaBounds(data, info);
  const crop = await sharp(input)
    .extract({
      left: bounds.minX,
      top: bounds.minY,
      width: bounds.maxX - bounds.minX + 1,
      height: bounds.maxY - bounds.minY + 1,
    })
    .resize({
      width: size - padding * 2,
      height: size - padding * 2,
      fit: 'contain',
      background: { r: 255, g: 255, b: 255, alpha: 0 },
    })
    .png()
    .toBuffer();
  const resized = await sharp(crop).metadata();
  const width = resized.width ?? size - padding * 2;
  const height = resized.height ?? size - padding * 2;

  return sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background: { r: 255, g: 255, b: 255, alpha: 0 },
    },
  })
    .composite([
      {
        input: crop,
        left: Math.round((size - width) / 2),
        top: Math.round((size - height) / 2),
      },
    ])
    .png()
    .toBuffer();
}

function findAlphaBounds(data, info) {
  const bounds = {
    minX: info.width,
    minY: info.height,
    maxX: -1,
    maxY: -1,
  };

  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      const alpha = data[(y * info.width + x) * info.channels + 3];
      if (alpha === 0) continue;
      bounds.minX = Math.min(bounds.minX, x);
      bounds.minY = Math.min(bounds.minY, y);
      bounds.maxX = Math.max(bounds.maxX, x);
      bounds.maxY = Math.max(bounds.maxY, y);
    }
  }

  if (bounds.maxX < 0) {
    throw new Error('Could not find visible pixels in prop image.');
  }

  return bounds;
}
