/*
 * D3D11 correctness gate: render a triangle offscreen and read the pixels back.
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
 * Whether DXMT actually DRAWS could not be answered on the harness: the window
 * path needs a compositor, and the capture hook only sees Wine's GDI surface,
 * not the Metal layer DXMT presents to. So do not involve a window at all.
 *
 * Render to an offscreen target, copy it to a staging texture, map it, and
 * check the pixels here in the guest. That exercises everything that matters --
 * device creation, shader compilation (DXBC -> AIR), pipeline state, the
 * rasteriser, and the readback path -- and reports a verdict as text, which
 * works identically on a Mac and on a phone with no screen attached to
 * anything.
 *
 * The shader source is embedded rather than loaded from a file: a relative
 * path fails with "file not found", because the guest's current directory is
 * the prefix's .wineserver dir, not the program's.
 *
 * The triangle covers the centre and leaves the corners clear, so the check is
 * a shape test rather than "something changed": a cleared-but-never-drawn
 * target passes a naive "is it non-black" test and fails this one.
 */

#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>

#define RT_SIZE 256

static const char *hlsl =
    "struct VSOut { float4 pos : SV_POSITION; float4 col : COLOR; };\n"
    "VSOut vs_main(uint id : SV_VertexID) {\n"
    "  float2 p[3] = { float2(0.0, 0.8), float2(0.8, -0.8), float2(-0.8, -0.8) };\n"
    "  VSOut o;\n"
    "  o.pos = float4(p[id], 0.0, 1.0);\n"
    "  o.col = float4(1.0, 0.0, 0.0, 1.0);\n"
    "  return o;\n"
    "}\n"
    "float4 ps_main(VSOut i) : SV_TARGET { return i.col; }\n";

static int fail( const char *what, HRESULT hr )
{
    printf( "d3d11: FAIL %s hr=0x%08lx\n", what, (unsigned long)hr );
    return 1;
}

int main( void )
{
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *rt = NULL, *staging = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3DBlob *vsb = NULL, *psb = NULL, *err = NULL;
    D3D11_TEXTURE2D_DESC td = {0};
    D3D11_MAPPED_SUBRESOURCE map;
    D3D11_VIEWPORT vp = {0};
    const float clear[4] = { 0.0f, 0.0f, 1.0f, 1.0f };   /* blue */
    D3D_FEATURE_LEVEL got;
    unsigned red = 0, blue = 0, other = 0;
    unsigned cx, cy, x, y;
    HRESULT hr;

    hr = D3D11CreateDevice( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                            D3D11_SDK_VERSION, &dev, &got, &ctx );
    if (FAILED(hr)) return fail( "D3D11CreateDevice", hr );
    printf( "d3d11: device created, feature level %x\n", (unsigned)got );

    td.Width = td.Height = RT_SIZE;
    td.MipLevels = td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    if (FAILED(hr = ID3D11Device_CreateTexture2D( dev, &td, NULL, &rt )))
        return fail( "CreateTexture2D(rt)", hr );
    if (FAILED(hr = ID3D11Device_CreateRenderTargetView( dev, (ID3D11Resource *)rt, NULL, &rtv )))
        return fail( "CreateRenderTargetView", hr );

    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(hr = ID3D11Device_CreateTexture2D( dev, &td, NULL, &staging )))
        return fail( "CreateTexture2D(staging)", hr );

    hr = D3DCompile( hlsl, strlen(hlsl), NULL, NULL, NULL, "vs_main", "vs_5_0", 0, 0, &vsb, &err );
    if (FAILED(hr)) return fail( "D3DCompile(vs)", hr );
    hr = D3DCompile( hlsl, strlen(hlsl), NULL, NULL, NULL, "ps_main", "ps_5_0", 0, 0, &psb, &err );
    if (FAILED(hr)) return fail( "D3DCompile(ps)", hr );
    printf( "d3d11: shaders compiled\n" );

    if (FAILED(hr = ID3D11Device_CreateVertexShader( dev, ID3D10Blob_GetBufferPointer(vsb),
                                                     ID3D10Blob_GetBufferSize(vsb), NULL, &vs )))
        return fail( "CreateVertexShader", hr );
    if (FAILED(hr = ID3D11Device_CreatePixelShader( dev, ID3D10Blob_GetBufferPointer(psb),
                                                    ID3D10Blob_GetBufferSize(psb), NULL, &ps )))
        return fail( "CreatePixelShader", hr );

    vp.Width = vp.Height = RT_SIZE;
    vp.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports( ctx, 1, &vp );
    ID3D11DeviceContext_OMSetRenderTargets( ctx, 1, &rtv, NULL );
    ID3D11DeviceContext_ClearRenderTargetView( ctx, rtv, clear );
    ID3D11DeviceContext_VSSetShader( ctx, vs, NULL, 0 );
    ID3D11DeviceContext_PSSetShader( ctx, ps, NULL, 0 );
    ID3D11DeviceContext_IASetPrimitiveTopology( ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
    ID3D11DeviceContext_Draw( ctx, 3, 0 );

    ID3D11DeviceContext_CopyResource( ctx, (ID3D11Resource *)staging, (ID3D11Resource *)rt );
    ID3D11DeviceContext_Flush( ctx );

    if (FAILED(hr = ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)staging, 0,
                                             D3D11_MAP_READ, 0, &map )))
        return fail( "Map(staging)", hr );

    for (y = 0; y < RT_SIZE; y++)
    {
        const unsigned char *row = (const unsigned char *)map.pData + y * map.RowPitch;
        for (x = 0; x < RT_SIZE; x++)
        {
            const unsigned char *p = row + x * 4;    /* BGRA */
            if (p[2] > 200 && p[1] < 60 && p[0] < 60) red++;
            else if (p[0] > 200 && p[1] < 60 && p[2] < 60) blue++;
            else other++;
        }
    }

    /* The centre must be inside the triangle and the top-left corner outside;
     * that is the difference between "drew a triangle" and "cleared". */
    cx = RT_SIZE / 2; cy = RT_SIZE / 2;
    {
        const unsigned char *mid = (const unsigned char *)map.pData + cy * map.RowPitch + cx * 4;
        const unsigned char *corner = (const unsigned char *)map.pData;   /* 0,0 */
        int mid_red = mid[2] > 200 && mid[1] < 60 && mid[0] < 60;
        int corner_blue = corner[0] > 200 && corner[1] < 60 && corner[2] < 60;

        printf( "d3d11: red=%u blue=%u other=%u centre=%s corner=%s\n",
                red, blue, other, mid_red ? "red" : "NOT-red",
                corner_blue ? "blue" : "NOT-blue" );

        ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)staging, 0 );

        if (mid_red && corner_blue && red > 1000)
        {
            printf( "d3d11: OK triangle rendered\n" );
            return 0;
        }
    }
    printf( "d3d11: FAIL no triangle\n" );
    return 1;
}
