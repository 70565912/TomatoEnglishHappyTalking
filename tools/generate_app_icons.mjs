import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const source = path.resolve('web_ui/public/assets/ui/lego/prop-tomato.png');
const windowsIcon = path.resolve('app/windows/runner/resources/app_icon.ico');
const androidIconSizes = [
  ['mipmap-mdpi', 48],
  ['mipmap-hdpi', 72],
  ['mipmap-xhdpi', 96],
  ['mipmap-xxhdpi', 144],
  ['mipmap-xxxhdpi', 192],
];
const icoSizes = [16, 24, 32, 48, 64, 128, 256];

await assertReadable(source);
const cleanSource = await cleanIconSource(source);

for (const [folder, size] of androidIconSizes) {
  const file = path.resolve('app/android/app/src/main/res', folder, 'ic_launcher.png');
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, await renderIconPng(size));
}

await fs.mkdir(path.dirname(windowsIcon), { recursive: true });
await fs.writeFile(windowsIcon, await buildIco(icoSizes));

console.log(`Generated tomato app icons from ${path.relative(process.cwd(), source)}`);
console.log(`Windows: ${path.relative(process.cwd(), windowsIcon)}`);
for (const [folder] of androidIconSizes) {
  console.log(`Android: app/android/app/src/main/res/${folder}/ic_launcher.png`);
}

async function assertReadable(file) {
  try {
    await fs.access(file);
  } catch {
    throw new Error(`Missing icon source: ${file}`);
  }
}

async function renderIconPng(size) {
  if (size <= 32) {
    return renderSmallTomatoPng(size);
  }

  return renderDetailedTomatoPng(size);
}

async function renderDetailedTomatoPng(size) {
  const innerSize = Math.round(size * 0.88);
  const transparent = { r: 0, g: 0, b: 0, alpha: 0 };
  return sharp(cleanSource)
    .ensureAlpha()
    .trim({ background: transparent, threshold: 12 })
    .resize({
      width: innerSize,
      height: innerSize,
      fit: 'contain',
      kernel: sharp.kernel.lanczos3,
      background: transparent,
    })
    .extend({
      top: Math.floor((size - innerSize) / 2),
      bottom: Math.ceil((size - innerSize) / 2),
      left: Math.floor((size - innerSize) / 2),
      right: Math.ceil((size - innerSize) / 2),
      background: transparent,
    })
    .png()
    .toBuffer();
}

async function renderSmallTomatoPng(size) {
  const scale = size / 32;
  const stroke = Math.max(1, Math.round(size / 18));
  const svg = `
<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 32 32">
  <path d="M15.8 7.6c-.9-2-2.8-3.4-5.1-3.8 2.5-1 5.1-.5 6.9 1.4.9-1.8 2.5-3 4.5-3.6-.2 2.4-1.1 4.3-2.7 5.5 2.4-.2 4.5.4 6.3 1.7-2.2 1.4-4.5 1.8-6.8 1.1.6 1.4.6 2.8.1 4.2-1.3-1-2.2-2.3-2.6-4-1.6 1.1-3.6 1.5-6 1.1 1.2-1.8 3-2.9 5.4-3.6z" fill="#55b72f" stroke="#206b15" stroke-width="${stroke}" stroke-linejoin="round"/>
  <circle cx="16" cy="18" r="10.6" fill="#f14528" stroke="#9d1d14" stroke-width="${stroke}"/>
  <path d="M8.8 15.2c2-3.1 5.4-4.8 9-4.3" fill="none" stroke="#ff8a62" stroke-width="${Math.max(1, stroke)}" stroke-linecap="round" opacity=".72"/>
  <path d="M22.5 14.5c1.9 2.8 1.7 7.4-.8 10.2" fill="none" stroke="#b91f19" stroke-width="${Math.max(1, stroke)}" stroke-linecap="round" opacity=".62"/>
</svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

async function cleanIconSource(file) {
  const { data, info } = await sharp(file)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const index = (y * info.width + x) * info.channels;
      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      const alpha = data[index + 3];
      if (alpha === 0) {
        continue;
      }

      const saturation = Math.max(red, green, blue) - Math.min(red, green, blue);
      const lowerIconArea = y > info.height * 0.68;
      const redLike = lowerIconArea
        ? red > 70 && red > green + 34 && red > blue + 30 && saturation > 42
        : red > 55 && red > green + 16 && red > blue + 14;
      const greenLike = green > 55 && green > red - 8 && green > blue + 8;

      if (lowerIconArea && !redLike && !greenLike) {
        data[index + 3] = 0;
      }
    }
  }

  return sharp(data, { raw: info }).png().toBuffer();
}

async function buildIco(sizes) {
  const pngs = await Promise.all(sizes.map((size) => renderIconPng(size)));
  const headerSize = 6;
  const entrySize = 16;
  const imageOffsetStart = headerSize + entrySize * sizes.length;
  const header = Buffer.alloc(imageOffsetStart);

  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);

  let imageOffset = imageOffsetStart;
  sizes.forEach((size, index) => {
    const entryOffset = headerSize + index * entrySize;
    const png = pngs[index];
    header.writeUInt8(size >= 256 ? 0 : size, entryOffset);
    header.writeUInt8(size >= 256 ? 0 : size, entryOffset + 1);
    header.writeUInt8(0, entryOffset + 2);
    header.writeUInt8(0, entryOffset + 3);
    header.writeUInt16LE(1, entryOffset + 4);
    header.writeUInt16LE(32, entryOffset + 6);
    header.writeUInt32LE(png.length, entryOffset + 8);
    header.writeUInt32LE(imageOffset, entryOffset + 12);
    imageOffset += png.length;
  });

  return Buffer.concat([header, ...pngs]);
}
