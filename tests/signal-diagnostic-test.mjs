// Compile the production diagnostic reader, then probe inaccessible addresses.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const source = fs.readFileSync(path.join(root, 'third_party/wine/dlls/ntdll/unix/signal_arm64.c'), 'utf8');
const first = source.indexOf('static int ios_diagnostic_read(');
const last = source.indexOf('\n#endif', first);
assert(first >= 0 && last > first);
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
fs.writeFileSync(path.join(scratch, 'wine-diagnostic-read.inc'), source.slice(first, last));
const output = path.join(scratch, 'signal-diagnostic-test');
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror',
  '-I' + scratch, path.join(root, 'tests/signal_diagnostic_test.c'), '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 10000});
