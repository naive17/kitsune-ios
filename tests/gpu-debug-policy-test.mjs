import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const source = fs.readFileSync(path.join(root, 'third_party/dxmt/src/winemetal/unix/winemetal_unix.c'), 'utf8');
const begin = source.indexOf('static MTLStoreAction ios_debug_store_action(');
const end = source.indexOf('\n}\n', begin) + 3;
assert(begin >= 0 && end > begin);
const input = path.join(scratch, 'gpu-debug-policy-test.c');
const output = path.join(scratch, 'gpu-debug-policy-test');
fs.writeFileSync(input, `
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
typedef enum { MTLStoreActionDontCare, MTLStoreActionStore,
  MTLStoreActionMultisampleResolve, MTLStoreActionStoreAndMultisampleResolve,
  MTLStoreActionUnknown, MTLStoreActionCustomSampleDepthStore } MTLStoreAction;
static _Atomic unsigned ios_gpu_debug_mask = 0;
${source.slice(begin, end)}
int main(void) {
  for (unsigned mask = 0; mask < 4; mask++) {
    atomic_store(&ios_gpu_debug_mask, mask);
    for (unsigned action = 0; action < 6; action++) {
      unsigned expected = (mask & 2) && action == MTLStoreActionDontCare ? MTLStoreActionStore : action;
      assert(ios_debug_store_action(action) == expected);
    }
  }
  puts("GPU-DEBUG PASS: default and serial-only preserve store actions; preserve-store changes only DontCare, never resolves");
}
`);
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror',
  '-fsanitize=address,undefined', input, '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
