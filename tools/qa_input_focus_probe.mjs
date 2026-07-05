#!/usr/bin/env node
/**
 * QA: probe HTML input focus stability inside WebView (Windows focus toggle).
 *
 * Usage:
 *   node tools/qa_input_focus_probe.mjs --port 39317
 */

const config = parseArgs(process.argv.slice(2));
const base = `http://127.0.0.1:${config.port}`;

async function main() {
  await waitForHealth();
  console.log('=== QA input focus probe ===');

  await postJson('/navigate', { path: '/settings' });
  await wait(1500);
  const settingsSnapshot = await getSnapshot();
  if (!settingsSnapshot.focusGuardInstalled) {
    throw new Error('WebView focus guard is not installed');
  }
  console.log(`Focus guard installed: ${settingsSnapshot.focusGuardInstalled}`);

  const settingsInput = (settingsSnapshot.formControls ?? []).find(
    (control) => control.tag === 'input' && !control.disabled,
  );
  if (!settingsInput) {
    throw new Error('No settings input found in snapshot');
  }

  const fillSelector = settingsInput.className.includes('secret-input')
    ? '.secret-input'
    : 'input:not([type="hidden"])';
  await postJson('/fill', { selector: fillSelector, value: 'focus-probe', index: 0 });
  await wait(150);
  const afterSettingsFill = await getSnapshot();
  console.log('Settings activeElement:', JSON.stringify(afterSettingsFill.activeElement));
  if (!afterSettingsFill.activeElement || afterSettingsFill.activeElement.tag !== 'input') {
    throw new Error(`Settings input lost focus after fill: ${JSON.stringify(afterSettingsFill.activeElement)}`);
  }

  await postJson('/navigate', { path: '/books/23/player?articleId=72&mode=listening' });
  await wait(1500);
  await postJson('/click', { text: '修改第 45 句字幕', index: 0 });
  await wait(500);

  const dialogSnapshot = await getSnapshot();
  const textarea = (dialogSnapshot.formControls ?? []).find((control) => control.tag === 'textarea');
  if (!textarea) {
    throw new Error('Sentence edit textarea not found');
  }

  await postJson('/fill', { selector: '.sentence-edit-dialog textarea', value: 'Focus probe text', index: 0 });
  await wait(150);
  const afterDialogFill = await getSnapshot();
  console.log('Dialog activeElement:', JSON.stringify(afterDialogFill.activeElement));
  if (!afterDialogFill.activeElement || afterDialogFill.activeElement.tag !== 'textarea') {
    throw new Error(`Dialog textarea lost focus after fill: ${JSON.stringify(afterDialogFill.activeElement)}`);
  }

  console.log('=== QA input focus probe: PASS ===');
}

async function getSnapshot() {
  const res = await fetch(`${base}/snapshot`);
  if (!res.ok) {
    throw new Error(`snapshot failed: ${res.status}`);
  }
  return res.json();
}

async function waitForHealth() {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) {
        const body = await res.json();
        if (body.webReady) return body;
      }
    } catch (_) {
      // retry
    }
    await wait(1000);
  }
  throw new Error(`QA server not ready at ${base}/health`);
}

async function postJson(path, body) {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch (_) {
    throw new Error(`Invalid JSON from ${path}: ${text.slice(0, 200)}`);
  }
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseArgs(argv) {
  const config = { port: 39317 };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--port') config.port = Number(argv[++i]);
  }
  return config;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
