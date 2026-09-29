// Runs jit-scripts/ios-wine.js against a simulated StikDebug and debugserver.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = path.resolve(import.meta.dirname, '..');
const script = fs.readFileSync(path.join(root, 'jit-scripts/ios-wine.js'), 'utf8');
const BRK_F00D = 'a0013ed4';   // brk #0xf00d, little-endian
const PC = 0x100004000n;

const le = n => Array.from({length: 8}, (_, i) => Number((BigInt(n) >> BigInt(8 * i)) & 0xffn).toString(16).padStart(2, '0')).join('');
const brk = (x16, x0 = 0n, x1 = 0n) => `T05thread:1a;00:${le(x0)};01:${le(x1)};10:${le(x16)};20:${le(PC)};`;
const fault = sig => `T${sig}thread:1a;00:${le(0)};01:${le(0)};10:${le(0)};20:${le(PC + 0x100n)};`;

function run(stops, rx = 0x80000000n) {
  const sent = [], prepared = [];
  const sandbox = {
    get_pid: () => 1234,
    log: () => {},
    resume_app: () => 'OK',
    prepare_memory_region: (addr, len) => { prepared.push([BigInt(addr), BigInt(len)]); return 'OK'; },
    send_command: cmd => {
      sent.push(cmd);
      if (cmd.startsWith('vAttach')) return 'T11thread:1a;';
      if (cmd === 'c' || cmd.startsWith('vCont')) return stops.shift() ?? 'W00';
      if (cmd.startsWith('m')) return cmd.startsWith(`m${PC.toString(16)},`) ? BRK_F00D : '00000000';
      if (cmd.startsWith('_M')) return rx ? rx.toString(16) : '';
      return 'OK';
    },
  };
  vm.runInNewContext(script, sandbox);
  return {sent, prepared};
}

// Allocate only, prepare in two steps, then detach.
{
  const step = 0x2000000n;
  const {sent, prepared} = run([brk(3n, 0n, 2n * step), brk(1n, 0x80000000n, step), brk(1n, 0x80000000n + step, step), brk(0n)]);
  assert(sent.includes(`_M${(2n * step).toString(16)},rx`));
  assert.deepEqual(prepared, [[0x80000000n, step], [0x80000000n + step, step]]);
  assert.equal(sent.filter(c => c === `P0=${le(0x80000000n).slice(0, 16)};thread:1a;`).length, 2);
  assert(sent.includes(`P20=${le(PC + 4n)};thread:1a;`));
  assert.equal(sent.at(-1), 'D');
}

// The one-request path still allocates and prepares together.
{
  const {sent, prepared} = run([brk(1n, 0n, 0x4000n), brk(0n)]);
  assert(sent.includes('_M4000,rx'));
  assert.deepEqual(prepared, [[0x80000000n, 0x4000n]]);
}

// A failed allocation answers 0 so the app can tell.
{
  const {sent, prepared} = run([brk(3n, 0n, 0x4000n), brk(0n)], 0n);
  assert(sent.includes(`P0=${le(0n)};thread:1a;`));
  assert.deepEqual(prepared, []);
}

// A fault that is not a brk goes back to the app, and its reply is the next stop.
{
  const {sent} = run([fault('0b'), brk(0n)]);
  const i = sent.indexOf('vCont;S0b:1a');
  assert(i > 0 && sent[i + 1].startsWith('m') && sent.at(-1) === 'D');
}
console.log('JIT SCRIPT PASS: allocate-only, stepwise prepare, one-request prepare, failed allocation, fault forwarding, detach');
