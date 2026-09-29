// Compile the actual Wine mode generator and iOS stale-mode validation block.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const wine = path.join(root, 'third_party/wine');
const source = fs.readFileSync(path.join(wine, 'dlls/win32u/sysparams.c'), 'utf8');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
function slice(start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  assert(first >= 0 && last > first, `Production source markers changed: ${start}`);
  return source.slice(first, last);
}
const validation = slice('            UINT i;\n            for (i = 0; i < virtual_count; i++)', '#endif');
fs.writeFileSync(path.join(scratch, 'wine-display-modes.inc'),
  slice('static UINT devmode_get(', 'static BOOL is_detached_mode(') +
  slice('static UINT add_screen_size(', 'static void add_modes(') +
  '\nstatic DEVMODEW validate_mode(DEVMODEW physical, DEVMODEW virtual, ' +
  'DEVMODEW *virtual_modes, UINT virtual_count) {\n' + validation +
  '\nreturn virtual;\n}\n');
const output = path.join(scratch, 'display-modes-test');
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-std=gnu11', '-O1', '-g',
  '-Wall', '-Wextra', '-Werror', '-Wno-sign-compare', '-D__WINESRC__',
  '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
  '-I' + path.join(wine, 'include'), '-I' + scratch,
  path.join(root, 'tests/display_modes_test.c'), '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
