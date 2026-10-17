// Records demo.html in headless Chrome, frame by frame, then builds a GIF and an MP4 with ffmpeg.
// Run: node record.mjs   (needs Google Chrome and ffmpeg; no npm packages)
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const frames = join(here, 'frames');
const W = 960, H = 440, SCALE = 2, PORT = 9333;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

rmSync(frames, { recursive: true, force: true });
mkdirSync(frames, { recursive: true });

const profile = join(here, '.chrome-profile');
const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, '--hide-scrollbars', '--no-first-run', '--mute-audio', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pageWs;
for (let i = 0; i < 50 && !pageWs; i++) {
  await sleep(200);
  try {
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    pageWs = list.find((t) => t.type === 'page')?.webSocketDebuggerUrl;
  } catch {}
}
if (!pageWs) { chrome.kill(); throw new Error('Chrome did not start'); }

const ws = new WebSocket(pageWs);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let id = 0;
const pending = new Map();
const shots = [];
ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); return; }
  if (msg.method === 'Page.screencastFrame') {
    const { data, metadata, sessionId } = msg.params;
    const file = join(frames, `f${String(shots.length).padStart(5, '0')}.jpg`);
    writeFileSync(file, Buffer.from(data, 'base64'));
    shots.push({ file, t: metadata.timestamp });
    send('Page.screencastFrameAck', { sessionId });
  }
});
function send(method, params = {}) {
  const n = ++id;
  ws.send(JSON.stringify({ id: n, method, params }));
  return new Promise((r) => pending.set(n, r));
}
const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }))?.result?.value;

await send('Page.enable');
await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
await send('Page.navigate', { url: 'file://' + join(here, 'demo.html') + '?record' });
for (let i = 0; i < 100 && !(await evaluate('typeof window.runDemo === "function" && document.readyState === "complete"')); i++) await sleep(100);
await evaluate('document.fonts.ready.then(() => true)');
await sleep(600);

await send('Page.startScreencast', { format: 'jpeg', quality: 95, maxWidth: W * SCALE, maxHeight: H * SCALE, everyNthFrame: 1 });
await sleep(300);
evaluate('runDemo()');
const started = Date.now();
while (!(await evaluate('window.__done === true')) && Date.now() - started < 60000) await sleep(200);
await send('Page.stopScreencast');
await sleep(300);
ws.close();
chrome.kill();

// Each frame lasts until the next one arrives
const lines = ['ffconcat version 1.0'];
shots.forEach((s, i) => {
  const next = shots[i + 1];
  const dur = next ? Math.max(0.001, next.t - s.t) : 0.6;
  lines.push(`file '${s.file}'`, `duration ${dur.toFixed(4)}`);
});
lines.push(`file '${shots[shots.length - 1].file}'`);
writeFileSync(join(frames, 'list.ffconcat'), lines.join('\n'));
const total = shots[shots.length - 1].t - shots[0].t;
console.log(`${shots.length} frames over ${total.toFixed(1)}s`);

const list = join(frames, 'list.ffconcat');
const gif = join(here, 'martin-demo.gif');
const mp4 = join(here, 'martin-demo.mp4');
execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list,
  '-vf', `fps=20,scale=${W}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle`,
  '-loop', '0', gif]);
execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list,
  '-vf', 'fps=30,format=yuv420p', '-c:v', 'libx264', '-crf', '18', '-preset', 'slow', '-movflags', '+faststart', mp4]);
console.log('wrote', gif, existsSync(gif), mp4, existsSync(mp4));
