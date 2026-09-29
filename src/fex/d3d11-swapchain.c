/*
 * D3D11 through a real swapchain: the shape a game actually has.
 *
 * Copyright 2026 the ios-wine project
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
 * d3d11-readback.c deliberately has no window, because "does DXMT draw" had to
 * be answerable on a machine with nothing attached to a layer. It passes, and
 * it does not say whether a game would run: no game renders to an offscreen
 * texture and maps it. A game creates a swapchain for its window and calls
 * Present in a loop, and that path goes through IDXGISwapChain, DXMT's
 * Presenter, CreateMetalViewFromHWND, this port's macdrv_functions bridge, a
 * second CAMetalLayer stacked over the window's, and nextDrawable -- none of
 * which the offscreen test touches. Every bug found while getting this to run
 * lived in that list.
 *
 * Three questions, one program:
 *
 *   does it survive       -- creating a swapchain for a live window, resizing
 *                            its buffers, and presenting several hundred times
 *                            without a fault. The first attempt died in
 *                            objc_release on the third frame.
 *   does it draw          -- the back buffer is read back and shape-tested
 *                            before a Present, exactly as in d3d11-readback.c.
 *                            "Present returned S_OK" is not evidence of pixels.
 *   how fast              -- frames per second, and the share of the frame
 *                            spent inside Present, reported by the guest. This
 *                            is the number that decides whether a game is
 *                            playable, and nothing outside the guest can
 *                            measure it: the driver's own counter sees GDI
 *                            flushes, and a D3D window does not produce them.
 *
 * Builds for both arm64ec and x86-64. The x86-64 build is the real target
 * shape: translated code calling into an ARM64EC d3d11.dll through the EC
 * thunks and out to Metal.
 *
 * IOSWINE_D3D_SECONDS   how long to run (default 5)
 * IOSWINE_D3D_W / _H    swapchain size (default 640x480)
 * IOSWINE_D3D_VSYNC     Present(1,0) instead of Present(0,0)
 */

#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * The GUID spelled out rather than linked.
 *
 * -ldxguid does not exist for arm64ec in this toolchain: the link fails with
 * "undefined symbol: IID_ID3D11Texture2D (EC symbol)". It is a constant, and
 * one constant is cheaper than an arch-dependent link line.
 */
static const GUID iid_texture2d =
    { 0x6f15aaf2, 0xd208, 0x4e89, { 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/*
 * Two shaders, because the difference between them is a measurement.
 *
 * The plain one takes no input at all; the other reads a per-frame constant
 * buffer, which is how every real game moves anything. Running the same test
 * both ways separates "the swapchain presents nothing" from "constant buffers
 * do not arrive", and those have nothing to do with each other. Selected with
 * IOSWINE_D3D_CBUF so the regression suite can check both.
 */
static const char *hlsl_plain =
    "struct VSOut { float4 pos : SV_POSITION; float4 col : COLOR; };\n"
    "VSOut vs_main(uint id : SV_VertexID) {\n"
    "  float2 p[3] = { float2(0.0, 0.8), float2(0.8, -0.8), float2(-0.8, -0.8) };\n"
    "  VSOut o;\n"
    "  o.pos = float4(p[id], 0.0, 1.0);\n"
    "  o.col = float4(1.0, 0.0, 0.0, 1.0);\n"
    "  return o;\n"
    "}\n"
    "float4 ps_main(VSOut i) : SV_TARGET { return i.col; }\n";

static const char *hlsl_cbuf =
    "cbuffer Params : register(b0) { float4 ofs; };\n"
    "struct VSOut { float4 pos : SV_POSITION; float4 col : COLOR; };\n"
    "VSOut vs_main(uint id : SV_VertexID) {\n"
    "  float2 p[3] = { float2(0.0, 0.8), float2(0.8, -0.8), float2(-0.8, -0.8) };\n"
    "  VSOut o;\n"
    "  o.pos = float4(p[id] + float2(ofs.x, 0.0), 0.0, 1.0);\n"
    "  o.col = float4(1.0, 0.0, 0.0, 1.0);\n"
    "  return o;\n"
    "}\n"
    "float4 ps_main(VSOut i) : SV_TARGET { return i.col; }\n";

static int fail( const char *what, HRESULT hr )
{
    printf( "d3d11-swap: FAIL %s hr=0x%08lx\n", what, (unsigned long)hr );
    fflush( stdout );
    return 1;
}

static LRESULT CALLBACK wnd_proc( HWND h, UINT m, WPARAM w, LPARAM l )
{
    if (m == WM_DESTROY) { PostQuitMessage( 0 ); return 0; }
    return DefWindowProcW( h, m, w, l );
}

static int env_int( const char *name, int def )
{
    const char *v = getenv( name );
    int n;

    if (!v || !*v) return def;
    n = atoi( v );
    return n > 0 ? n : def;
}

static LONGLONG qpf = 1;

static LONGLONG now_us( void )
{
    LARGE_INTEGER c;
    QueryPerformanceCounter( &c );
    return c.QuadPart * 1000000 / qpf;
}

/*
 * Read the BACK BUFFER, not an offscreen copy.
 *
 * Called before a Present, because with DXGI_SWAP_EFFECT_DISCARD the contents
 * are undefined afterwards -- a check placed after Present would be testing
 * whatever the driver felt like leaving behind, and would pass or fail for
 * reasons that have nothing to do with the triangle.
 */
static int verify_backbuffer( ID3D11Device *dev, ID3D11DeviceContext *ctx,
                              ID3D11Texture2D *back, int width, int height )
{
    ID3D11Texture2D *staging = NULL;
    D3D11_MAPPED_SUBRESOURCE map;
    D3D11_TEXTURE2D_DESC td;
    unsigned red = 0, blue = 0, other = 0, x, y;
    int mid_red, corner_blue;
    HRESULT hr;

    ID3D11Texture2D_GetDesc( back, &td );
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.MiscFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(hr = ID3D11Device_CreateTexture2D( dev, &td, NULL, &staging )))
        return fail( "CreateTexture2D(staging)", hr );

    ID3D11DeviceContext_CopyResource( ctx, (ID3D11Resource *)staging, (ID3D11Resource *)back );
    ID3D11DeviceContext_Flush( ctx );
    if (FAILED(hr = ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)staging, 0,
                                             D3D11_MAP_READ, 0, &map )))
    {
        ID3D11Texture2D_Release( staging );
        return fail( "Map(staging)", hr );
    }

    for (y = 0; y < (unsigned)height; y++)
    {
        const unsigned char *row = (const unsigned char *)map.pData + y * map.RowPitch;
        for (x = 0; x < (unsigned)width; x++)
        {
            const unsigned char *p = row + x * 4;   /* BGRA */
            if (p[2] > 200 && p[1] < 60 && p[0] < 60) red++;
            else if (p[0] > 200 && p[1] < 60 && p[2] < 60) blue++;
            else other++;
        }
    }
    {
        const unsigned char *mid = (const unsigned char *)map.pData
                                 + (height / 2) * map.RowPitch + (width / 2) * 4;
        const unsigned char *corner = (const unsigned char *)map.pData;
        mid_red = mid[2] > 200 && mid[1] < 60 && mid[0] < 60;
        corner_blue = corner[0] > 200 && corner[1] < 60 && corner[2] < 60;
    }
    ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)staging, 0 );
    ID3D11Texture2D_Release( staging );

    printf( "d3d11-swap: backbuffer red=%u blue=%u other=%u centre=%s corner=%s\n",
            red, blue, other, mid_red ? "red" : "NOT-red",
            corner_blue ? "blue" : "NOT-blue" );
    fflush( stdout );
    return mid_red && corner_blue && red > 1000;
}

int main( void )
{
    static const WCHAR class_name[] = L"ioswine_d3d11_swapchain";
    WNDCLASSEXW wc = {0};
    DXGI_SWAP_CHAIN_DESC scd = {0};
    IDXGISwapChain *swap = NULL;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11Buffer *cb = NULL;
    ID3DBlob *vsb = NULL, *psb = NULL, *err = NULL;
    D3D11_BUFFER_DESC bd = {0};
    D3D11_VIEWPORT vp = {0};
    D3D_FEATURE_LEVEL got;
    LARGE_INTEGER freq;
    const float clear[4] = { 0.0f, 0.0f, 1.0f, 1.0f };   /* blue */
    int width  = env_int( "IOSWINE_D3D_W", 640 );
    int height = env_int( "IOSWINE_D3D_H", 480 );
    int seconds = env_int( "IOSWINE_D3D_SECONDS", 5 );
    int vsync = getenv( "IOSWINE_D3D_VSYNC" ) != NULL;
    int use_cbuf = getenv( "IOSWINE_D3D_CBUF" ) != NULL;
    const char *hlsl = use_cbuf ? hlsl_cbuf : hlsl_plain;
    LONGLONG start, mark, deadline, t_present = 0;
    unsigned frames = 0, total_frames = 0, present_fail = 0;
    int verified = -1;
    HWND hwnd;
    MSG msg;
    HRESULT hr;

    QueryPerformanceFrequency( &freq );
    if (freq.QuadPart > 0) qpf = freq.QuadPart;

    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW( NULL );
    wc.hCursor = LoadCursorW( NULL, (const WCHAR *)IDC_ARROW );
    wc.lpszClassName = class_name;
    if (!RegisterClassExW( &wc )) { printf( "d3d11-swap: FAIL RegisterClassExW\n" ); return 1; }

    /* WS_POPUP: no frame, so the swapchain size and the window size agree and
     * a mismatch cannot be blamed on a caption bar. */
    hwnd = CreateWindowExW( 0, class_name, L"d3d11 swapchain", WS_POPUP | WS_VISIBLE,
                            0, 0, width, height, NULL, NULL, wc.hInstance, NULL );
    if (!hwnd) { printf( "d3d11-swap: FAIL CreateWindowExW\n" ); return 1; }
    ShowWindow( hwnd, SW_SHOW );

    scd.BufferDesc.Width = width;
    scd.BufferDesc.Height = height;
    scd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.SampleDesc.Count = 1;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.BufferCount = 2;
    scd.OutputWindow = hwnd;
    scd.Windowed = TRUE;
    scd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                        D3D11_SDK_VERSION, &scd, &swap, &dev, &got, &ctx );
    if (FAILED(hr)) return fail( "D3D11CreateDeviceAndSwapChain", hr );
    printf( "d3d11-swap: device + swapchain %dx%d, feature level %x, vsync %d\n",
            width, height, (unsigned)got, vsync );
    fflush( stdout );

    if (FAILED(hr = IDXGISwapChain_GetBuffer( swap, 0, &iid_texture2d, (void **)&back )))
        return fail( "GetBuffer", hr );
    if (FAILED(hr = ID3D11Device_CreateRenderTargetView( dev, (ID3D11Resource *)back, NULL, &rtv )))
        return fail( "CreateRenderTargetView", hr );

    hr = D3DCompile( hlsl, strlen(hlsl), NULL, NULL, NULL, "vs_main", "vs_5_0", 0, 0, &vsb, &err );
    if (FAILED(hr)) return fail( "D3DCompile(vs)", hr );
    hr = D3DCompile( hlsl, strlen(hlsl), NULL, NULL, NULL, "ps_main", "ps_5_0", 0, 0, &psb, &err );
    if (FAILED(hr)) return fail( "D3DCompile(ps)", hr );
    if (FAILED(hr = ID3D11Device_CreateVertexShader( dev, ID3D10Blob_GetBufferPointer(vsb),
                                                     ID3D10Blob_GetBufferSize(vsb), NULL, &vs )))
        return fail( "CreateVertexShader", hr );
    if (FAILED(hr = ID3D11Device_CreatePixelShader( dev, ID3D10Blob_GetBufferPointer(psb),
                                                    ID3D10Blob_GetBufferSize(psb), NULL, &ps )))
        return fail( "CreatePixelShader", hr );

    if (use_cbuf)
    {
        bd.ByteWidth = 16;
        bd.Usage = D3D11_USAGE_DYNAMIC;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        if (FAILED(hr = ID3D11Device_CreateBuffer( dev, &bd, NULL, &cb )))
            return fail( "CreateBuffer(cb)", hr );
    }

    vp.Width = (float)width;
    vp.Height = (float)height;
    vp.MaxDepth = 1.0f;

    start = mark = now_us();
    deadline = start + (LONGLONG)seconds * 1000000;

    for (;;)
    {
        D3D11_MAPPED_SUBRESOURCE m;
        float params[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        LONGLONG a, b, now;

        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            if (msg.message == WM_QUIT) goto done;
            TranslateMessage( &msg );
            DispatchMessageW( &msg );
        }

        if (cb)
        {
            /* +-0.1 of NDC, so the shape stays centred enough for the check
             * below to hold on whichever frame it happens to run. */
            /* (int) before the subtraction. total_frames is unsigned, so
             * `(total_frames % 20) - 10` wrapped to about 4.29e9 for the first
             * ten frames and put the triangle 43 million NDC units off screen.
             * The back buffer came back pure clear-blue and it read exactly
             * like DXMT never binding the constant buffer. */
            params[0] = 0.1f * (float)((int)(total_frames % 20) - 10) / 10.0f;
            if (total_frames == 3) params[0] = 0.0f;
            if (SUCCEEDED(ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)cb, 0,
                                                   D3D11_MAP_WRITE_DISCARD, 0, &m )))
            {
                memcpy( m.pData, params, sizeof(params) );
                ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)cb, 0 );
            }
        }

        ID3D11DeviceContext_RSSetViewports( ctx, 1, &vp );
        ID3D11DeviceContext_OMSetRenderTargets( ctx, 1, &rtv, NULL );
        ID3D11DeviceContext_ClearRenderTargetView( ctx, rtv, clear );
        ID3D11DeviceContext_VSSetShader( ctx, vs, NULL, 0 );
        if (cb) ID3D11DeviceContext_VSSetConstantBuffers( ctx, 0, 1, &cb );
        ID3D11DeviceContext_PSSetShader( ctx, ps, NULL, 0 );
        ID3D11DeviceContext_IASetPrimitiveTopology( ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
        ID3D11DeviceContext_Draw( ctx, 3, 0 );

        /* Frame 3: late enough that the pipeline is warm, early enough that a
         * failure is reported rather than waited out. Offset 0 on that frame,
         * so the triangle is where the shape test expects it. */
        if (total_frames == 3) verified = verify_backbuffer( dev, ctx, back, width, height );

        a = now_us();
        hr = IDXGISwapChain_Present( swap, vsync ? 1 : 0, 0 );
        b = now_us();
        if (FAILED(hr)) present_fail++;
        t_present += b - a;

        frames++;
        total_frames++;

        now = b;
        if (now - mark >= 2000000)
        {
            printf( "d3d11-swap: %.1f fps  %u frames in %.1fs  present=%.2fms/frame\n",
                    frames * 1000000.0 / (double)(now - mark), frames,
                    (double)(now - mark) / 1e6,
                    (double)t_present / 1000.0 / (double)frames );
            fflush( stdout );
            frames = 0; t_present = 0; mark = now;
        }
        if (now >= deadline) break;
    }

done:
    printf( "d3d11-swap: %u frames total, %u failed Presents\n", total_frames, present_fail );
    if (verified < 0) printf( "d3d11-swap: FAIL never reached the verification frame\n" );
    else if (!verified) printf( "d3d11-swap: FAIL back buffer has no triangle\n" );
    else if (present_fail) printf( "d3d11-swap: FAIL %u Presents failed\n", present_fail );
    else printf( "d3d11-swap: OK swapchain presented %u frames\n", total_frames );
    fflush( stdout );

    /* Deliberately torn down rather than left to ExitProcess: releasing the
     * swapchain is what calls ReleaseMetalView, and a double free of the
     * overlay layer would only show up here. */
    if (rtv) ID3D11RenderTargetView_Release( rtv );
    if (back) ID3D11Texture2D_Release( back );
    if (cb) ID3D11Buffer_Release( cb );
    if (vs) ID3D11VertexShader_Release( vs );
    if (ps) ID3D11PixelShader_Release( ps );
    if (swap) IDXGISwapChain_Release( swap );
    if (ctx) ID3D11DeviceContext_Release( ctx );
    if (dev) ID3D11Device_Release( dev );
    DestroyWindow( hwnd );
    printf( "d3d11-swap: released\n" );
    fflush( stdout );

    return (verified == 1 && !present_fail) ? 0 : 1;
}
