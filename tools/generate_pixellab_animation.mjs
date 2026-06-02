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
  args.manifestPath || path.join('tools', 'pixellab_animations.json'),
);
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const token = await readPixelLabToken();
const animation = selectAnimation(manifest.animations, args.animationName);
const pollIntervalSeconds = Number(args.pollIntervalSeconds ?? manifest.pollIntervalSeconds ?? 5);
const timeoutSeconds = Number(args.timeoutSeconds ?? 240);
const outputRoot = path.resolve(workspaceRoot, manifest.outputRoot);
const appOutputRoot = path.resolve(workspaceRoot, manifest.appOutputRoot);

const sourcePath = path.resolve(workspaceRoot, animation.source);
if (!existsSync(sourcePath)) {
  throw new Error(`动画首帧不存在: ${sourcePath}`);
}

const sourceBase64 = await imageDataUrl(sourcePath);
const job = await startAnimationJob(animation, sourceBase64);
console.log(`已提交动画任务: ${job.background_job_id}`);

const result = await pollJob(job.background_job_id);
const frames = extractFrames(result);
const animationDir = path.join(outputRoot, animation.name);
const appAnimationDir = path.join(appOutputRoot, animation.name);
await mkdir(animationDir, { recursive: true });
await mkdir(appAnimationDir, { recursive: true });

const savedFrames = [];
for (let index = 0; index < frames.length; index += 1) {
  const framePath = path.join(animationDir, `frame-${String(index).padStart(2, '0')}.png`);
  const appFramePath = path.join(appAnimationDir, `frame-${String(index).padStart(2, '0')}.png`);
  const bytes = Buffer.from(normalizeBase64(frames[index]), 'base64');
  await writeFile(framePath, bytes);
  await copyFile(framePath, appFramePath);
  savedFrames.push(`frame-${String(index).padStart(2, '0')}.png`);
}

const frameManifest = {
  name: animation.name,
  source: path.basename(animation.source),
  action: animation.action,
  frameCount: frames.length,
  frameDurationMs: animation.frameDurationMs ?? 180,
  loop: true,
  frames: savedFrames,
};
await writeFile(
  path.join(animationDir, 'manifest.json'),
  `${JSON.stringify(frameManifest, null, 2)}\n`,
);
await copyFile(
  path.join(animationDir, 'manifest.json'),
  path.join(appAnimationDir, 'manifest.json'),
);

console.log(`已保存动画帧: ${animationDir}`);
console.log(`已同步动画帧: ${appAnimationDir}`);

function parseArgs(values) {
  const parsed = {
    animationName: undefined,
    manifestPath: undefined,
    pollIntervalSeconds: undefined,
    timeoutSeconds: undefined,
  };

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    switch (value) {
      case '--animation-name':
      case '-AnimationName':
        parsed.animationName = values[++index] ?? '';
        break;
      case '--manifest':
      case '-ManifestPath':
        parsed.manifestPath = values[++index] ?? '';
        break;
      case '--poll-interval-seconds':
      case '-PollIntervalSeconds':
        parsed.pollIntervalSeconds = values[++index] ?? '';
        break;
      case '--timeout-seconds':
      case '-TimeoutSeconds':
        parsed.timeoutSeconds = values[++index] ?? '';
        break;
      default:
        if (!parsed.animationName && !value.startsWith('-')) {
          parsed.animationName = value;
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

function selectAnimation(animations, animationName) {
  if (!animationName) {
    if (animations.length !== 1) {
      throw new Error('请通过 --animation-name 指定动画。');
    }
    return animations[0];
  }

  const animation = animations.find((item) => item.name === animationName);
  if (!animation) {
    throw new Error(`动画清单中找不到: ${animationName}`);
  }
  return animation;
}

async function imageDataUrl(filePath) {
  const bytes = await readFile(filePath);
  return `data:image/png;base64,${bytes.toString('base64')}`;
}

async function startAnimationJob(item, firstFrame) {
  const body = {
    action: item.action,
    first_frame: {
      base64: firstFrame,
    },
    frame_count: Number(item.frameCount ?? 8),
    no_background: item.noBackground ?? true,
    seed: Number(item.seed ?? 0),
  };

  const response = await fetch(`${manifest.baseUrl}${manifest.endpoint}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();

  if (!response.ok) {
    throw new Error(`PixelLab 返回 HTTP ${response.status}: ${text.slice(0, 500)}`);
  }

  return JSON.parse(text);
}

async function pollJob(jobId) {
  const started = Date.now();
  while (Date.now() - started < timeoutSeconds * 1000) {
    await sleep(pollIntervalSeconds * 1000);
    const response = await fetch(`${manifest.baseUrl}/background-jobs/${jobId}`, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
      },
    });
    const text = await response.text();

    if (!response.ok) {
      throw new Error(`PixelLab job 查询返回 HTTP ${response.status}: ${text.slice(0, 500)}`);
    }

    const payload = JSON.parse(text);
    console.log(`任务状态: ${payload.status}`);
    if (payload.status === 'completed') {
      return payload;
    }
    if (payload.status === 'failed') {
      throw new Error(`PixelLab 动画任务失败: ${JSON.stringify(payload.last_response ?? payload)}`);
    }
  }

  throw new Error(`PixelLab 动画任务超时: ${jobId}`);
}

function extractFrames(result) {
  const images = result?.last_response?.images ?? result?.images;
  if (!Array.isArray(images) || images.length === 0) {
    throw new Error('PixelLab 动画结果中没有 last_response.images。');
  }

  return images.map((item) => item?.base64 ?? item?.image?.base64 ?? item);
}

function normalizeBase64(value) {
  const raw = String(value);
  if (raw.startsWith('data:')) {
    return raw.slice(raw.indexOf(',') + 1);
  }
  return raw;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
