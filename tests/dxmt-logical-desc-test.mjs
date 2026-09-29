// Compile the production descriptor-reporting method, not a reimplementation.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const source = fs.readFileSync(path.join(root, 'third_party/dxmt/src/d3d11/d3d11_resource.hpp'), 'utf8');
const begin = source.indexOf('  typename tag::DESC1 ReportedDesc() const {');
const end = source.indexOf('\n  void STDMETHODCALLTYPE GetDesc(', begin);
assert(begin >= 0 && end > begin);
assert(source.includes('DowngradeResourceDescription(ReportedDesc(),'));
assert(source.includes('*(typename tag::DESC1 *)pDesc = ReportedDesc();'));
const device = fs.readFileSync(path.join(root, 'third_party/dxmt/src/d3d11/d3d11_device.cpp'), 'utf8');
assert(device.includes('resource->mip_clamp = {clamp, logical_desc.Width, logical_desc.Height, logical_desc.MipLevels};'));
assert(!device.includes('g_mipclamp['), 'Mip bias must not outlive its resource');
const test = `
#include <cassert>
#include <cstdint>
#include <cstdio>
constexpr unsigned D3D11_RESOURCE_DIMENSION_TEXTURE2D = 3;
struct TextureDesc { unsigned Width, Height, MipLevels, Format, ArraySize; };
struct BufferDesc { unsigned ByteWidth, Usage; };
struct TextureTag { using DESC1 = TextureDesc; static constexpr unsigned dimension = 3; };
struct BufferTag { using DESC1 = BufferDesc; static constexpr unsigned dimension = 1; };
template<class tag> struct Resource {
  typename tag::DESC1 desc;
  struct { uint32_t levels = 0, width = 0, height = 0, mips = 0; } mip_clamp;
${source.slice(begin, end)}
};
int main() {
  Resource<TextureTag> texture{{512, 256, 10, 71, 6}};
  auto unchanged = texture.ReportedDesc();
  assert(unchanged.Width == 512 && unchanged.Height == 256 && unchanged.MipLevels == 10);
  texture.mip_clamp = {2, 2048, 1024, 12};
  auto logical = texture.ReportedDesc();
  assert(logical.Width == 2048 && logical.Height == 1024 && logical.MipLevels == 12);
  assert(logical.Format == 71 && logical.ArraySize == 6);
  assert(texture.desc.Width == 512 && texture.desc.MipLevels == 10); // internal backing unchanged
  texture = Resource<TextureTag>{{256, 256, 9, 98, 1}};
  assert(texture.ReportedDesc().Width == 256 && !texture.mip_clamp.levels);
  Resource<BufferTag> buffer{{4096, 0}};
  assert(buffer.ReportedDesc().ByteWidth == 4096); // non-textures still compile and remain unchanged
  puts("LOGICAL-DESC PASS: atlas extent, mip count, array/format preservation, backing unchanged, lifetime, non-textures");
}
`;
const input = path.join(scratch, 'dxmt-logical-desc-test.cpp');
const output = path.join(scratch, 'dxmt-logical-desc-test');
fs.writeFileSync(input, test);
execFileSync('xcrun', ['--sdk', 'macosx', 'clang++', '-std=c++20', '-Wall', '-Wextra',
  '-Werror', '-Wno-missing-field-initializers', '-fsanitize=address,undefined',
  input, '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
