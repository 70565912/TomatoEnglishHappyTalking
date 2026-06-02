import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const sourceRoot = path.resolve('docs/design-previews/generated-ui-assets/source');
const previewRoot = path.resolve('docs/design-previews/generated-ui-assets/processed');
const assetRoots = [
  path.resolve('web_ui/public/assets/ui/lego'),
  path.resolve('app/assets/web/assets/ui/lego'),
];

const mascotSize = 512;
const propSize = 384;

const sources = {
  tomatoIdle: 'tomato-idle-source.png',
  tomatoBlink: 'tomato-blink-source.png',
  brandTomato: 'brand-tomato-source.png',
  headphones: 'headphones-source.png',
  microphone: 'microphone-source.png',
  scoreShield: 'score-shield-source.png',
  monster: 'monster-source.png',
};

for (const root of [...assetRoots, previewRoot]) {
  await fs.mkdir(root, { recursive: true });
}

const [idleCanvas, blinkCanvas] = await createMascotCanvases();
const blinkFrames = await createBlinkFrames(idleCanvas, blinkCanvas);

for (const [index, frame] of blinkFrames.entries()) {
  const name = `mascot-blink/frame-${String(index + 1).padStart(2, '0')}.png`;
  await writeToTargets(name, frame);
}
await writeToTargets('mascot-ui-idle.png', blinkFrames[0]);
await writeToTargets('mascot-ui-blink.png', blinkFrames[3]);

await buildProp('brand-tomato.png', sources.brandTomato, 62);
await buildProp('prop-headphones.png', sources.headphones, 58);
await buildProp('prop-microphone.png', sources.microphone, 58);
await buildProp('prop-shield.png', sources.scoreShield, 58);
await buildProp('prop-monster.png', sources.monster, 54);

console.log('Done: generated UI assets normalized and exported.');

async function createMascotCanvases() {
  const idle = await removeMagentaBackground(path.join(sourceRoot, sources.tomatoIdle));
  const blink = await removeMagentaBackground(path.join(sourceRoot, sources.tomatoBlink));
  const idleBounds = await getAlphaBounds(idle);
  const sidePadding = 34;
  const topPadding = 26;
  const bottomPadding = 40;
  const scale = Math.min(
    (mascotSize - sidePadding * 2) / idleBounds.width,
    (mascotSize - topPadding - bottomPadding) / idleBounds.height,
  );
  const idleCanvas = await fitBoundsToCanvas(idle, {
    bounds: idleBounds,
    size: mascotSize,
    scale,
    bottomPadding,
  });
  const idleRaw = await sharp(idleCanvas).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const idleBody = findTomatoBodyBounds(idleRaw.data, idleRaw.info);

  return [
    idleCanvas,
    await fitMascotToBody(blink, idleBody),
  ];
}

async function createBlinkFrames(idleCanvas, blinkCanvas) {
  const idle = await sharp(idleCanvas).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const blink = await sharp(blinkCanvas).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const body = findTomatoBodyBounds(idle.data, idle.info);
  const mask = {
    centerX: (body.minX + body.maxX) / 2,
    centerY: body.minY + body.height * 0.42,
    radiusX: body.width * 0.44,
    radiusY: body.height * 0.27,
  };
  const weights = [0, 0.28, 0.64, 1, 0.64, 0.28, 0];

  return Promise.all(
    weights.map((weight) => renderBlinkFrame(idle, blink, mask, weight)),
  );
}

async function renderBlinkFrame(idle, blink, mask, weight) {
  const data = new Uint8ClampedArray(idle.data);
  const { width, height, channels } = idle.info;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const nx = (x - mask.centerX) / mask.radiusX;
      const ny = (y - mask.centerY) / mask.radiusY;
      const distance = Math.sqrt(nx * nx + ny * ny);
      if (distance >= 1) continue;

      const feather = distance < 0.96 ? 1 : (1 - distance) / 0.04;
      const amount = weight * feather;
      const offset = (y * width + x) * channels;

      if (idle.data[offset + 3] === 0 || blink.data[offset + 3] === 0) continue;

      data[offset] = Math.round(idle.data[offset] * (1 - amount) + blink.data[offset] * amount);
      data[offset + 1] = Math.round(idle.data[offset + 1] * (1 - amount) + blink.data[offset + 1] * amount);
      data[offset + 2] = Math.round(idle.data[offset + 2] * (1 - amount) + blink.data[offset + 2] * amount);
      data[offset + 3] = idle.data[offset + 3];
    }
  }

  return sharp(data, { raw: idle.info }).png().toBuffer();
}

async function buildProp(outputName, sourceName, padding) {
  const transparent = await removeMagentaBackground(path.join(sourceRoot, sourceName));
  const bounds = await getAlphaBounds(transparent);
  const scale = Math.min(
    (propSize - padding * 2) / bounds.width,
    (propSize - padding * 2) / bounds.height,
  );
  const png = await fitBoundsToCanvas(transparent, {
    bounds,
    size: propSize,
    scale,
    bottomPadding: padding,
  });
  await writeToTargets(outputName, png);
}

async function fitMascotToBody(input, targetBody) {
  const { data, info } = await sharp(input)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const alphaBounds = findAlphaBounds(data, info);
  const bodyBounds = findTomatoBodyBounds(data, info);
  const scale = targetBody.width / bodyBounds.width;
  const crop = await sharp(input)
    .extract({
      left: alphaBounds.minX,
      top: alphaBounds.minY,
      width: alphaBounds.maxX - alphaBounds.minX + 1,
      height: alphaBounds.maxY - alphaBounds.minY + 1,
    })
    .resize({
      width: Math.round((alphaBounds.maxX - alphaBounds.minX + 1) * scale),
      height: Math.round((alphaBounds.maxY - alphaBounds.minY + 1) * scale),
      fit: 'fill',
    })
    .png()
    .toBuffer();
  const metadata = await sharp(crop).metadata();
  const targetCenterX = (targetBody.minX + targetBody.maxX) / 2;
  const targetCenterY = (targetBody.minY + targetBody.maxY) / 2;
  const sourceCenterX = ((bodyBounds.minX + bodyBounds.maxX) / 2 - alphaBounds.minX) * scale;
  const sourceCenterY = ((bodyBounds.minY + bodyBounds.maxY) / 2 - alphaBounds.minY) * scale;
  const left = Math.round(targetCenterX - sourceCenterX);
  const top = Math.round(targetCenterY - sourceCenterY);

  return sharp({
    create: {
      width: mascotSize,
      height: mascotSize,
      channels: 4,
      background: { r: 255, g: 255, b: 255, alpha: 0 },
    },
  })
    .composite([
      {
        input: crop,
        left: Math.max(0, Math.min(mascotSize - (metadata.width ?? 0), left)),
        top: Math.max(0, Math.min(mascotSize - (metadata.height ?? 0), top)),
      },
    ])
    .png()
    .toBuffer();
}

async function removeMagentaBackground(filePath) {
  const image = sharp(filePath).ensureAlpha();
  const { data, info } = await image.raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;

  for (let index = 0; index < width * height; index += 1) {
    const offset = index * channels;
    const r = data[offset];
    const g = data[offset + 1];
    const b = data[offset + 2];
    const isMagenta = r > 170 && b > 145 && g < 125 && r - g > 78 && b - g > 70;

    if (!isMagenta) continue;
    data[offset + 3] = 0;
  }

  return sharp(data, { raw: info }).png().toBuffer();
}

async function fitBoundsToCanvas(input, { bounds, size, scale, bottomPadding }) {
  const crop = await sharp(input)
    .extract({
      left: bounds.minX,
      top: bounds.minY,
      width: bounds.width,
      height: bounds.height,
    })
    .resize({
      width: Math.round(bounds.width * scale),
      height: Math.round(bounds.height * scale),
      fit: 'fill',
    })
    .png()
    .toBuffer();
  const metadata = await sharp(crop).metadata();
  const width = metadata.width ?? Math.round(bounds.width * scale);
  const height = metadata.height ?? Math.round(bounds.height * scale);

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
        top: Math.round(size - bottomPadding - height),
      },
    ])
    .png()
    .toBuffer();
}

async function getAlphaBounds(input) {
  const { data, info } = await sharp(input)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const bounds = findAlphaBounds(data, info);
  return {
    ...bounds,
    width: bounds.maxX - bounds.minX + 1,
    height: bounds.maxY - bounds.minY + 1,
  };
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
      const offset = (y * info.width + x) * info.channels;
      if (data[offset + 3] === 0) continue;
      bounds.minX = Math.min(bounds.minX, x);
      bounds.minY = Math.min(bounds.minY, y);
      bounds.maxX = Math.max(bounds.maxX, x);
      bounds.maxY = Math.max(bounds.maxY, y);
    }
  }

  if (bounds.maxX < 0) {
    throw new Error('Could not find visible pixels in generated image.');
  }

  return bounds;
}

function findTomatoBodyBounds(data, info) {
  const { width, height, channels } = info;
  const redPixels = new Uint8Array(width * height);
  const visited = new Uint8Array(width * height);
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      const offset = (y * width + x) * channels;
      const r = data[offset];
      const g = data[offset + 1];
      const b = data[offset + 2];
      const redBody = data[offset + 3] > 0 && r > 125 && g < 115 && b < 95 && r - g > 50 && r - b > 65;
      if (redBody) redPixels[y * width + x] = 1;
    }
  }

  let best = null;
  const queue = [];
  for (let start = 0; start < redPixels.length; start += 1) {
    if (!redPixels[start] || visited[start]) continue;

    const component = {
      count: 0,
      minX: width,
      minY: height,
      maxX: -1,
      maxY: -1,
    };
    visited[start] = 1;
    queue.length = 0;
    queue.push(start);

    for (let cursor = 0; cursor < queue.length; cursor += 1) {
      const index = queue[cursor];
      const x = index % width;
      const y = Math.floor(index / width);
      component.count += 1;
      component.minX = Math.min(component.minX, x);
      component.minY = Math.min(component.minY, y);
      component.maxX = Math.max(component.maxX, x);
      component.maxY = Math.max(component.maxY, y);

      for (const next of [index + 1, index - 1, index + width, index - width]) {
        if (next < 0 || next >= redPixels.length) continue;
        if ((index % width === width - 1 && next === index + 1) || (index % width === 0 && next === index - 1)) continue;
        if (!redPixels[next] || visited[next]) continue;
        visited[next] = 1;
        queue.push(next);
      }
    }

    if (!best || component.count > best.count) best = component;
  }

  if (!best) {
    throw new Error('Could not find tomato body pixels in generated mascot.');
  }

  return {
    ...best,
    width: best.maxX - best.minX + 1,
    height: best.maxY - best.minY + 1,
  };
}

async function writeToTargets(relativePath, bytes) {
  await fs.mkdir(path.join(previewRoot, path.dirname(relativePath)), { recursive: true });
  await fs.writeFile(path.join(previewRoot, relativePath), bytes);

  for (const root of assetRoots) {
    const output = path.join(root, relativePath);
    await fs.mkdir(path.dirname(output), { recursive: true });
    await fs.writeFile(output, bytes);
  }
}
