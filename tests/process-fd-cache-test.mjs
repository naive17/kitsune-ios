// Compile production Wine cache helpers. Generated fixture is a verbatim
// source slice, not a separately maintained cache implementation.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const wine = path.join(root, 'third_party/wine');
const source = fs.readFileSync(path.join(wine, 'dlls/ntdll/unix/server.c'), 'utf8');
const start = source.indexOf('/* fd cache support */');
const marker = '\n/***********************************************************************\n *           server_get_unix_fd';
const end = source.indexOf(marker, start);
assert(start >= 0 && end > start);
assert(source.includes('if (!ios_fd_cache_enabled)\n#endif\n    {\n        ret = get_cached_fd'));
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
fs.writeFileSync(path.join(scratch, 'wine-fd-cache.inc'), source.slice(start, end));
const sanitizer = process.argv[2];
assert(!sanitizer || ['address', 'thread'].includes(sanitizer), 'optional sanitizer: address or thread');
if (sanitizer) {
  const clang = execFileSync('xcrun', ['--find', 'clang'], {encoding: 'utf8'}).trim();
  assert(!clang.includes('/CommandLineTools/'),
    'Sanitizers need full Xcode here: set DEVELOPER_DIR to Xcode.app/Contents/Developer. ' +
    'The installed Command Line Tools sanitizer runtime stalls/crashes before main.');
}
const binary = path.join(scratch, `process-fd-cache-test${sanitizer ? '-' + sanitizer : ''}`);
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
  '-Wno-unused-parameter', '-D__WINESRC__', '-DWINE_UNIX_LIB', '-DWINE_IOS_JIT_ARENA',
  '-DWINE_NO_DEBUG_MSGS', '-DWINE_NO_TRACE_MSGS',
  ...[path.join(root, 'build/wine-macos/include'), path.join(wine, 'include'),
    path.join(wine, 'dlls/ntdll/unix'), scratch].map(p => '-I' + p),
  ...(sanitizer ? ['-fsanitize=' + sanitizer, '-fno-omit-frame-pointer'] : []),
  path.join(root, 'tests/process_fd_cache_test.c'), '-o', binary], {stdio: 'inherit'});
execFileSync(binary, {stdio: 'inherit', timeout: 30000});
