/*
 * Run the iOS-shaped Wine on macOS, in one process, from a terminal.
 *
 * This is the same boot sequence as src/ios/wine_boot.m -- arena, then dlopen
 * ntdll.so, then __wine_main on a dedicated thread with wineserver as another
 * thread in the same process -- minus UIKit and the debugger. Output goes to
 * the terminal, which is the entire point: the device round trip is about six
 * minutes and this is about two seconds.
 *
 * Read the header of src/host/host_arena.c before trusting a pass here. macOS
 * permits several things iOS refuses, so this harness can only prove that the
 * LOGIC is right, never that the platform will allow it.
 */

#define _GNU_SOURCE
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "jit_arena.h"

int host_arena_verify(void);

/* Wine looks this up to decide whether it must re-exec itself under its own
 * loader. Its mere existence selects the no-preloader path. Same reasoning as
 * the iOS app -- see src/ios/wine_boot.m. */
__attribute__((visibility("default")))
const void *wine_main_preload_info = NULL;

static char tree[4096];      /* the staged wine tree (PE modules + nls) */
static char unixdir[4096];   /* where ntdll.so lives */

static void die(const char *what) {
  fprintf(stderr, "harness: %s: %s\n", what, strerror(errno));
  exit(1);
}

/*
 * Persist the prefix.
 *
 * wineserver normally writes system.reg/user.reg when its last client
 * disconnects. As a thread it never gets that moment -- exit() takes every
 * thread down together -- so without this the prefix is rebuilt from scratch on
 * every launch and nothing a user installs survives.
 */
static void flush_prefix_at_exit(void) {
  void (*flush)(void) = dlsym(RTLD_DEFAULT, "wineserver_inproc_flush");
  if (flush) flush();
}

typedef struct { void (*entry)(int, char **); int argc; char **argv; } targs;

/* Read by the main thread's run loop below. __wine_main is documented not to
 * return, so this is the unreachable-path guard rather than the normal exit. */
static int wine_exited;

static void *wine_thread(void *p) {
  targs *a = p;
  a->entry(a->argc, a->argv);
  __atomic_store_n(&wine_exited, 1, __ATOMIC_RELEASE);
  return NULL;    /* not reached: __wine_main does not return */
}

/*
 * Exercise the input path on the harness.
 *
 * The device hung on the first delivered event, and nothing here could
 * reproduce it: the host normally never sends input, so the drain thread's
 * NtUserSendHardwareInput was only ever executed on a phone. With
 * IOSWINE_TEST_INPUT=1 the harness waits for the guest to come up, resolves
 * the driver entry points (dlsym works here even though it does not on iOS)
 * and sends a few events, so a hang in that path shows up locally.
 */
static void *ioswine_test_input( void *arg )
{
    void (*move)( int, int );
    void (*button)( int, int );
    void (*key)( int, int, int );
    int i;

    sleep( 12 );
    move   = dlsym( RTLD_DEFAULT, "wineios_input_mouse_move" );
    button = dlsym( RTLD_DEFAULT, "wineios_input_mouse_button" );
    key    = dlsym( RTLD_DEFAULT, "wineios_input_key" );
    fprintf( stderr, "test-input: move=%p button=%p key=%p\n", move, button, key );
    if (!move || !button || !key) return NULL;

    /* Rotations, as the app reports them (IOSWINE_TEST_SCREEN_CHANGE=WxH[,WxH...]):
     * each must reach Wine, and input must still arrive after them. */
    if (getenv( "IOSWINE_TEST_SCREEN_CHANGE" ))
    {
        void wine_surface_host_test_resize( int width, int height );
        void (*changed)( void ) = dlsym( RTLD_DEFAULT, "wineios_metal_screen_changed" );
        const char *p = getenv( "IOSWINE_TEST_SCREEN_CHANGE" );
        int w, h, n;

        while (sscanf( p, "%dx%d%n", &w, &h, &n ) == 2)
        {
            wine_surface_host_test_resize( w, h );
            fprintf( stderr, "test-input: screen change to %dx%d %s\n", w, h, changed ? "sent" : "<no symbol>" );
            if (changed) changed();
            sleep( 1 );
            p += n;
            if (*p != ',') break;
            p++;
        }
    }

    for (i = 0; i < 5; i++)
    {
        move( 400 + i * 60, 300 );
        fprintf( stderr, "test-input: move %d sent\n", i );
        usleep( 200000 );
    }
    button( 0, 1 ); button( 0, 0 );
    fprintf( stderr, "test-input: click sent\n" );
    key( 0x41, 0, 1 ); key( 0x41, 0, 0 );      /* 'A' */
    fprintf( stderr, "test-input: key sent -- the path did NOT hang\n" );
    /* Back off the probe's popup, which must be told the cursor left. */
    usleep( 500000 );
    move( 400, 300 );
    fprintf( stderr, "test-input: move off the popup sent\n" );

    /*
     * The same string the app prints in its heartbeat on device. Reading it
     * here means a device report and a harness run can be compared line for
     * line instead of by inference -- which is how "hit=0x0" was left
     * ambiguous between "the point is over nothing" and "this probe does not
     * measure what it looks like it measures".
     */
    {
        const char *status = dlsym( RTLD_DEFAULT, "wineios_input_status" );
        fprintf( stderr, "test-input: srv{%s}\n", status ? status : "<no status symbol>" );
    }
    return NULL;
}

/*
 * The app's part in a session, for a run of the session host: with
 * IOSWINE_SESSION_LAUNCH set, that Windows command line is handed to the
 * host's drain thread once, and the harness exits when no program is left,
 * since the host itself never exits.
 */
static int session_launch_taken;

__attribute__((visibility("default")))
int wine_surface_host_take_launch( char *cmdline, size_t cmdline_size, char *cwd, size_t cwd_size )
{
    const char *want = getenv( "IOSWINE_SESSION_LAUNCH" ), *dir = getenv( "IOSWINE_SESSION_CWD" );

    if (!want || __atomic_exchange_n( &session_launch_taken, 1, __ATOMIC_ACQ_REL )) return 0;
    snprintf( cmdline, cmdline_size, "%s", want );
    snprintf( cwd, cwd_size, "%s", dir ? dir : "" );
    fprintf( stderr, "harness: session launch taken\n" );
    return 1;
}

static void *session_watch( void *arg __attribute__((unused)) )
{
    int (*programs)( void ) = dlsym( RTLD_DEFAULT, "wineserver_inproc_user_processes" );
    int seen = 0;

    if (!programs) { fprintf( stderr, "harness: no wineserver_inproc_user_processes\n" ); exit( 1 ); }
    for (;;)
    {
        /* The session host is a process too; nothing counts before it takes the launch. */
        int n = __atomic_load_n( &session_launch_taken, __ATOMIC_ACQUIRE ) ? programs() - 1 : 0;

        if (n > 0 && !seen) fprintf( stderr, "harness: session running %d program(s)\n", n );
        if (n > 0) seen = 1;
        else if (seen)
        {
            fprintf( stderr, "harness: session idle\n" );
            exit( 0 );
        }
        usleep( 100000 );
    }
    return NULL;
}

int main(int argc, char **argv) {
  char prefix[4096], home[4096], dllpath[4096], ntdll[4096], datadir[4096];

  const char *root = getenv("IOSWINE_TREE");
  const char *pfx  = getenv("IOSWINE_PREFIX");

  if (!root) { fprintf(stderr, "harness: set IOSWINE_TREE\n"); return 2; }
  snprintf(tree, sizeof(tree), "%s", root);
  /*
   * IOSWINE_UNIX lets the unix halves live somewhere OTHER than the PE tree,
   * which is the device layout: the .so files must be inside the signed app
   * bundle (iOS will not dlopen a dylib that arrived after install) while the
   * PE modules are a downloaded tree in Documents.
   *
   * Without this the harness could only ever test a single-tree layout, and it
   * missed a real bug because of it: Wine records a builtin's unix half beside
   * wherever the PE was found, so on device it named a .so that does not exist
   * and ws2_32's DllMain failed. An earlier attempt to model the split with a
   * SYMLINK passed, precisely because the symlink made the wrong path valid.
   */
  const char *unixroot = getenv("IOSWINE_UNIX");
  if (unixroot) snprintf(unixdir, sizeof(unixdir), "%s/lib/wine/aarch64-unix", unixroot);
  else snprintf(unixdir, sizeof(unixdir), "%s/lib/wine/aarch64-unix", tree);

  snprintf(home, sizeof(home), "%s/home", tree);
  snprintf(prefix, sizeof(prefix), "%s", pfx ? pfx : "");
  if (!prefix[0]) snprintf(prefix, sizeof(prefix), "%s/prefix", tree);
  mkdir(home, 0755);

  setenv("HOME", home, 1);
  setenv("WINEPREFIX", prefix, 1);
  snprintf(dllpath, sizeof(dllpath), "%s/lib/wine", tree);
  setenv("WINEDLLPATH", dllpath, 1);
  snprintf(datadir, sizeof(datadir), "%s/share/wine", tree);
  setenv("WINEDATADIR", datadir, 1);
  /*
   * We ARE the prefix bootstrap, so say so.
   *
   * Builtin DLLs that have no file in the prefix yet can only be loaded while
   * is_prefix_bootstrap is set (loader.c: find_builtin_without_file). Upstream
   * that flag is handed to the wineboot CHILD via this variable, and the parent
   * clears it again as soon as the child exits. With no child -- iOS cannot
   * fork -- nobody ever had it set, and the very first import failed:
   *     wine: could not load kernel32.dll, status c0000135
   */
  setenv("WINEBOOTSTRAPMODE", "1", 1);
  setenv("WINEDLLOVERRIDES", "winemac.drv,winex11.drv=", 1);
  setenv("DISPLAY", "", 1);
  /*
   * Same default as the device (see wine_boot.m): SDL2 must not choose a
   * renderer that needs Vulkan, because this port has none.
   *
   * SDL_CreateRenderer(-1) takes `direct3d` first, that is d3d9.dll, and the
   * d3d9 in this tree is DXVK -- which aborts the process with an uncaught
   * dxvk::DxvkError when winevulkan cannot find a driver. Kept here as well as
   * on device so the harness reproduces what the phone does; the two
   * environments diverging is what cost this project a day of device round
   * trips over Doom.
   */
  setenv("SDL_RENDER_DRIVER", "software", 0);
  if (getenv("IOSWINE_TEST_INPUT"))
  {
    pthread_t t;
    pthread_create( &t, NULL, ioswine_test_input, NULL );
    pthread_detach( t );
  }
  if (getenv("IOSWINE_SESSION_LAUNCH"))
  {
    pthread_t t;
    pthread_create( &t, NULL, session_watch, NULL );
    pthread_detach( t );
  }
  if (!getenv("WINEDEBUG")) setenv("WINEDEBUG", "+loaddll,+process,+server", 1);

  /* Same ordering as the device: bless before anything maps an image. There is
   * no detach step here because there is no debugger. */
  char err[256] = {0};
  /* 640, not 512: from the pinned base 0x120010000 the arena must reach past
   * 0x140000000 + the exe window for a relocs-stripped exe (Dark Souls) to load
   * at its required base. Matches ARENA_PIN_MIN_MB on device. */
  size_t mb = getenv("ARENA_MB") ? (size_t)atoi(getenv("ARENA_MB")) : 640;

  /* Must match WINE_USER_SHARED_DATA_ADDR in wine/include/wine/ios_shared_data.h.
   * Claim it before the arena is placed, exactly as the app does. */
  if (!ios_jit_arena_reserve((void *)0x120000000ull, 0x10000, err, sizeof(err)))
    fprintf(stderr, "harness: keepout failed: %s\n", err);

  if (!ios_jit_arena_init(mb << 20, err, sizeof(err))) {
    fprintf(stderr, "harness: arena init failed: %s\n", err);
    return 1;
  }
  void *lo = NULL; size_t sz = 0; ptrdiff_t d = 0;
  ios_jit_arena_bounds(&lo, &sz, &d);
  fprintf(stderr, "harness: arena %p-%p delta %#lx (%zu MB)\n",
          lo, (char *)lo + sz, (long)d, sz >> 20);

  ios_jit_arena_release_reserved();   /* Wine maps there itself */

  snprintf(ntdll, sizeof(ntdll), "%s/ntdll.so", unixdir);
  void *h = dlopen(ntdll, RTLD_NOW | RTLD_GLOBAL);
  if (!h) { fprintf(stderr, "harness: dlopen(%s): %s\n", ntdll, dlerror()); return 1; }

  void (*wine_main)(int, char **) = dlsym(h, "__wine_main");
  if (!wine_main) { fprintf(stderr, "harness: no __wine_main\n"); return 1; }
  if (!dlsym(RTLD_DEFAULT, "wineserver_inproc_main")) {
    fprintf(stderr, "harness: wineserver_inproc_main not visible -- link "
                    "libwineserver.a with -Wl,-all_load -Wl,-export_dynamic\n");
    return 1;
  }
  fprintf(stderr, "harness: ntdll.so loaded, in-process wineserver visible\n");
  atexit(flush_prefix_at_exit);

  /* argv[1..] become Wine's command line, same as the real loader. */
  int wargc = argc;
  char **wargv = calloc((size_t)wargc + 1, sizeof(char *));
  wargv[0] = (char *)"wine";
  for (int i = 1; i < argc; i++) wargv[i] = argv[i];
  wargv[wargc] = NULL;

  /* 16 MB stack: Wine's entry installs handlers, sets up a TEB and never
   * returns, which a default worker stack does not survive. */
  static targs a;
  a.entry = wine_main; a.argc = wargc; a.argv = wargv;
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 16 * 1024 * 1024);
  pthread_t tid;
  if (pthread_create(&tid, &at, wine_thread, &a)) die("pthread_create");
  pthread_attr_destroy(&at);

  /*
   * The main thread services the main dispatch queue, because on the device
   * UIKit does and code below here depends on it.
   *
   * wineios.drv presents every frame with dispatch_async(main_queue) -- the
   * thread a CAMetalDrawable is presented from is not negotiable, see
   * dlls/wineios.drv/metal.m -- and DXMT's winemetal unix half configures a
   * CAMetalLayer with dispatch_SYNC to the same queue. With the main thread
   * parked in pthread_join nobody drains that queue: our own presents were
   * silently queued and never ran, and DXMT's setProps would have deadlocked
   * the guest outright. Neither shows up as an error; the first looks like "the
   * window is blank" and the second like "D3D11 hangs".
   *
   * CFRunLoopRunInMode with a timeout rather than CFRunLoopRun: with no input
   * sources of our own CFRunLoopRun returns immediately, and a loop that polls
   * also gives the join below somewhere to happen. __wine_main does not return,
   * so in practice this runs until the guest calls ExitProcess.
   */
  while (!__atomic_load_n(&wine_exited, __ATOMIC_ACQUIRE))
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
  pthread_join(tid, NULL);

  int bad = host_arena_verify();
  fprintf(stderr, "harness: __wine_main returned; arena violations: %d\n", bad);
  return bad ? 1 : 0;
}
