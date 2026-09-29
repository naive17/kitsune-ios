import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const source = fs.readFileSync(path.join(root, 'third_party/wine/dlls/ntdll/unix/virtual.c'), 'utf8');
const begin = source.indexOf('        if ((vprot & VPROT_COMMITTED) && (ios_swap_mask & IOS_SWAP_RESERVE)');
const end = source.indexOf('\n        {', begin);
assert(begin >= 0 && end > begin);
const condition = source.slice(begin, end).trim().replace(/^if /, '');
const input = path.join(scratch, 'swap-commit-policy-test.c');
const output = path.join(scratch, 'swap-commit-policy-test');
fs.writeFileSync(input, `
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#define VPROT_COMMITTED 1
#define IOS_SWAP_RESERVE 2
#define SEC_IMAGE 4
struct file_view {size_t size; unsigned protect;};
static int eligible(struct file_view *view, unsigned vprot, unsigned ios_swap_mask,
                    int ios_thread_stack_alloc, size_t ios_swap_min_view) {
  return ${condition};
}
int main(void) {
  struct file_view hot = {0x210000, 0}, heap = {64u<<20, 0}, exact = {4u<<20, 0};
  assert(!eligible(&hot, 1, 3, 0, 4u<<20));
  assert(eligible(&heap, 1, 3, 0, 4u<<20)); // size is reservation, even for a 4 KB commit
  assert(eligible(&exact, 1, 3, 0, 4u<<20));
  assert(!eligible(&heap, 1, 1, 0, 4u<<20));
  assert(!eligible(&heap, 0, 3, 0, 4u<<20));
  assert(!eligible(&heap, 1, 3, 1, 4u<<20));
  heap.protect = SEC_IMAGE;
  assert(!eligible(&heap, 1, 3, 0, 4u<<20));
  puts("SWAP-COMMIT PASS: short-lived small reservations skipped; large-heap commits, masks and exclusions retained");
}
`);
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror',
  '-fsanitize=address,undefined', input, '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
