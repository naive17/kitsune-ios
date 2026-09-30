/* bc_transcode.cpp (winemetal) encodes to ETC2/EAC; the GPU must decode the
 * same colours. etcpak takes BGRA bytes, and packing RGBA once swapped red and
 * blue (blue-tinted sprites) and zeroed EAC R11/RG11. Run by etc2-transcode-test.sh. */
#import <Metal/Metal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
extern int ios_bc_transcode(const uint8_t *src, size_t pitch, unsigned bpp, unsigned w, unsigned h, int kind, uint8_t *dst, size_t dst_size);
/* Encode a solid 4x4 colour, let the GPU decode it, compare. */
static int check(id<MTLDevice> dev, id<MTLCommandQueue> q, MTLPixelFormat fmt, int kind, unsigned bpp, const uint8_t *px, const char *name) {
  uint8_t src[16 * 4], blk[16];
  for (int i = 0; i < 16; i++) memcpy(src + i * bpp, px, bpp);
  if (ios_bc_transcode(src, 4 * bpp, bpp, 4, 4, kind, blk, sizeof blk)) { printf("%s: encode failed\n", name); return 1; }
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:4 height:4 mipmapped:NO];
  id<MTLTexture> t = [dev newTextureWithDescriptor:d];
  [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:blk bytesPerRow:(kind == 1 ? 8 : 16)];
  /* The GPU decodes the block; a one-thread kernel reads a texel back. */
  NSError *err = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:
      @"#include <metal_stdlib>\nusing namespace metal;\n"
       "kernel void k(texture2d<float> s [[texture(0)]], device float4 *o [[buffer(0)]]) { o[0] = s.read(uint2(1,1)); }"
      options:nil error:&err];
  id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
  id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> cb = [q commandBuffer];
  id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
  [e setComputePipelineState:ps]; [e setTexture:t atIndex:0]; [e setBuffer:out offset:0 atIndex:0];
  [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
  [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
  float *f = (float *)out.contents;
  int want[4] = { px[0], bpp >= 2 ? px[1] : 0, bpp == 4 ? px[2] : 0, bpp == 4 ? px[3] : 255 };
  int got[4] = { (int)(f[0] * 255 + .5f), (int)(f[1] * 255 + .5f), (int)(f[2] * 255 + .5f), (int)(f[3] * 255 + .5f) };
  int ok = 1, n = kind == 1 ? 1 : kind == 2 ? 2 : 4;
  for (int c = 0; c < n; c++) if (abs(got[c] - want[c]) > 12) ok = 0;
  printf("%-16s in %3d %3d %3d %3d  decoded %3d %3d %3d %3d  %s\n", name, want[0], want[1], want[2], want[3], got[0], got[1], got[2], got[3], ok ? "OK" : "WRONG");
  return !ok;
}
int main(void) {
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    int bad = 0;
    uint8_t red[4] = {220, 30, 20, 255}, blue[4] = {20, 40, 210, 255}, half[4] = {60, 200, 90, 128};
    uint8_t r8[1] = {200}, rg[2] = {180, 40};
    bad += check(dev, q, MTLPixelFormatEAC_RGBA8, 0, 4, red, "RGBA red");
    bad += check(dev, q, MTLPixelFormatEAC_RGBA8, 0, 4, blue, "RGBA blue");
    bad += check(dev, q, MTLPixelFormatEAC_RGBA8, 0, 4, half, "RGBA half-alpha");
    bad += check(dev, q, MTLPixelFormatEAC_R11Unorm, 1, 1, r8, "EAC R11");
    bad += check(dev, q, MTLPixelFormatEAC_RG11Unorm, 2, 2, rg, "EAC RG11");
    printf(bad ? "ETC2 TEST FAILED\n" : "ETC2 TEST PASS\n");
    return bad != 0;
  }
}
