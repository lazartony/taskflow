#!/usr/bin/env node
// Capture a CPU profile from a running Node process over the Chrome DevTools
// Protocol, without restarting it.
//
//   node scripts/lib/node-cpuprofile.mjs <inspector-url> <seconds> <output.cpuprofile>
//   node scripts/lib/node-cpuprofile.mjs http://localhost:9229 30 cpu.cpuprofile
//
// The target must have been started with --inspect. Two things matter about
// that flag:
//
//   • Bind to 127.0.0.1, never 0.0.0.0. The inspector protocol is unauthenticated
//     and can evaluate arbitrary code in the process. An exposed inspector port
//     is remote code execution, not a debugging convenience.
//   • Use --inspect, not --inspect-brk, unless you want the process to sit
//     paused waiting for a debugger to attach.
//
// Why this instead of `--cpu-prof`: --cpu-prof only writes its output when the
// process EXITS. That is fine for a benchmark you are going to stop anyway and
// useless during an incident. This attaches and detaches at will.
//
// Zero dependencies: Node 22 ships a global WebSocket.

const [, , rawUrl, rawSeconds, rawOut] = process.argv;

if (!rawUrl || rawUrl === '--help' || rawUrl === '-h') {
  console.log(
    'usage: node-cpuprofile.mjs <inspector-http-url> <seconds> <output.cpuprofile>\n' +
    '   eg: node-cpuprofile.mjs http://localhost:9229 30 cpu.cpuprofile',
  );
  process.exit(rawUrl ? 0 : 2);
}

const seconds = Number(rawSeconds || 30);
const outPath = rawOut || 'cpu.cpuprofile';

const die = (msg) => {
  console.error(`node-cpuprofile: ${msg}`);
  process.exit(1);
};

// Discover the target's WebSocket debugger URL.
let targets;
try {
  const res = await fetch(new URL('/json/list', rawUrl), { signal: AbortSignal.timeout(5000) });
  targets = await res.json();
} catch (e) {
  die(
    `could not reach the inspector at ${rawUrl} (${e.message}).\n` +
    '  Start the service with NODE_OPTIONS="--inspect=127.0.0.1:9229" and publish\n' +
    '  the port in the benchmark environment only.',
  );
}

const target = (targets || []).find((t) => t.webSocketDebuggerUrl);
if (!target) die('the inspector is reachable but exposes no debuggable target');

const ws = new WebSocket(target.webSocketDebuggerUrl);
let nextId = 1;
const pending = new Map();

const send = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params: params || {} }));
  });

ws.addEventListener('message', (ev) => {
  let msg;
  try {
    msg = JSON.parse(ev.data);
  } catch {
    return;
  }
  if (msg.id === undefined) return; // an event, not a reply
  const p = pending.get(msg.id);
  if (!p) return;
  pending.delete(msg.id);
  if (msg.error) p.reject(new Error(msg.error.message));
  else p.resolve(msg.result);
});

ws.addEventListener('error', () => die('websocket error talking to the inspector'));

await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  setTimeout(() => reject(new Error('timed out')), 10_000).unref?.();
}).catch(() => die('could not open a websocket to the inspector'));

try {
  await send('Profiler.enable');
  // 1 ms is V8's default. Finer sampling costs more overhead and, on a service
  // that is mostly waiting on IO, buys nothing.
  await send('Profiler.setSamplingInterval', { interval: 1000 });
  await send('Profiler.start');
  console.error(`node-cpuprofile: sampling for ${seconds}s…`);
  await new Promise((r) => setTimeout(r, seconds * 1000));
  const { profile } = await send('Profiler.stop');
  const { writeFile } = await import('node:fs/promises');
  await writeFile(outPath, JSON.stringify(profile));
  console.error(
    `node-cpuprofile: wrote ${outPath}\n` +
    '  Open it in Chrome DevTools → Performance → Load, or: npx speedscope ' + outPath,
  );
  ws.close();
  process.exit(0);
} catch (e) {
  die(`profiling failed: ${e.message}`);
}
