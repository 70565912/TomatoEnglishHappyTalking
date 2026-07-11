/**
 * Build (optional) + run Suno fill QA in a loop until pass or max attempts.
 *
 * Usage:
 *   node tools/qa_suno_fill_loop.mjs --articleId 84 --attempts 3
 *   node tools/qa_suno_fill_loop.mjs --articleId 84 --rebuild
 */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const config = parseArgs(process.argv.slice(2));

function parseArgs(argv) {
  const options = {
    articleId: 84,
    port: 39317,
    attempts: 3,
    rebuild: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--articleId') options.articleId = Number(argv[++i]);
    else if (arg === '--port') options.port = Number(argv[++i]);
    else if (arg === '--attempts') options.attempts = Number(argv[++i]);
    else if (arg === '--rebuild') options.rebuild = true;
  }
  options.baseUrl = `http://127.0.0.1:${options.port}`;
  return options;
}

function run(command, args, opts = {}) {
  console.log(`> ${command} ${args.join(' ')}`);
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: 'inherit',
    shell: true,
    ...opts,
  });
  return result.status ?? 1;
}

async function waitForHealth(timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${config.baseUrl}/health`);
      if (res.ok) return true;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  return false;
}

async function main() {
  if (!config.rebuild && !(await waitForHealth())) {
    throw new Error(`QA health check failed: ${config.baseUrl}/health`);
  }

  for (let attempt = 1; attempt <= config.attempts; attempt += 1) {
    console.log(`\n=== Suno fill loop attempt ${attempt}/${config.attempts} ===`);
    if (config.rebuild && attempt === 1) {
      const code = run(
        process.platform === 'win32' ? 'powershell.exe' : 'pwsh',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          path.join(root, 'tools', 'qa_suno_fill_rebuild.ps1'),
        ],
        { shell: false },
      );
      if (code !== 0) {
        throw new Error('Windows rebuild failed');
      }
      if (!(await waitForHealth())) {
        throw new Error(`QA health check failed after rebuild: ${config.baseUrl}/health`);
      }
    }
    const code = run('node', [
      'tools/qa_suno_fill_quick.mjs',
      '--articleId',
      String(config.articleId),
      '--port',
      String(config.port),
    ], { shell: false });
    if (code === 0) {
      console.log(`PASS on attempt ${attempt}`);
      return;
    }
    console.error(`Attempt ${attempt} failed (exit ${code})`);
    if (attempt < config.attempts) {
      if (process.platform === 'win32') {
        run(
          'powershell.exe',
          [
            '-NoProfile',
            '-Command',
            "Get-Process tomato_english_happy_talking -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue",
          ],
          { shell: false },
        );
        await new Promise((resolve) => setTimeout(resolve, 3000));
        if (!(await waitForHealth(30_000))) {
          run(
            process.platform === 'win32' ? 'powershell.exe' : 'pwsh',
            [
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              path.join(root, 'tools', 'qa_suno_fill_rebuild.ps1'),
            ],
            { shell: false },
          );
          if (!(await waitForHealth())) {
            throw new Error(`QA health check failed after restart: ${config.baseUrl}/health`);
          }
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }

  throw new Error(`Suno fill loop failed after ${config.attempts} attempts`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
