/*
 * Does input actually reach a guest window?
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
 * "The events are being posted" and "a window received them" are different
 * claims, and only the second one is worth anything. Every earlier check of
 * this path stopped at the first: the driver counted what it sent and the
 * server probe showed what it routed, and both were happy while the guest got
 * nothing -- absolute coordinates were arriving in the wrong units and the
 * server clamped every one of them into the bottom-right corner.
 *
 * So this reports what a WINDOW SAW. It covers the virtual screen, so an event
 * aimed anywhere on screen lands on it, and it prints the coordinates it was
 * given rather than merely a count: a click delivered to the wrong place still
 * fails the check.
 *
 * Runs against the harness's KITSUNE_TEST_INPUT injection, which sends five
 * moves, a left click and the 'A' key about twelve seconds in. The verdict is
 * a single line so the regression suite can grep it.
 *
 * -nostdlib with a custom entry point, like the x86-64 guests, and for a
 * sharper reason here: mingw's prebuilt CRT startup objects are compiled
 * WITHOUT -ffixed-x28, and this port keeps the TEB in x28. Linking crt2.o
 * destroyed the TEB before main() ran -- a read fault at 0x49 with x28=0x1,
 * every time. Nothing in this file may pull in the C runtime.
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
    char buf[16];
    int i = sizeof(buf) - 1;
    int neg = v < 0;
    unsigned u = neg ? (unsigned)-v : (unsigned)v;

    buf[i] = 0;
    do { buf[--i] = '0' + (u % 10); u /= 10; } while (u);
    if (neg) buf[--i] = '-';
    print( buf + i );
}

static int n_move, n_down, n_up, n_char;
/* Leave tracking, as Chromium does to clear hover: in the popup run the
 * cursor moves from this window onto the popup, so it must be told it left. */
static int tracking_leave, n_leave;
static int last_x = -1, last_y = -1;
static int down_x = -1, down_y = -1;
static int got_char;

/*
 * A second window, owned by the first and covering the point the harness
 * clicks, exactly as a dialog or a menu covers the window that opened it.
 *
 * Reported from device: "in popups the mouse does not work, not being able to
 * click" -- Notepad's About dialog drew in the right place and swallowed
 * nothing. A single window cannot show that. The failure needs two windows
 * overlapping the same pixel, so that "which one gets the click" has an answer
 * that can be wrong: the host used to answer it from a creation-ordered list,
 * and now leaves it to Wine, and this is what tells the two apart.
 */
static int n_mouseactivate;
static int getenv_flag_noactivate;

static int pop_down, pop_move, pop_tracking, pop_leave;
static int pop_x = -1, pop_y = -1;

/*
 * A real tracking MENU, which is a different animal from an overlapping
 * window.
 *
 * The device says clicks inside popups do nothing, while its own diagnostics
 * show the click hit-testing correctly to <#32768> -- the menu class -- with
 * the owner window holding capture, which is exactly what Windows does. So
 * routing is right and something about the menu's own loop is not, and the
 * plain-window popup test cannot see it: TrackPopupMenu runs a modal
 * PeekMessage loop, takes capture, and does its own hit-testing on message
 * coordinates rather than receiving WM_LBUTTONDOWN at a window proc at all.
 *
 * TrackPopupMenu with TPM_RETURNCMD returns the item id it selected, or 0. It
 * is the whole verdict, in one integer, from inside the code being tested.
 */
#define MENU_ITEM_ID 4242
static int menu_result = -1;

/*
 * A child BUTTON control, which is what the device is actually failing on.
 *
 * "Click on the About popup works only on the title bar ... inside, the Ok and
 * License buttons were not pressable." The title bar is non-client and is
 * handled by the top-level window itself; a button is a CHILD window, and a
 * child never gets its own surface or layer here -- it paints into its
 * parent's -- so the only thing that routes a click into one is win32u's
 * client-side dispatch. Nothing in this suite had exercised that: the earlier
 * popup test watched WM_LBUTTONDOWN arrive at a top-level window proc, which
 * is the case that already worked.
 *
 * BN_CLICKED, not WM_LBUTTONDOWN: a button that receives the press and never
 * reports a click is a different bug from one that receives nothing, and the
 * device cannot tell them apart.
 */
#define BUTTON_ID 4300
static int btn_clicked;

/*
 * Subclass the button to watch WM_NCHITTEST.
 *
 * window_from_point walks the hit list front to back and sends each candidate
 * WM_NCHITTEST; a window answering HTTRANSPARENT is SKIPPED and the search
 * continues behind it. That is the one way a control can be in the list, be
 * under the cursor, and still not be chosen -- which is what the traces show
 * (scope 0x10028 returning 0x10028, the parent, with the button in the tree).
 * So log what the control actually answers.
 */
static WNDPROC btn_orig;
static int nchit_calls, nchit_last = -1, btn_raw_down;

static LRESULT CALLBACK btn_proc( HWND h, UINT msg, WPARAM wp, LPARAM lp )
{
    LRESULT r = CallWindowProcW( btn_orig, h, msg, wp, lp );

    if (msg == WM_NCHITTEST) { nchit_calls++; nchit_last = (int)r; }
    if (msg == WM_LBUTTONDOWN) btn_raw_down++;
    return r;
}

static LRESULT CALLBACK pop_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_MOUSEMOVE:
        pop_move++;
        if (!pop_tracking)
        {
            TRACKMOUSEEVENT t = { sizeof(t), TME_LEAVE, hwnd, 0 };
            pop_tracking = TrackMouseEvent( &t );
        }
        return 0;
    case WM_MOUSELEAVE:
        pop_leave++;
        pop_tracking = 0;
        return 0;
    case WM_LBUTTONDOWN:
        pop_down++;
        pop_x = (short)LOWORD(lp);
        pop_y = (short)HIWORD(lp);
        return 0;
    }
    return DefWindowProcW( hwnd, msg, wp, lp );
}

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_MOUSEMOVE:
        n_move++;
        last_x = (short)LOWORD(lp);
        last_y = (short)HIWORD(lp);
        if (!tracking_leave)
        {
            TRACKMOUSEEVENT t = { sizeof(t), TME_LEAVE, hwnd, 0 };
            tracking_leave = TrackMouseEvent( &t );
        }
        return 0;
    case WM_MOUSELEAVE:
        n_leave++;
        tracking_leave = 0;
        return 0;
    case WM_LBUTTONDOWN:
        n_down++;
        down_x = (short)LOWORD(lp);
        down_y = (short)HIWORD(lp);
        return 0;
    case WM_LBUTTONUP:
        n_up++;
        return 0;
    case WM_CHAR:
        n_char++;
        got_char = (int)wp;
        return 0;
    case WM_COMMAND:
        if (LOWORD(wp) == BUTTON_ID && HIWORD(wp) == BN_CLICKED) btn_clicked++;
        return 0;
    case WM_MOUSEACTIVATE:
        /*
         * The experiment. process_mouse_message activates the window when a
         * click targets something other than the active window -- which is
         * every click on a child CONTROL, and never a click on the top-level
         * window itself. If set_foreground_window() fails there, eat_msg is
         * set and the click is discarded silently.
         *
         * MA_NOACTIVATE takes that path out: it skips the activation entirely
         * and does not eat. If the button starts receiving clicks with this
         * here and not without it, the activation is the cause.
         */
        n_mouseactivate++;
        if (getenv_flag_noactivate) return MA_NOACTIVATE;
        break;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcW( hwnd, msg, wp, lp );
}

void mainCRTStartup(void)
{
    static const WCHAR class_name[] = L"kitsune_input_probe";
    WNDCLASSEXW wc;
    HWND hwnd, popup = NULL;
    MSG msg;
    DWORD deadline;
    int x = GetSystemMetrics( SM_XVIRTUALSCREEN );
    int y = GetSystemMetrics( SM_YVIRTUALSCREEN );
    int w = GetSystemMetrics( SM_CXVIRTUALSCREEN );
    int h = GetSystemMetrics( SM_CYVIRTUALSCREEN );
    int seconds = 20;
    WCHAR secbuf[16];

    if (GetEnvironmentVariableW( L"KITSUNE_PROBE_SECONDS", secbuf, 16 ))
    {
        int v = 0, i;
        for (i = 0; secbuf[i] >= '0' && secbuf[i] <= '9'; i++) v = v * 10 + (secbuf[i] - '0');
        if (v > 0) seconds = v;
    }
    if (w <= 0) { x = y = 0; w = 800; h = 600; }
    getenv_flag_noactivate = GetEnvironmentVariableW( L"KITSUNE_PROBE_NOACTIVATE", secbuf, 16 ) != 0;

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW( NULL );
    wc.hCursor = LoadCursorW( NULL, (const WCHAR *)IDC_ARROW );
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = class_name;
    if (!RegisterClassExW( &wc ))
    {
        print( "input-probe: FAIL RegisterClassExW\n" );
        ExitProcess( 1 );
    }

    /* WS_POPUP over the whole virtual screen: no frame to miss, and no title
     * bar to swallow a click meant for the client area. */
    hwnd = CreateWindowExW( 0, class_name, L"input probe", WS_POPUP | WS_VISIBLE,
                            x, y, w, h, NULL, NULL, wc.hInstance, NULL );
    if (!hwnd)
    {
        print( "input-probe: FAIL CreateWindowExW\n" );
        ExitProcess( 1 );
    }
    ShowWindow( hwnd, SW_SHOW );
    SetForegroundWindow( hwnd );
    SetFocus( hwnd );

    /*
     * The popup: owned by the window above, on top of it, and covering
     * (640,300) -- where the harness clicks. Registered with its own class so
     * a message arriving at the wrong window is unambiguous.
     *
     * Opt-in, because it takes the click AND the focus away from the main
     * window, which is the point of it and would make the single-window checks
     * read as failures. The suite runs the probe twice.
     */
    if (GetEnvironmentVariableW( L"KITSUNE_PROBE_POPUP", secbuf, 16 ))
    {
        WNDCLASSEXW pc;

        memset( &pc, 0, sizeof(pc) );
        pc.cbSize = sizeof(pc);
        pc.lpfnWndProc = pop_proc;
        pc.hInstance = wc.hInstance;
        pc.hCursor = LoadCursorW( NULL, (const WCHAR *)IDC_ARROW );
        pc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
        pc.lpszClassName = L"kitsune_input_probe_popup";
        if (RegisterClassExW( &pc ))
            popup = CreateWindowExW( 0, pc.lpszClassName, L"popup",
                                     WS_POPUP | WS_BORDER | WS_VISIBLE,
                                     x + 540, y + 200, 200, 200,
                                     hwnd, NULL, wc.hInstance, NULL );
        if (popup)
        {
            ShowWindow( popup, SW_SHOW );
            SetForegroundWindow( popup );
        }
        print( popup ? "input-probe: popup created over 640,300\n"
                     : "input-probe: FAIL no popup\n" );
    }

    print( "input-probe: window covering " );
    print_int( x ); print( "," ); print_int( y ); print( " " );
    print_int( w ); print( "x" ); print_int( h ); print( "\n" );

    /*
     * A push button straddling 640,300, where the harness clicks.
     */
    if (GetEnvironmentVariableW( L"KITSUNE_PROBE_BUTTON", secbuf, 16 ))
    {
        HWND b = CreateWindowExW( 0, L"Button", L"Press me",
                                  WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                  580, 270, 120, 60, hwnd, (HMENU)(ULONG_PTR)BUTTON_ID,
                                  wc.hInstance, NULL );
        print( b ? "input-probe: child button at 580,270 120x60\n"
                 : "input-probe: FAIL no child button\n" );
        if (!b) ExitProcess( 1 );
        {
            RECT r = {0};
            HWND par = GetParent( b );
            GetWindowRect( b, &r );
            print( "input-probe: button parent=" ); print_int( (int)(ULONG_PTR)par );
            print( " same=" );    print_int( par == hwnd );
            print( " visible=" ); print_int( IsWindowVisible( b ) );
            print( " rect=" );    print_int( r.left ); print( "," ); print_int( r.top );
            print( "-" );         print_int( r.right ); print( "," ); print_int( r.bottom );
            print( "\n" );
        }
        /*
         * Ask the SERVER the same questions, through calls that are server
         * round trips rather than client-side reads. GetParent and
         * GetWindowRect can be answered from shared memory; GW_CHILD and the
         * point lookups cannot. If these disagree with the block above, the
         * two window trees really have diverged.
         */
        btn_orig = (WNDPROC)SetWindowLongPtrW( b, GWLP_WNDPROC, (LONG_PTR)btn_proc );
        {
            HWND kid = GetWindow( hwnd, GW_CHILD );
            POINT sp = { x + 640, y + 300 }, cp = { 640, 300 };
            HWND wfp = WindowFromPoint( sp );
            HWND cfp = ChildWindowFromPoint( hwnd, cp );

            print( "input-probe: GW_CHILD=" );   print_int( (int)(ULONG_PTR)kid );
            print( " is_button=" );              print_int( kid == b );
            print( " WindowFromPoint=" );        print_int( (int)(ULONG_PTR)wfp );
            print( " ChildWindowFromPoint=" );   print_int( (int)(ULONG_PTR)cfp );
            print( "\n" );
            /* GA_ROOT on the control is what process_mouse_message feeds to
             * set_foreground_window; the trace shows it arriving as 0. */
            print( "input-probe: desktop=" );   print_int( (int)(ULONG_PTR)GetDesktopWindow() );
            print( " btn.GA_PARENT=" );         print_int( (int)(ULONG_PTR)GetAncestor( b, GA_PARENT ) );
            print( " btn.GA_ROOT=" );           print_int( (int)(ULONG_PTR)GetAncestor( b, GA_ROOT ) );
            print( " top.GA_PARENT=" );         print_int( (int)(ULONG_PTR)GetAncestor( hwnd, GA_PARENT ) );
            print( " top.GA_ROOT=" );           print_int( (int)(ULONG_PTR)GetAncestor( hwnd, GA_ROOT ) );
            print( "\n" );
        }
    }

    /*
     * The menu opens where the harness is about to click. Injection sends five
     * moves ending at 640,300 and then a left click, about twelve seconds in;
     * a menu at 600,280 puts its first item under that point.
     */
    if (GetEnvironmentVariableW( L"KITSUNE_PROBE_MENU", secbuf, 16 ))
    {
        HMENU menu = CreatePopupMenu();

        AppendMenuW( menu, MF_STRING, MENU_ITEM_ID, L"Click me" );
        AppendMenuW( menu, MF_STRING, MENU_ITEM_ID + 1, L"Not this one" );
        /* 600,292 rather than a round number: measured. With the menu top at
         * 280 the click at 640,300 landed on the SECOND item, so an item is
         * about 12 points tall here plus a top border. Anchoring 8 above the
         * click puts it in the middle of the first one. */
        print( "input-probe: tracking a popup menu at 600,292\n" );
        /* Blocks in the menu's own loop until something selects or cancels.
         * TPM_NONOTIFY keeps the owner out of it; the return value is the
         * measurement. */
        menu_result = (int)TrackPopupMenu( menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTBUTTON,
                                           x + 600, y + 292, 0, hwnd, NULL );
        print( "input-probe: menu returned " ); print_int( menu_result ); print( "\n" );
        /* Two verdicts, deliberately. "A click selected SOMETHING" is the
         * property the device is failing -- there, nothing happens at all --
         * and it must not be hidden by this test being fussy about which item
         * a font-dependent layout put under the point. */
        if (menu_result) print( "input-probe: OK menu took the click\n" );
        else print( "input-probe: FAIL menu took no click\n" );
        if (menu_result == MENU_ITEM_ID) print( "input-probe: OK menu selected the aimed item\n" );
        else print( "input-probe: WARN menu selected a different item\n" );
        DestroyMenu( menu );
        ExitProcess( menu_result ? 0 : 1 );
    }

    /*
     * Resize the window repeatedly, which is what dragging a partly off-screen
     * window does to its visible rect -- and what left a ladder of stale
     * layers on the glass.
     */
    if (GetEnvironmentVariableW( L"KITSUNE_PROBE_RESIZE", secbuf, 16 ))
    {
        int i;
        for (i = 0; i < 6; i++)
        {
            SetWindowPos( hwnd, 0, x, y, w, h - i * 140, SWP_NOZORDER | SWP_NOACTIVATE );
            RedrawWindow( hwnd, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN );
            Sleep( 250 );
        }
        print( "input-probe: resized six times\n" );
    }

    deadline = GetTickCount() + seconds * 1000;
    {
        /* Close the popup part-way through, so the run shows a window being
         * destroyed while the process stays alive -- which is what a dialog's
         * Ok button does, and what leaves a layer on screen on device. */
        /* Opt-in: the popup click test needs the popup to still BE there when
         * the injected click arrives at ~12s. Destroying it on a timer by
         * default made that test fail, which is a fair warning about tests
         * that quietly change the scenario they share. */
        DWORD kill_at = GetTickCount() + 6000;
        int killed = !GetEnvironmentVariableW( L"KITSUNE_PROBE_DESTROY", secbuf, 16 );
        /* Hidden, not destroyed: Steam's menus come and go this way. */
        int hide = !!GetEnvironmentVariableW( L"KITSUNE_PROBE_HIDE", secbuf, 16 );
        for (;;)
        {
        if (popup && !killed && (int)(GetTickCount() - kill_at) >= 0)
        {
            killed = 1;
            print( "input-probe: destroying the popup now\n" );
            DestroyWindow( popup );
            popup = NULL;
        }
        if (popup && hide && (int)(GetTickCount() - kill_at) >= 0)
        {
            hide = 0;
            print( "input-probe: hiding the popup now\n" );
            ShowWindow( popup, SW_HIDE );
        }
        if ((int)(GetTickCount() - deadline) >= 0) break;
        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            if (msg.message == WM_QUIT) goto done;
            TranslateMessage( &msg );
            DispatchMessageW( &msg );
        }
        Sleep( 10 );
        }
    }

done:
    print( "input-probe: move=" );  print_int( n_move );
    print( " last=" );              print_int( last_x ); print( "," ); print_int( last_y );
    print( " down=" );              print_int( n_down );
    print( " at=" );                print_int( down_x ); print( "," ); print_int( down_y );
    print( " up=" );                print_int( n_up );
    print( " char=" );              print_int( n_char );
    print( " code=" );              print_int( got_char );
    print( "\n" );

    if (popup)
    {
        print( "input-probe: popup move=" ); print_int( pop_move );
        print( " down=" );                   print_int( pop_down );
        print( " at=" );                     print_int( pop_x ); print( "," ); print_int( pop_y );
        print( "\n" );
        /* The click was aimed at a point the popup covers. If the window
         * underneath got it instead, the two sides disagree about z-order. */
        print( "input-probe: leave=" ); print_int( n_leave ); print( " popup leave=" ); print_int( pop_leave ); print( "\n" );
        if (n_leave) print( "input-probe: OK the window underneath was told the cursor left\n" );
        else print( "input-probe: FAIL no WM_MOUSELEAVE when the cursor moved onto the popup\n" );
        if (pop_leave) print( "input-probe: OK the popup was told the cursor left\n" );
        else print( "input-probe: FAIL no WM_MOUSELEAVE when the cursor moved off the popup\n" );
        if (pop_down && !n_down) print( "input-probe: OK popup got the click\n" );
        else if (pop_down) print( "input-probe: FAIL click reached BOTH windows\n" );
        else print( "input-probe: FAIL popup got no click\n" );
        ExitProcess( pop_down && !n_down ? 0 : 1 );
    }

    if (n_move && n_down && n_up) print( "input-probe: OK window received mouse\n" );
    else print( "input-probe: FAIL window received no mouse\n" );
    if (n_char) print( "input-probe: OK window received keyboard\n" );
    else print( "input-probe: FAIL window received no keyboard\n" );

    if (GetEnvironmentVariableW( L"KITSUNE_PROBE_BUTTON", secbuf, 16 ))
    {
        print( "input-probe: button clicked=" ); print_int( btn_clicked );
        print( " raw-down=" );                   print_int( btn_raw_down );
        print( " parent-down=" );                print_int( n_down );
        print( " nchittest calls=" );            print_int( nchit_calls );
        print( " last=" );                       print_int( nchit_last );
        print( " mouseactivate=" );              print_int( n_mouseactivate );
        print( "\n" );
        if (btn_clicked) print( "input-probe: OK child control took the click\n" );
        else print( "input-probe: FAIL child control took no click\n" );
        ExitProcess( btn_clicked ? 0 : 1 );
    }

    ExitProcess( (n_move && n_down && n_up && n_char) ? 0 : 1 );
}
