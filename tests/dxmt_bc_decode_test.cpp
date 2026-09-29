#include <array>
#include <cassert>
#include <cstdio>
#include <vector>
#include "dxmt_bc_decode.hpp"
using namespace dxmt;

namespace unix_format {
static bool use_16bit, use_native;
static bool bc_16bit_enabled() { return use_16bit; }
static bool bc_native_enabled() { return use_native; }
#include "dxmt-bc-remap.inc"
}

static std::vector<uint8_t> decode(WMTPixelFormat f, const uint8_t *block,
                                  uint32_t w = 4, uint32_t h = 4, bool bc16 = false) {
  auto l = bc_upload_layout(f, w, h, bc16);
  assert(l.kind && l.row_pitch % 4 == 0);
  std::vector<uint8_t> out(l.image_pitch + 16, 0xcd);
  assert(bc_decode_upload(l, block, l.bytes_per_block, out.data(), w, h));
  for (size_t i = l.image_pitch; i < out.size(); i++) assert(out[i] == 0xcd);
  return out;
}

int main() {
  for (bool use16 : {false, true}) {
    unix_format::use_16bit = use16;
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC1_RGBA, false) ==
           (use16 ? WMTPixelFormatBGR5A1Unorm : WMTPixelFormatRGBA8Unorm));
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC1_RGBA_sRGB, false) == WMTPixelFormatRGBA8Unorm_sRGB);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC5_RGSnorm, false) == WMTPixelFormatRG8Snorm);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC6H_RGBUfloat, false) == WMTPixelFormatRGBA16Float);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC7_RGBAUnorm, false) == WMTPixelFormatRGBA8Unorm);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC1_RGBA, true) == WMTPixelFormatBC1_RGBA);
    // Native transcode keeps colour and normal formats block-compressed; snorm and HDR keep the decoded formats.
    unix_format::use_native = true;
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC1_RGBA, false) == WMTPixelFormatEAC_RGBA8);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC3_RGBA_sRGB, false) == WMTPixelFormatEAC_RGBA8_sRGB);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC7_RGBAUnorm, false) == WMTPixelFormatEAC_RGBA8);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC4_RUnorm, false) == WMTPixelFormatEAC_R11Unorm);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC5_RGUnorm, false) == WMTPixelFormatEAC_RG11Unorm);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC5_RGSnorm, false) == WMTPixelFormatRG8Snorm);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC6H_RGBUfloat, false) == WMTPixelFormatRGBA16Float);
    assert(unix_format::remap_unsupported_bc(WMTPixelFormatBC1_RGBA, true) == WMTPixelFormatBC1_RGBA);
    unix_format::use_native = false;
  }
  std::array<uint8_t, 16> block{};
  block[1] = 0xf8; // RGB565 red, index zero everywhere.
  for (bool bc16 : {false, true})
    for (uint32_t w = 1; w <= 4; w++)
      for (uint32_t h = 1; h <= 4; h++) {
        auto l = bc_upload_layout(WMTPixelFormatBC1_RGBA, w, h, bc16);
        auto out = decode(WMTPixelFormatBC1_RGBA, block.data(), w, h, bc16);
        for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
          const auto *p = out.data() + y * l.row_pitch + x * l.bytes_per_pixel;
          if (bc16) assert(p[0] == 0 && p[1] == 0xfc);
          else assert(p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255);
        }
      }
  // BC1 sRGB must stay RGBA8 even when BC1 UNORM uses 5551.
  assert(bc_upload_layout(WMTPixelFormatBC1_RGBA_sRGB, 1, 1, true).bytes_per_pixel == 4);
  block.fill(0); block[0] = 255; block[9] = 0xf8;
  auto rgba = decode(WMTPixelFormatBC3_RGBA, block.data());
  assert(rgba[0] == 255 && rgba[3] == 255);
  for (unsigned i = 0; i < 8; i++) block[i] = 0xff;
  rgba = decode(WMTPixelFormatBC2_RGBA, block.data());
  assert(rgba[0] == 255 && rgba[3] == 255);
  block.fill(0); block[0] = 128; block[8] = 64;
  auto rg = decode(WMTPixelFormatBC5_RGUnorm, block.data(), 3, 2);
  for (unsigned y = 0; y < 2; y++) for (unsigned x = 0; x < 3; x++)
    assert(rg[y * 8 + x * 2] == 128 && rg[y * 8 + x * 2 + 1] == 64);
  block[0] = 0x81; block[8] = 0x7f;
  rg = decode(WMTPixelFormatBC5_RGSnorm, block.data());
  assert(int8_t(rg[0]) == -127 && int8_t(rg[1]) == 127);
  auto r = decode(WMTPixelFormatBC4_RSnorm, block.data(), 1, 1);
  assert(int8_t(r[0]) == -127);
  // Reserved BC6H mode decodes black; Metal's physical RGBA16F needs alpha one.
  block.fill(0); block[0] = 0x1f;
  auto hdr = decode(WMTPixelFormatBC6H_RGBUfloat, block.data());
  for (unsigned p = 0; p < 16; p++) {
    for (unsigned c = 0; c < 6; c++) assert(hdr[p * 8 + c] == 0);
    assert(hdr[p * 8 + 6] == 0 && hdr[p * 8 + 7] == 0x3c);
  }
  // BC7 mode 6: both RGBA endpoints 127 with pbits 1 => opaque white.
  block.fill(0); unsigned pos = 0;
  auto bits = [&](unsigned v, unsigned n) {
    for (unsigned i = 0; i < n; i++, pos++) block[pos / 8] |= ((v >> i) & 1) << (pos % 8);
  };
  bits(0x40, 7);
  for (unsigned c = 0; c < 8; c++) bits(127, 7);
  bits(3, 2);
  rgba = decode(WMTPixelFormatBC7_RGBAUnorm, block.data());
  for (unsigned i = 0; i < 64; i++) assert(rgba[i] == 255);
  // Two block rows, odd crop, padded source pitch and deliberately unaligned input.
  std::vector<uint8_t> source(1 + 48 * 2, 0xee), out(8 * 5 + 16, 0xcd);
  for (unsigned y = 0; y < 2; y++) for (unsigned x = 0; x < 2; x++) {
    auto *p = source.data() + 1 + y * 48 + x * 8;
    std::memset(p, 0, 8); p[0] = 32 + x + y * 2;
  }
  auto l = bc_upload_layout(WMTPixelFormatBC4_RUnorm, 5, 5, false);
  assert(bc_decode_upload(l, source.data() + 1, 48, out.data(), 5, 5));
  for (unsigned y = 0; y < 5; y++) for (unsigned x = 0; x < 5; x++)
    assert(out[y * 8 + x] == 32 + x / 4 + (y / 4) * 2);
  for (size_t i = 40; i < out.size(); i++) assert(out[i] == 0xcd);
  assert(!bc_decode_upload(l, source.data(), 1, out.data(), 5, 5));
  assert(!bc_upload_layout(WMTPixelFormatRGBA8Unorm, 4, 4, false).kind);
  puts("BC-DECODE PASS: BC1-7, signed normals, HDR alpha, sRGB/5551, odd mip tails, padded/unaligned input");
}
