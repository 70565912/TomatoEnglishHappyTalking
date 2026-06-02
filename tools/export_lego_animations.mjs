#!/usr/bin/env node
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import gifenc from 'gifenc';

const { GIFEncoder, applyPalette, quantize } = gifenc;

const scriptPath = fileURLToPath(import.meta.url);
const toolsRoot = path.dirname(scriptPath);
const workspaceRoot = path.dirname(toolsRoot);

const sourceRoot = path.join(
  workspaceRoot,
  'docs',
  'design-previews',
  'lego-preview-baseline-v3',
);
const assetRoots = [
  path.join(workspaceRoot, 'web_ui', 'public', 'assets', 'ui', 'lego'),
  path.join(workspaceRoot, 'app', 'assets', 'web', 'assets', 'ui', 'lego'),
];

const animations = [
  {
    name: 'wave',
    sheet: 'lego-wave-animation-sheet-v3.png',
    delayMs: 110,
  },
  {
    name: 'speaking',
    sheet: 'lego-speaking-animation-sheet-v3.png',
    delayMs: 105,
  },
  {
    name: 'success',
    sheet: 'lego-success-animation-sheet-v3.png',
    delayMs: 115,
  },
];

const manifest = {
  version: 'lego-preview-baseline-v3',
  baseline: 'docs/design-previews/generated-tomato-mascot-lego-preview.png',
  generatedAt: new Date().toISOString(),
  animations: {},
};

for (const animation of animations) {
  const result = await exportAnimation(animation);
  manifest.animations[animation.name] = result;
}

await writeJsonToTargets('animations/manifest.json', manifest);
console.log('Done: exported lego animation frames, GIFs, WebPs, and manifest.');

async function exportAnimation(animation) {
  const sheetPath = path.join(sourceRoot, animation.sheet);
  const metadata = await sharp(sheetPath).metadata();

  if (!metadata.width || !metadata.height) {
    throw new Error(`Could not read image dimensions: ${sheetPath}`);
  }

  const cols = 4;
  const rows = 2;
  const frameCount = cols * rows;
  const targetWidth = Math.ceil(metadata.width / cols);
  const targetHeight = Math.ceil(metadata.height / rows);
  const frameRoot = path.join(sourceRoot, 'animations', animation.name);

  await mkdir(frameRoot, { recursive: true });
  for (const assetRoot of assetRoots) {
    await mkdir(path.join(assetRoot, 'animations', animation.name), { recursive: true });
  }

  const framePaths = [];
  for (let index = 0; index < frameCount; index += 1) {
    const col = index % cols;
    const row = Math.floor(index / cols);
    const left = Math.round((col * metadata.width) / cols);
    const right = Math.round(((col + 1) * metadata.width) / cols);
    const top = Math.round((row * metadata.height) / rows);
    const bottom = Math.round(((row + 1) * metadata.height) / rows);
    const width = right - left;
    const height = bottom - top;
    const frameName = `frame-${String(index + 1).padStart(2, '0')}.png`;
    const outPath = path.join(frameRoot, frameName);

    const crop = await sharp(sheetPath)
      .extract({ left, top, width, height })
      .png()
      .toBuffer();

    await sharp({
      create: {
        width: targetWidth,
        height: targetHeight,
        channels: 4,
        background: '#fbf8f3',
      },
    })
      .composite([
        {
          input: crop,
          left: Math.floor((targetWidth - width) / 2),
          top: Math.floor((targetHeight - height) / 2),
        },
      ])
      .png()
      .toFile(outPath);

    await copyToAssetRoots(
      outPath,
      path.join('animations', animation.name, frameName),
    );
    framePaths.push(outPath);
  }

  const gifName = `lego-${animation.name}-animation-v3.gif`;
  const gifPath = path.join(sourceRoot, gifName);
  const gifBytes = await createGif(framePaths, animation.delayMs);
  await writeFile(gifPath, gifBytes);
  await copyToAssetRoots(gifPath, gifName);

  const webpName = `lego-${animation.name}-animation-v3.webp`;
  const webpPath = path.join(sourceRoot, webpName);
  await sharp(gifBytes, { animated: true })
    .webp({ quality: 86, effort: 4, loop: 0, delay: animation.delayMs })
    .toFile(webpPath);
  await copyToAssetRoots(webpPath, webpName);

  return {
    delayMs: animation.delayMs,
    frameCount,
    frameSize: {
      width: targetWidth,
      height: targetHeight,
    },
    frames: framePaths.map((_, index) => {
      return `assets/ui/lego/animations/${animation.name}/frame-${String(index + 1).padStart(2, '0')}.png`;
    }),
    gif: `assets/ui/lego/${gifName}`,
    webp: `assets/ui/lego/${webpName}`,
  };
}

async function createGif(framePaths, delayMs) {
  const gif = GIFEncoder();

  for (const framePath of framePaths) {
    const { data, info } = await sharp(framePath)
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    const palette = quantize(data, 256);
    const index = applyPalette(data, palette);
    gif.writeFrame(index, info.width, info.height, {
      palette,
      delay: delayMs,
      repeat: 0,
    });
  }

  gif.finish();
  return Buffer.from(gif.bytes());
}

async function copyToAssetRoots(sourcePath, relativePath) {
  for (const assetRoot of assetRoots) {
    const targetPath = path.join(assetRoot, relativePath);
    await mkdir(path.dirname(targetPath), { recursive: true });
    await copyFile(sourcePath, targetPath);
  }
}

async function writeJsonToTargets(relativePath, value) {
  const bytes = `${JSON.stringify(value, null, 2)}\n`;
  const docPath = path.join(sourceRoot, relativePath);
  await mkdir(path.dirname(docPath), { recursive: true });
  await writeFile(docPath, bytes);

  for (const assetRoot of assetRoots) {
    const targetPath = path.join(assetRoot, relativePath);
    await mkdir(path.dirname(targetPath), { recursive: true });
    await writeFile(targetPath, bytes);
  }
}
