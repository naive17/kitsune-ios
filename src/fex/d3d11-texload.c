/*
 * D3D11 level-load gate: many large textures created with initial data and
 * no drawing in between, as a game loads a level.
 *
 * Copyright 2026 the Kitsune project
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Cuphead creates dozens of 4096x4096 RGBA8 textures at a level start before
 * it draws anything. DXMT staged each one's 64 MB of data and kept every
 * staging buffer until something flushed the uploads, which nothing did, and
 * the phone ran out of memory. The harness reports the app's peak footprint
 * while this runs; the gate bounds it.
 *
 * usage: d3d11_texload.exe <count> [check]
 * With "check", the first and the last texture are read back and compared
 * with what was uploaded (only meaningful when the textures stay RGBA8).
 */

#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DIM 4096

static UINT32 texel( unsigned i, unsigned x, unsigned y )
{
    return 0xff000000u | ((i & 0xff) << 16) | ((y & 0xff) << 8) | (x & 0xff);
}

static int verify( ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *tex, unsigned i )
{
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D *staging;
    D3D11_MAPPED_SUBRESOURCE map;
    unsigned x, y, bad = 0;
    HRESULT hr;

    ID3D11Texture2D_GetDesc( tex, &desc );
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(hr = ID3D11Device_CreateTexture2D( dev, &desc, NULL, &staging )))
    {
        printf( "FAIL staging texture hr=%08lx\n", (unsigned long)hr );
        return 0;
    }
    ID3D11DeviceContext_CopyResource( ctx, (ID3D11Resource *)staging, (ID3D11Resource *)tex );
    if (FAILED(hr = ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map )))
    {
        printf( "FAIL map hr=%08lx\n", (unsigned long)hr );
        ID3D11Texture2D_Release( staging );
        return 0;
    }
    for (y = 0; y < DIM; y += 97)
        for (x = 0; x < DIM; x += 89)
        {
            UINT32 got = ((const UINT32 *)((const BYTE *)map.pData + (size_t)y * map.RowPitch))[x];
            if (got != texel( i, x, y ) && bad++ < 4)
                printf( "texload: texture %u at %u,%u has %08x, want %08x\n", i, x, y, got, texel( i, x, y ) );
        }
    ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)staging, 0 );
    ID3D11Texture2D_Release( staging );
    return !bad;
}

int main( int argc, char **argv )
{
    unsigned count = argc > 1 ? (unsigned)atoi( argv[1] ) : 40, i, x, y;
    int check = argc > 2 && !strcmp( argv[2], "check" );
    ID3D11Texture2D **tex;
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    D3D11_TEXTURE2D_DESC desc = { 0 };
    D3D11_SUBRESOURCE_DATA init;
    UINT32 *data;
    HRESULT hr;

    if (FAILED(hr = D3D11CreateDevice( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                       &dev, NULL, &ctx )))
    {
        printf( "FAIL D3D11CreateDevice hr=%08lx\n", (unsigned long)hr );
        return 1;
    }
    if (!(data = malloc( (size_t)DIM * DIM * 4 )) || !(tex = calloc( count, sizeof(*tex) )))
    {
        printf( "FAIL out of memory\n" );
        return 1;
    }
    desc.Width = desc.Height = DIM;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    init.pSysMem = data;
    init.SysMemPitch = DIM * 4;
    init.SysMemSlicePitch = 0;

    for (i = 0; i < count; i++)
    {
        for (y = 0; y < DIM; y++)
            for (x = 0; x < DIM; x++) data[(size_t)y * DIM + x] = texel( i, x, y );
        if (FAILED(hr = ID3D11Device_CreateTexture2D( dev, &desc, &init, &tex[i] )))
        {
            printf( "FAIL texture %u hr=%08lx\n", i, (unsigned long)hr );
            return 1;
        }
    }
    printf( "texload: created %u textures of %ux%u\n", count, DIM, DIM );
    fflush( stdout );

    if (check && !(verify( dev, ctx, tex[0], 0 ) && verify( dev, ctx, tex[count - 1], count - 1 )))
    {
        printf( "FAIL texture contents\n" );
        return 1;
    }
    for (i = 0; i < count; i++) ID3D11Texture2D_Release( tex[i] );
    ID3D11DeviceContext_Release( ctx );
    ID3D11Device_Release( dev );
    printf( check ? "OK texload contents\n" : "OK texload\n" );
    return 0;
}
