// Takes one picture of a page at an exact moment, in real time.
// node snap.mjs <page> <out.png> <width> <height> <scale> <setup-js> <wait-ms> [clip x,y,w,h]
import { spawn } from 'node:child_process';
import { writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const [page, out, w, h, scale, setup, waitMs, clip] = process.argv.slice(2);
const PORT = 9400 + Math.floor(Math.random() * 400);
const profile = join(tmpdir(), 'snap-' + PORT);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ['--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, '--hide-scrollbars', '--no-first-run', '--mute-audio', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let url;
for (let i = 0; i < 50 && !url; i++) {
  await sleep(200);
  try { url = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find((t) => t.type === 'page')?.webSocketDebuggerUrl; } catch {}
}
const ws = new WebSocket(url);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } });
const send = (method, params = {}) => { const n = ++id; ws.send(JSON.stringify({ id: n, method, params })); return new Promise((r) => pending.set(n, r)); };
const evaluate = async (e) => (await send('Runtime.evaluate', { expression: e, awaitPromise: true, returnByValue: true }))?.result?.value;

await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: +w, height: +h, deviceScaleFactor: +scale, mobile: false });
await send('Page.navigate', { url: 'file://' + page });
for (let i = 0; i < 100 && (await evaluate('document.readyState')) !== 'complete'; i++) await sleep(100);
await evaluate('document.fonts.ready.then(() => true)');
await evaluate(`(async () => { ${setup} })()`);
await sleep(+waitMs);
const params = { format: 'png', captureBeyondViewport: false };
if (clip) { const [x, y, cw, ch] = clip.split(',').map(Number); params.clip = { x, y, width: cw, height: ch, scale: 1 }; }
const shot = await send('Page.captureScreenshot', params);
writeFileSync(out, Buffer.from(shot.data, 'base64'));
ws.close(); chrome.kill();
await sleep(300);
rmSync(profile, { recursive: true, force: true });
console.log('wrote', out);
