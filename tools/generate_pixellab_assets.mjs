#!/usr/bin/env node
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const toolsRoot = path.dirname(scriptPath);
const workspaceRoot = path.dirname(toolsRoot);

const args = parseArgs(process.argv.slice(2));
const manifestPath = path.resolve(
  workspaceRoot,
  args.manifestPath || path.join('tools', 'pixellab_assets.json'),
);
const timeoutSeconds = Number(args.timeoutSeconds ?? 180);

const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const token = await readPixelLabToken();
const webUiAssetsRoot = path.join(workspaceRoot, 'web_ui', 'public', 'assets', 'ui');
const appAssetsRoot = path.join(workspaceRoot, 'app', 'assets', 'web', 'assets', 'ui');

await mkdir(webUiAssetsRoot, { recursive: true });
await mkdir(appAssetsRoot, { recursive: true });

const selectedAssets = selectAssets(manifest.assets, args.assetName);

for (const asset of selectedAssets) {
  const targetPath = path.join(webUiAssetsRoot, asset.output);
  const appAssetPath = path.join(appAssetsRoot, asset.output);

  if (existsSync(targetPath) && !args.force) {
    console.log(`跳过已存在图片: ${asset.output}`);
    if (!args.skipSyncToAppAssets && !existsSync(appAssetPath)) {
      await copyFile(targetPath, appAssetPath);
      console.log(`已同步: ${appAssetPath}`);
    }
    continue;
  }

  console.log(`=== 生成 ${asset.name} ===`);
  const response = await createPixelLabImage(asset);
  const base64 = getImageBase64(response);
  const bytes = Buffer.from(base64, 'base64');
  await writeFile(targetPath, bytes);
  console.log(`已保存: ${targetPath}`);

  if (!args.skipSyncToAppAssets) {
    await copyFile(targetPath, appAssetPath);
    console.log(`已同步: ${appAssetPath}`);
  }
}

function parseArgs(values) {
  const parsed = {
    assetName: undefined,
    force: false,
    skipSyncToAppAssets: false,
    manifestPath: undefined,
    timeoutSeconds: undefined,
  };

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    switch (value) {
      case '--asset-name':
      case '-AssetName':
        parsed.assetName = values[++index] ?? '';
        break;
      case '--manifest':
      case '-ManifestPath':
        parsed.manifestPath = values[++index] ?? '';
        break;
      case '--timeout-seconds':
      case '-TimeoutSeconds':
        parsed.timeoutSeconds = values[++index] ?? '';
        break;
      case '--force':
      case '-Force':
        parsed.force = true;
        break;
      case '--skip-sync-to-app-assets':
      case '-SkipSyncToAppAssets':
        parsed.skipSyncToAppAssets = true;
        break;
      default:
        if (!parsed.assetName && !value.startsWith('-')) {
          parsed.assetName = value;
        } else {
          throw new Error(`未知参数: ${value}`);
        }
    }
  }

  return parsed;
}

async function readPixelLabToken() {
  const envToken = process.env.PIXELLAB_API_TOKEN?.trim();
  if (envToken) {
    return envToken;
  }

  const tokenPath = path.join(workspaceRoot, 'security', 'pixellab-api-token.txt');
  if (existsSync(tokenPath)) {
    const token = (await readFile(tokenPath, 'utf8')).trim();
    if (token) {
      return token;
    }
  }

  throw new Error(
    '未找到 PixelLab API token。请设置环境变量 PIXELLAB_API_TOKEN，或在 security/pixellab-api-token.txt 放入 token。',
  );
}

function selectAssets(assets, assetName) {
  if (!assetName) {
    return assets;
  }

  const selected = assets.filter(
    (asset) => asset.name === assetName || asset.output === assetName,
  );

  if (selected.length === 0) {
    throw new Error(`资产清单中找不到: ${assetName}`);
  }

  return selected;
}

async function createPixelLabImage(asset) {
  const description = `${manifest.style} ${asset.description}`;
  const body = {
    description,
    image_size: {
      width: Number(asset.width),
      height: Number(asset.height),
    },
    no_background: Boolean(asset.noBackground),
  };

  if (asset.outline) {
    body.outline = String(asset.outline);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutSeconds * 1000);

  try {
    const response = await fetch(`${manifest.baseUrl}${manifest.endpoint}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    const text = await response.text();
    if (!response.ok) {
      throw new Error(`PixelLab 返回 HTTP ${response.status}: ${text.slice(0, 500)}`);
    }

    return JSON.parse(text);
  } finally {
    clearTimeout(timeout);
  }
}

function getImageBase64(response) {
  const raw = response?.image?.base64;
  if (!raw) {
    throw new Error('PixelLab 响应中没有 image.base64 字段。');
  }

  const value = String(raw);
  if (value.startsWith('data:')) {
    return value.slice(value.indexOf(',') + 1);
  }

  return value;
}
