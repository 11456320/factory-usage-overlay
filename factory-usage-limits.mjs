// Reads Factory's own usage page in a headless Chrome that keeps its own profile,
// so the overlay never depends on a tab being open, visible, or focused.
// No Factory API is called and no credential file is touched: this is a normal
// browser loading the page the user would load, and the numbers are read from
// the rendered DOM.
//
//   node factory-usage-limits.mjs            sample and print JSON
//   node factory-usage-limits.mjs --login    plain Chrome for a one-time sign-in
//
// --login deliberately starts Chrome WITHOUT the debugging port: Google refuses
// OAuth sign-in ("This browser or app may not be secure") when the browser looks
// like an automation session. It waits for that window to close, then verifies
// with a normal sample.
//
// Exit status is 0 whenever a JSON object was printed; the caller reads "ok".

import { spawn } from 'node:child_process';
import { readFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

const URL_USAGE = 'https://app.factory.ai/settings/usage';
const LOCALAPPDATA = process.env.LOCALAPPDATA;
const PROFILE = process.env.FACTORY_USAGE_PROFILE ||
  (LOCALAPPDATA + '\\factory-usage-browser');
// Per-user install first (the common one), then machine-wide, then PATH.
const CHROME = (() => {
  const tried = [
    process.env.FACTORY_USAGE_CHROME,
    LOCALAPPDATA + '\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  ].filter(Boolean);
  for (const p of tried) if (existsSync(p)) return p;
  for (const p of (process.env.PATH || '').split(';')) {
    if (!p) continue;
    const c = p.replace(/[\\/]+$/, '') + '\\chrome.exe';
    if (existsSync(c)) return c;
  }
  return null;
})();
const LOGIN = process.argv.includes('--login');
const DEADLINE_MS = 30000;

const out = (o) => { process.stdout.write(JSON.stringify(o) + '\n'); };
const die = (reason, extra = {}) => { out({ ok: false, reason, ...extra }); process.exit(0); };

if (!LOCALAPPDATA && !process.env.FACTORY_USAGE_PROFILE) die('windows_only', { detail: 'set FACTORY_USAGE_PROFILE or run on Windows' });
if (!CHROME) die('chrome_missing', { tried: 'FACTORY_USAGE_CHROME, %LOCALAPPDATA%, Program Files, PATH' });

const version = async (p) => {
  try { const r = await fetch(`http://127.0.0.1:${p}/json/version`); return r.ok ? await r.json() : null; }
  catch { return null; }
};

async function closeLiveInstance() {
  const f = PROFILE + '\\DevToolsActivePort';
  if (!existsSync(f)) return;
  const p0 = readFileSync(f, 'utf8').split('\n')[0].trim();
  const v0 = await version(p0);
  if (!v0 || !v0.webSocketDebuggerUrl) return;
  try {
    const w0 = new WebSocket(v0.webSocketDebuggerUrl);
    await new Promise((res) => {
      w0.addEventListener('open', res, { once: true });
      w0.addEventListener('error', res, { once: true });
    });
    w0.send(JSON.stringify({ id: 1, method: 'Browser.close' }));
    await sleep(800);
  } catch {}
  try { rmSync(PROFILE + '\\DevToolsActivePort', { force: true }); } catch {}
}

function connector(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let id = 0;
  const pending = new Map();
  const ready = new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });
  ws.addEventListener('message', (ev) => {
    let msg; try { msg = JSON.parse(ev.data); } catch { return; }
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); p(msg); }
  });
  const send = (method, params = {}) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    ws.send(JSON.stringify({ id: mid, method, params }));
  });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    return r.result?.result?.value;
  };
  return { ready, send, evaluate, close: () => { try { ws.close(); } catch {} } };
}

// One silent sample: headless Chrome on our own profile, read the DOM, close it.
async function sample() {
  await closeLiveInstance();
  try { rmSync(PROFILE + '\\DevToolsActivePort', { force: true }); } catch {}
  const child = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--disable-features=Translate', '--remote-debugging-port=0',
    '--user-data-dir=' + PROFILE, 'about:blank',
  ], { stdio: 'ignore' });
  child.on('error', () => {});

  let port = null;
  for (let i = 0; i < 80; i++) {
    await sleep(250);
    if (existsSync(PROFILE + '\\DevToolsActivePort')) {
      port = readFileSync(PROFILE + '\\DevToolsActivePort', 'utf8').split('\n')[0].trim();
      break;
    }
    // A plain Chrome already owns this profile: our launch handed the request to
    // it and exited, and no debug port will ever show up.
    if (child.exitCode !== null) break;
  }
  if (!port) {
    try { child.kill(); } catch {}
    return { ok: false, reason: child.exitCode !== null ? 'profile_in_use' : 'browser_failed' };
  }
  if (!(await version(port))) { try { child.kill(); } catch {} return { ok: false, reason: 'browser_unreachable' }; }

  const shutdown = async () => {
    const v = await version(port);
    if (v && v.webSocketDebuggerUrl) {
      try {
        const c = connector(v.webSocketDebuggerUrl);
        await c.ready;
        await c.send('Browser.close');
        c.close();
        await sleep(400);
      } catch {}
    }
    try { child.kill(); } catch {}
  };

  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(URL_USAGE)}`, { method: 'PUT' });
    if (!res.ok) { await shutdown(); return { ok: false, reason: 'new_target_failed' }; }
    const target = await res.json();
    const c = connector(target.webSocketDebuggerUrl);
    await c.ready;

    const started = Date.now();
    let text = '';
    while (Date.now() - started < DEADLINE_MS) {
      await sleep(600);
      text = (await c.evaluate('document.body ? document.body.innerText : ""')) || '';
      if (/5-hour usage/i.test(text)) break;
      if (/continue with email|continue with google/i.test(text)) break;
    }
    const bars = await c.evaluate(
      `JSON.stringify([...document.querySelectorAll('[role="progressbar"]')]
         .map(e => Number(e.getAttribute('aria-valuenow'))))`);
    c.close();

    let result;
    if (/5-hour usage/i.test(text)) {
      const nums = text.match(/(\d+)\s*%/g)?.map((s) => parseInt(s, 10)) ?? [];
      let progress = [];
      try { progress = JSON.parse(bars ?? '[]').filter((n) => Number.isFinite(n)); } catch {}
      const pick = (i) => (Number.isFinite(progress[i]) ? progress[i]
        : Number.isFinite(nums[i]) ? nums[i] : null);
      const m = text.match(/\$\s?([\d,]+\.\d{2})/);
      result = {
        ok: true,
        fiveHour: pick(0), weekly: pick(1), monthly: pick(2),
        extra: m ? m[1].replace(/,/g, '') : null,
        source: 'headless-dom',
      };
    } else if (/continue with email|continue with google|sign up/i.test(text)) {
      result = { ok: false, reason: 'needs_login' };
    } else {
      result = { ok: false, reason: 'no_usage_text', chars: text.length };
    }
    await shutdown();
    return result;
  } catch (e) {
    await shutdown();
    return { ok: false, reason: 'error', detail: String((e && e.message) || e) };
  }
}

if (LOGIN) {
  // Plain Chrome, no debugging flags: the sign-in provider must see an ordinary
  // browser. We only wait for that window to close, then verify with a sample.
  const login = spawn(CHROME, ['--no-first-run', '--no-default-browser-check',
    '--user-data-dir=' + PROFILE, URL_USAGE], { stdio: 'ignore' });
  login.on('error', () => {});
  await new Promise((res) => { login.on('exit', res); login.on('error', res); });
  const check = await sample();
  if (check.ok) {
    // hand the first reading to the overlay's cache so the card fills at once
    try {
      writeFileSync(process.env.LOCALAPPDATA + '\\factory-usage-overlay.limits.json',
        JSON.stringify({ at: new Date().toISOString(), limits: {
          fiveHour: check.fiveHour, weekly: check.weekly, monthly: check.monthly, extra: check.extra } }));
    } catch {}
  }
  out(check);
  process.exit(0);
}

out(await sample());
process.exit(0);
