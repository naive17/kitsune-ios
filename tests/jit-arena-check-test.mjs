import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests/jit-arena');
fs.mkdirSync(scratch, {recursive: true});
const source = fs.readFileSync(path.join(root, 'scripts/dev/ensure-jit-run.sh'), 'utf8');
const begin = source.indexOf('      if [ "$MIN_ARENA_MB" -gt 0 ]; then');
const end = source.indexOf('      echo "JIT-RUN-CONFIRMED', begin);
assert(begin >= 0 && end > begin);
const check = `set -u\nfor i in 1; do\n${source.slice(begin, end)}\necho ACCEPTED\ndone`;
for (const [min, log, accepted, message] of [
  [1024, '0024:err:virtual:init_ios_arena ios: arena 0x120010000-0x160010000 delta 0x6edfff0000', true, '1024 MB'],
  [1024, '0024:err:virtual:init_ios_arena ios: arena 0x142800000-0x16a800000 delta 0x6ebd800000', false, 'undersized JIT arena'],
  [1024, '=== entering __wine_main ===', false, 'waiting for arena size'],
  [0, '=== entering __wine_main ===', true, 'ACCEPTED'],
]) {
  fs.writeFileSync(path.join(scratch, 'snapchk.log'), log + '\n');
  const output = execFileSync('bash', ['-c', check], {
    env: {...process.env, SP: scratch, MIN_ARENA_MB: String(min)}, encoding: 'utf8',
  });
  assert.equal(output.includes('ACCEPTED'), accepted);
  assert(output.includes(message));
}
console.log('JIT-ARENA PASS: full arena accepted, partial rejected, missing diagnostic waits, optional gate remains optional');

// A transport timeout is not proof that a process died. Test the production
// helper with an xcrun shell stub, without touching the connected phone.
const pidsStart = source.indexOf('pids(){');
const pidsEnd = source.indexOf('\n}\n', pidsStart) + 3;
assert(pidsStart >= 0 && pidsEnd > pidsStart);
const helper = source.slice(pidsStart, pidsEnd);
for (const [status, listing, expected] of [
  [0, '7387 /private/var/containers/Bundle/Application/test/Kitsune.app/Kitsune', 'PID=7387'],
  [0, '123 /other.app/other', 'PID='],
  [2, 'ERROR: Command timeout', 'TRANSPORT-ERROR=2'],
]) {
  const output = execFileSync('bash', ['-c', `
set -u
UDID=test
xcrun(){ printf '%s\\n' "$LISTING"; return "$STATUS"; }
${helper}
if value=$(pids); then echo "PID=$value"; else echo "TRANSPORT-ERROR=$?"; fi
`], {env: {...process.env, STATUS: String(status), LISTING: listing}, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
  assert.equal(output.trim(), expected);
}
for (const name of ['P', 'NEWPID', 'p2']) assert(source.includes(`${name}=$(pids) || exit 2`));
console.log('JIT-TRANSPORT PASS: present/absent are distinct from a failed query; failures stop lifecycle retries');
