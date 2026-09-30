/*
 * How fast can a window actually be painted?
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
 * "2 fps" was written down four times as this port's headline problem, and it
 * was never a measurement of anything.
 *
 * The number came from wineios_layer_present, which counts PRESENTS, and a
 * present happens only when a window surface is flushed, and a window surface
 * is flushed only when something painted into it. Notepad with a blinking caret
 * paints about twice a second. So "notepad renders at 2.0 fps" says the caret
 * blinked five times in 2.5 seconds -- it is a report of how idle the guest was,
 * not of how fast the pipe is, and no amount of optimising the pipe would move
 * it.
 *
 * A throughput number needs a guest that never idles. This one paints as hard
 * as it can and times the three stages separately, so a slow result names its
 * own cause instead of leaving it to be guessed at:
 *
 *   blit   BitBlt from a DIB into the window's surface bitmap -- Wine's GDI,
 *          plain CPU memory traffic, nothing of ours in it.
 *   end    EndPaint, which is where win32u flushes the surface and therefore
 *          where the whole driver lives: staging upload, nextDrawable, the
 *          blit encoder, the main-thread present.
 *   loop   everything else -- PeekMessage, InvalidateRect, UpdateWindow.
 *
 * KITSUNE_FPS_ROWS invalidates only the top N rows. wineios_surface_flush
 * currently ignores the dirty rect and uploads the entire surface every time;
 * if `end` does not fall when the damage shrinks, that is the proof it should,
 * and if it does fall the upload is not the bottleneck.
 *
 * -nostdlib with its own entry point, for the reason in input-probe.c:
 * mingw's prebuilt crt2.o is compiled without -ffixed-x28 and destroys the TEB.
 */

#include <windows.h>

static void print( const char *s )
{
    DWORD written;
    HANDLE out = GetStdHandle( STD_OUTPUT_HANDLE );
    DWORD len = 0;

    while (s[len]) len++;
    WriteFile( out, s, len, &written, NULL );
}

static void print_int( int v )
{
    char buf[24];
    int i = sizeof(buf) - 1;
    int neg = v < 0;
    unsigned u = neg ? (unsigned)-v : (unsigned)v;

    buf[i] = 0;
    do { buf[--i] = '0' + (u % 10); u /= 10; } while (u);
    if (neg) buf[--i] = '-';
    print( buf + i );
}

/* v/100 with two decimals, integer-only: no CRT here, and no float formatting
 * to reimplement. */
static void print_c2( int v )
{
    int neg = v < 0;
    if (neg) { print( "-" ); v = -v; }
    print_int( v / 100 );
    print( "." );
    print_int( (v / 10) % 10 );
    print_int( v % 10 );
}

static LONGLONG qpf = 1;

static LONGLONG now_us( void )
{
    LARGE_INTEGER c;
    QueryPerformanceCounter( &c );
    return c.QuadPart * 1000000 / qpf;
}

static int env_int( const WCHAR *name, int def )
{
    WCHAR buf[24];
    int v = 0, i;

    if (!GetEnvironmentVariableW( name, buf, 24 )) return def;
    for (i = 0; buf[i] >= '0' && buf[i] <= '9'; i++) v = v * 10 + (buf[i] - '0');
    return i ? v : def;
}

static int cw, ch, dirty_rows;
static HDC memdc;
static DWORD *dib_bits;

/* Two sets: the rolling two-second window, and the whole run. The final line
 * used to reuse the window counters and printed "no frames" whenever the run
 * length was a multiple of the report interval -- the counters had just been
 * reset by the last report. */
static int frames, all_frames;
static LONGLONG t_begin, t_blit, t_end;
static LONGLONG a_begin, a_blit, a_end;

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    PAINTSTRUCT ps;
    HDC hdc;
    LONGLONG a, b, c, d;

    switch (msg)
    {
    case WM_ERASEBKGND:
        /* The blit covers every pixel it is asked about. Letting the class
         * background brush run first would double the memory traffic and
         * measure Wine's brush fill as if it were ours. */
        return 1;

    case WM_PAINT:
        a = now_us();
        hdc = BeginPaint( hwnd, &ps );
        b = now_us();
        if (hdc)
        {
            int h = ps.rcPaint.bottom - ps.rcPaint.top;
            int w = ps.rcPaint.right - ps.rcPaint.left;
            BitBlt( hdc, ps.rcPaint.left, ps.rcPaint.top, w, h,
                    memdc, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY );
        }
        c = now_us();
        EndPaint( hwnd, &ps );
        d = now_us();
        t_begin += b - a; a_begin += b - a;
        t_blit  += c - b; a_blit  += c - b;
        t_end   += d - c; a_end   += d - c;
        frames++;
        all_frames++;
        return 0;

    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcW( hwnd, msg, wp, lp );
}

/* One report line, and the numbers that let it be argued with: per-frame stage
 * costs in milliseconds, so `blit + end + loop` adds up to the frame time and
 * whichever term dominates is the answer. */
static void report_stats( const char *tag, LONGLONG span_us, int f,
                          LONGLONG t_begin, LONGLONG t_blit, LONGLONG t_end )
{
    LONGLONG busy = t_begin + t_blit + t_end;

    if (!f || span_us <= 0) { print( "fps-probe: " ); print( tag ); print( " no frames\n" ); return; }

    print( "fps-probe: " ); print( tag ); print( " " );
    print_c2( (int)(f * 100LL * 1000000 / span_us) ); print( " fps  " );
    print_int( f ); print( " frames in " ); print_int( (int)(span_us / 1000) ); print( "ms  " );
    print( "frame=" ); print_c2( (int)(span_us * 100 / 1000 / f) ); print( "ms " );
    print( "begin=" ); print_c2( (int)(t_begin * 100 / 1000 / f) ); print( "ms " );
    print( "blit=" );  print_c2( (int)(t_blit  * 100 / 1000 / f) ); print( "ms " );
    print( "end=" );   print_c2( (int)(t_end   * 100 / 1000 / f) ); print( "ms " );
    print( "loop=" );  print_c2( (int)((span_us - busy) * 100 / 1000 / f) ); print( "ms " );
    print( "size=" );  print_int( cw ); print( "x" ); print_int( ch );
    print( " rows=" ); print_int( dirty_rows );
    print( "\n" );
}

static void report( const char *tag, LONGLONG span_us )
{
    report_stats( tag, span_us, frames, t_begin, t_blit, t_end );
}

void mainCRTStartup(void)
{
    static const WCHAR class_name[] = L"kitsune_fps_probe";
    WNDCLASSEXW wc;
    BITMAPINFO bi;
    HBITMAP dib;
    HWND hwnd;
    MSG msg;
    LARGE_INTEGER freq;
    LONGLONG start, mark, deadline;
    int seconds = env_int( L"KITSUNE_FPS_SECONDS", 8 );
    int i, n;

    QueryPerformanceFrequency( &freq );
    if (freq.QuadPart > 0) qpf = freq.QuadPart;

    cw = env_int( L"KITSUNE_FPS_W", 0 );
    ch = env_int( L"KITSUNE_FPS_H", 0 );
    if (cw <= 0) cw = GetSystemMetrics( SM_CXVIRTUALSCREEN );
    if (ch <= 0) ch = GetSystemMetrics( SM_CYVIRTUALSCREEN );
    if (cw <= 0 || ch <= 0) { cw = 1280; ch = 720; }
    dirty_rows = env_int( L"KITSUNE_FPS_ROWS", ch );
    if (dirty_rows > ch) dirty_rows = ch;
    if (dirty_rows < 1) dirty_rows = 1;

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = GetModuleHandleW( NULL );
    wc.hCursor       = LoadCursorW( NULL, (const WCHAR *)IDC_ARROW );
    wc.lpszClassName = class_name;
    if (!RegisterClassExW( &wc )) { print( "fps-probe: FAIL RegisterClassExW\n" ); ExitProcess( 1 ); }

    /* A DIB section, not a compatible bitmap: this is the shape a game or a
     * software renderer hands to GDI, and it keeps the source of the blit in
     * plain memory so the cost measured is a copy and not a format conversion.
     * Top-down (negative height) to match the window surface. */
    memset( &bi, 0, sizeof(bi) );
    bi.bmiHeader.biSize        = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth       = cw;
    bi.bmiHeader.biHeight      = -ch;
    bi.bmiHeader.biPlanes      = 1;
    bi.bmiHeader.biBitCount    = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    memdc = CreateCompatibleDC( NULL );
    dib = CreateDIBSection( memdc, &bi, DIB_RGB_COLORS, (void **)&dib_bits, NULL, 0 );
    if (!memdc || !dib || !dib_bits) { print( "fps-probe: FAIL CreateDIBSection\n" ); ExitProcess( 1 ); }
    SelectObject( memdc, dib );

    /* Fill it once with something non-uniform, so a compositor that decided to
     * skip a solid colour could not flatter the result. */
    n = cw * ch;
    for (i = 0; i < n; i++) dib_bits[i] = 0x00203040 + ((i % cw) << 8) + (i / cw);

    hwnd = CreateWindowExW( 0, class_name, L"fps probe", WS_POPUP | WS_VISIBLE,
                            0, 0, cw, ch, NULL, NULL, wc.hInstance, NULL );
    if (!hwnd) { print( "fps-probe: FAIL CreateWindowExW\n" ); ExitProcess( 1 ); }
    ShowWindow( hwnd, SW_SHOW );

    print( "fps-probe: painting " ); print_int( cw ); print( "x" ); print_int( ch );
    print( " for " ); print_int( seconds ); print( "s, dirty rows " ); print_int( dirty_rows );
    print( "\n" );

    /* Drain the show/activate traffic before the clock starts. */
    while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE )) DispatchMessageW( &msg );
    frames = all_frames = 0;
    t_begin = t_blit = t_end = 0;
    a_begin = a_blit = a_end = 0;

    start = mark = now_us();
    deadline = start + (LONGLONG)seconds * 1000000;

    for (;;)
    {
        RECT r;
        LONGLONG now;

        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            if (msg.message == WM_QUIT) goto done;
            DispatchMessageW( &msg );
        }

        /* Change a pixel per frame so nothing downstream can conclude the
         * content is unchanged and elide the upload. */
        dib_bits[(frames * 7919) % n] ^= 0x00ffffff;

        r.left = 0; r.top = 0; r.right = cw; r.bottom = dirty_rows;
        InvalidateRect( hwnd, &r, FALSE );
        UpdateWindow( hwnd );   /* synchronous WM_PAINT: no queue in the loop */

        now = now_us();
        if (now - mark >= 2000000)
        {
            report( "window", now - mark );
            frames = 0; t_begin = t_blit = t_end = 0;
            mark = now;
        }
        if (now >= deadline) break;
    }

done:
    report_stats( "final", now_us() - start, all_frames, a_begin, a_blit, a_end );
    print( "fps-probe: done\n" );
    ExitProcess( 0 );
}
