import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const source = fs.readFileSync(path.join(root, 'third_party/wine/dlls/wineios.drv/surface.c'), 'utf8');
const begin = source.indexOf('    x = visible.left;');
const end = source.indexOf('\n    pthread_mutex_lock(', begin);
assert(begin >= 0 && end > begin);
assert(source.includes('wineios_layer_set_geometry( layer, x, y, frame_width, frame_height );'));
assert(source.includes('wineios_layer_present( layer, color_bits, width, height, stride );'));
const input = path.join(scratch, 'surface-geometry-test.c');
const output = path.join(scratch, 'surface-geometry-test');
fs.writeFileSync(input, `
#include <assert.h>
#include <stdio.h>
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
typedef struct {int left,top,right,bottom;} RECT;
static void check(RECT visible, int surf_width, int surf_height, int fw, int fh, int pw, int ph) {
    int x, y, width, height, frame_width, frame_height;
${source.slice(begin, end)}
    assert(x == visible.left && y == visible.top);
    assert(frame_width == fw && frame_height == fh);
    assert(width == pw && height == ph);
    assert(width <= surf_width && height <= surf_height);
}
int main(void) {
    check((RECT){0,0,1350,624}, 1024,768, 1350,624, 1024,624);
    check((RECT){100,75,500,375}, 512,384, 400,300, 400,300);
    check((RECT){0,0,0,0}, 128,128, 128,128, 128,128);
    puts("SURFACE-GEOMETRY PASS: virtual bitmap cannot shrink raw fullscreen; window crop and initial fallback retained");
}
`);
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror',
  '-fsanitize=address,undefined', input, '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
