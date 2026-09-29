// Compile actual Wine context helpers/wrappers and the actual server exit timer.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const wine = path.join(root, 'third_party/wine');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const sanitizer = process.argv[2];
assert(!sanitizer || ['address', 'thread'].includes(sanitizer));
if (sanitizer) assert(!execFileSync('xcrun', ['--find', 'clang'], {encoding: 'utf8'})
  .includes('/CommandLineTools/'), 'Set DEVELOPER_DIR to full Xcode for sanitizers');
function slice(file, start, end) {
  const source = fs.readFileSync(path.join(wine, file), 'utf8');
  const first = source.indexOf(start), last = source.indexOf(end, first);
  assert(first >= 0 && last > first, `source markers changed: ${file}`);
  return source.slice(first, last);
}
fs.writeFileSync(path.join(scratch, 'wine-process-context.inc'),
  '#ifdef WINE_IOS_JIT_ARENA\n' + slice('dlls/ntdll/unix/server.c',
    '/* No registry lookup:', '/* atomically exchange a 64-bit value */'));
fs.writeFileSync(path.join(scratch, 'wine-process-timer.inc'),
  slice('server/process.c', '/* callback for process sigkill timeout */', '/* create a new process */'));
fs.writeFileSync(path.join(scratch, 'wine-inproc-lifetime.inc'),
  slice('server/ios_inproc.c', 'static void configure_inproc_lifetime(void)',
    '__attribute__((visibility("default")))'));
const thread = fs.readFileSync(path.join(wine, 'dlls/ntdll/unix/thread.c'), 'utf8');
const vm = fs.readFileSync(path.join(wine, 'dlls/ntdll/unix/virtual.c'), 'utf8');
assert(thread.includes('ios_process_inherit_thread( data )'));
assert(thread.includes('ios_process_release_thread( data )'));
assert(vm.includes('ios_process_release_thread( data )'));
for (const [test, ios] of [['process_context_test', true], ['process_timer_test', true], ['process_timer_test', false]]) {
  const output = path.join(scratch, `${test}-${ios ? 'ios' : 'legacy'}-${sanitizer || 'plain'}`);
  execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-std=c11', '-O1', '-g',
    '-Wall', '-Wextra', '-Werror', '-I' + path.join(wine, 'dlls/ntdll/unix'), '-I' + scratch,
    ...(ios ? ['-DWINE_IOS_JIT_ARENA'] : []),
    ...(sanitizer ? ['-fsanitize=' + sanitizer, '-fno-omit-frame-pointer'] : []),
    path.join(root, 'tests', test + '.c'), '-o', output], {stdio: 'inherit'});
  execFileSync(output, {stdio: 'inherit', timeout: 30000});
}
