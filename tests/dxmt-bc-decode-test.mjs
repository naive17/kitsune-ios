import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const dxmt = path.join(root, 'third_party/dxmt');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const digest = createHash('sha256').update(fs.readFileSync(path.join(dxmt, 'src/dxmt/bcdec.h'))).digest('hex');
assert.equal(digest, '134520764d96f70a27db814173616c89ad85db95fbd3328417c7a8c77e7ca189',
  'Vendored bcdec must remain identical to pinned upstream');
// Exercise the Unix format selection too: the PE layout and physical texture
// must agree, especially BC1 sRGB when the 16-bit switch is enabled.
const unix = fs.readFileSync(path.join(dxmt, 'src/winemetal/unix/winemetal_unix.c'), 'utf8');
const nativeStart = unix.indexOf('static enum WMTPixelFormat remap_bc_native(');
const nativeEnd = unix.indexOf('\n}\n', nativeStart) + 3;
const start = unix.indexOf('static enum WMTPixelFormat remap_unsupported_bc(');
const end = unix.indexOf('\n}\n', start) + 3;
assert(nativeStart >= 0 && nativeEnd > nativeStart && start >= 0 && end > start);
fs.writeFileSync(path.join(scratch, 'dxmt-bc-remap.inc'), unix.slice(nativeStart, nativeEnd) + unix.slice(start, end));
const output = path.join(scratch, 'dxmt-bc-decode-test');
execFileSync('xcrun', ['--sdk', 'macosx', 'clang++', '-std=c++20', '-Wall', '-Wextra',
  '-Werror', '-Wno-unused-function', '-fsigned-char', '-fsanitize=address,undefined',
  '-fno-omit-frame-pointer', '-I' + path.join(dxmt, 'src/dxmt'), '-I' + scratch,
  path.join(root, 'tests/dxmt_bc_decode_test.cpp'), '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
