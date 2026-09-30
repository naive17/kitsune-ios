// Compile the actual loader helpers, then audit false ARM64 matches in a PE.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'third_party/wine/dlls/ntdll/unix/virtual.c'), 'utf8');
function helper(name) {
  const start = source.indexOf(`static ${name}`);
  assert(start >= 0);
  let end = source.indexOf('{', start), depth = 1;
  while (depth && ++end < source.length) {
    if (source[end] === '{') ++depth;
    if (source[end] === '}') --depth;
  }
  assert.equal(depth, 0);
  return source.slice(start, end + 1);
}
assert(source.includes('if (ios_image_uses_x18( image_info->machine, image_info->is_hybrid ))'));
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kitsune-x18-test-'));
try {
  const code = `#include <assert.h>
#include <stddef.h>
#include <string.h>
typedef int BOOL;
typedef unsigned short USHORT;
typedef size_t SIZE_T;
#define IMAGE_FILE_MACHINE_ARM64 0xaa64
#define IMAGE_FILE_MACHINE_ARM64EC 0xa641
#define IMAGE_FILE_MACHINE_ARM64X 0xa64e
${helper('BOOL ios_image_uses_x18')}
${helper('unsigned ios_rewrite_x18')}
int main(void) {
  unsigned original[] = {0xaa1203e8, 0xf9403240, 0xd503201f}, copy[3];
  memcpy(copy, original, sizeof(copy));
  if (ios_image_uses_x18(0x8664, 0)) ios_rewrite_x18((char *)copy, sizeof(copy));
  assert(!memcmp(copy, original, sizeof(copy)));
  assert(!ios_image_uses_x18(0x14c, 0));
  assert(!ios_image_uses_x18(0, 0));
  assert(ios_image_uses_x18(0x8664, 1));
  assert(ios_image_uses_x18(0xa641, 0));
  assert(ios_image_uses_x18(0xa64e, 0));
  assert(ios_image_uses_x18(0xaa64, 0));
  assert(ios_rewrite_x18((char *)copy, sizeof(copy)) == 2);
  assert(copy[0] == 0xaa1c03e8 && copy[1] == 0xf9403380 && copy[2] == original[2]);
}`;
  fs.writeFileSync(path.join(scratch, 'test.c'), code);
  execFileSync('xcrun', ['clang', '-Wall', '-Wextra', '-Werror', path.join(scratch, 'test.c'), '-o', path.join(scratch, 'test')]);
  execFileSync(path.join(scratch, 'test'));
  console.log('PASS: actual loader helpers leave x86/x64 unchanged and retarget ARM64/EC');
} finally {
  fs.rmSync(scratch, {recursive: true, force: true});
}
if (process.argv[2]) {
  const pe = fs.readFileSync(process.argv[2]), nt = pe.readUInt32LE(0x3c);
  assert.equal(pe.readUInt32LE(nt), 0x4550);
  assert.equal(pe.readUInt16LE(nt + 4), 0x8664, 'audit input must be AMD64');
  const sections = nt + 24 + pe.readUInt16LE(nt + 20);
  const matches = [];
  for (let i = 0; i < pe.readUInt16LE(nt + 6); ++i) {
    const s = sections + 40 * i;
    if (!(pe.readUInt32LE(s + 36) & 0x20000000)) continue;
    const size = Math.min(pe.readUInt32LE(s + 8), pe.readUInt32LE(s + 16));
    const raw = pe.readUInt32LE(s + 20), rva = pe.readUInt32LE(s + 12);
    for (let n = 0; n + 4 <= size; n += 4) {
      const v = pe.readUInt32LE(raw + n), top = (v & 0xffc00000) >>> 0;
      if (((v & 0xffffffe0) >>> 0) === 0xaa1203e0 ||
          ((v >>> 5 & 31) === 18 && [0xf9400000,0xf9000000,0xb9400000,0xb9000000,0x91000000,0xd1000000].includes(top)))
        matches.push((rva + n).toString(16));
    }
  }
  console.log(`Old unguarded scan would corrupt ${matches.length} x64 words at RVAs: ${matches.join(', ')}`);
}
