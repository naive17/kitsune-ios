/*
 * The harness's stand-in for the phone's screen.
 *
 * WHY THIS EXISTS
 *
 * Every automated check in this project stops one step short of the glass. The
 * back buffer is verified (d3d11_swap reads it before Present), the GDI
 * drawable is verified (KITSUNE_CAPTURE, which is what the notepad glyph check
 * reads) -- and the COMPOSITED result, the thing a person looking at the phone
 * sees, is verified by nobody. A bug lived in exactly that gap: on an A15,
 * d3d11_swap.exe presented 1182 frames at 120 fps with zero failures and a back
 * buffer that read back correct, while the screen stayed white for the whole
 * run. Every check passed. The screen was blank.
 *
 * KITSUNE_CAPTURE cannot close that gap, and it is worth being precise about
 * why: it lives inside wineios_layer_present(), which is only ever called from
 * wineios_surface_flush() -- the GDI path. DXMT renders into its overlay layer
 * and presents it itself, so no D3D frame ever passes through that function.
 * Run d3d11_swap.exe with KITSUNE_CAPTURE set and you get exactly one PPM: the
 * window's GDI surface, 640x480, every pixel ffffff. It reports white for a run
 * whose D3D content is perfect, which is not a check, it is a coincidence that
 * happens to match the bug.
 *
 * So: the host hooks the driver dlsyms for, implemented for the harness, plus
 * an offscreen compositor. Layers are kept in the order they would be stacked
 * on screen, each one's last completed frame is captured, and
 * wine_surface_host_composite() paints them into one image in that order and
 * says what colour is at the middle of each window.
 *
 * WHAT THIS PROVES, AND WHAT IT DOES NOT
 *
 * Proves: which layers exist, which window and role each belongs to, their
 * z-ORDER, their rectangles, and that the topmost layer over a window has the
 * pixels the guest drew. That is enough to fail on "the overlay is behind the
 * GDI surface", "the overlay is at the wrong origin", "the overlay was never
 * added", and "the overlay is empty" -- all of which look identical in the
 * logs this port had.
 *
 * Does NOT prove: that CoreAnimation on a phone will composite the same tree
 * the same way. This paints the layers itself. A layer misconfigured in a way
 * only the real compositor reacts to -- presentsWithTransaction set on a layer
 * somebody else presents with -[MTLCommandBuffer presentDrawable:], which is
 * precisely the bug above -- is invisible here, so that one invariant is
 * asserted directly instead, in wine_surface_host_composite().
 *
 * (CARenderer would have given a real compositor offscreen. Measured on this
 * machine, macOS 27 / M1: a CARenderer bound to an MTLTexture reports an empty
 * updateBounds for a detached layer tree and renders nothing at all, even for a
 * plain white CALayer with no Metal involved. Not pursued further.)
 *
 * OFF unless KITSUNE_HOST_SURFACE=1. With it unset every entry point below
 * returns "no host", the driver takes its existing headless path, and nothing
 * about the other checks changes.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Mirrors enum wineios_layer_role in dlls/wineios.drv/wineios_metal.h and the
 * HOST_ROLE_* in src/ios/wine_surface.m. */
enum { HOST_ROLE_GDI = 0, HOST_ROLE_OVERLAY = 1, HOST_ROLE_UNKNOWN = -1 };

static const char *role_name( int role )
{
    switch (role)
    {
    case HOST_ROLE_GDI:     return "gdi";
    case HOST_ROLE_OVERLAY: return "overlay";
    default:                return "?";
    }
}

/*
 * A CAMetalLayer that remembers what was last drawn into it.
 *
 * The copy is taken from the drawable being HANDED OUT, before the caller
 * renders into it, which is not a mistake: a drawable comes back out of the
 * pool only once its previous use has been presented and released, so the
 * texture at that moment holds a COMPLETE earlier frame. Copying the drawable
 * we just gave away would race the caller's own rendering; copying the one it
 * is about to overwrite cannot. The cost is that the captured frame is a few
 * frames stale, which does not matter to "is this red or is it white".
 */
@interface WineHarnessLayer : CAMetalLayer
{
@public
    id<MTLTexture> captured;
}
@end

static id<MTLCommandQueue> harness_queue;
static pthread_mutex_t harness_lock = PTHREAD_MUTEX_INITIALIZER;

static void harness_capture( WineHarnessLayer *layer, id<MTLTexture> src )
{
    id<MTLCommandBuffer> cmd;
    id<MTLBlitCommandEncoder> blit;

    if (!src || !layer.device) return;

    pthread_mutex_lock( &harness_lock );
    if (!harness_queue) harness_queue = [[layer.device newCommandQueue] retain];

    if (!layer->captured || layer->captured.width != src.width ||
        layer->captured.height != src.height)
    {
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:src.width
                                                              height:src.height
                                                           mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        [layer->captured release];
        layer->captured = [[layer.device newTextureWithDescriptor:desc] retain];
    }
    if (!layer->captured || src.pixelFormat != MTLPixelFormatBGRA8Unorm)
    {
        pthread_mutex_unlock( &harness_lock );
        return;
    }

    cmd = [harness_queue commandBuffer];
    blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake( 0, 0, 0 )
               sourceSize:MTLSizeMake( src.width, src.height, 1 )
                toTexture:layer->captured destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake( 0, 0, 0 )];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    pthread_mutex_unlock( &harness_lock );
}

@implementation WineHarnessLayer
- (id<CAMetalDrawable>)nextDrawable
{
    id<CAMetalDrawable> d = [super nextDrawable];

    if (d) harness_capture( self, d.texture );
    return d;
}
@end

/* One entry per layer on the "screen", in compositing order: [0] is at the
 * back, the last is on top. Same contract as the desktop view's subviews on
 * iOS, and placed by the same rule, so a z-order bug reproduces here. */
struct host_entry
{
    WineHarnessLayer *layer;
    void             *hwnd;
    int               role;
    int               x, y, w, h;
    int               hidden;
};

#define HOST_MAX_ENTRIES 64
static struct host_entry host_entries[HOST_MAX_ENTRIES];
static unsigned host_entry_count;
static pthread_mutex_t host_entries_lock = PTHREAD_MUTEX_INITIALIZER;

static int host_screen_w, host_screen_h;

static int host_enabled( void )
{
    static int state = -1;

    if (state < 0)
    {
        const char *e = getenv( "KITSUNE_HOST_SURFACE" );

        state = (e && *e && strcmp( e, "0" )) ? 1 : 0;
        if (state)
        {
            host_screen_w = 1280;
            host_screen_h = 720;
        }
    }
    return state;
}

/* Main-thread-only on iOS; there is no main thread here, so the lock is the
 * whole story. Callers are Wine threads. */
static void host_dump_locked( const char *when )
{
    unsigned i;

    fprintf( stderr, "wineios:host[%s]: desktop now has %u layers (last = topmost)\n",
             when, host_entry_count );
    for (i = 0; i < host_entry_count; i++)
    {
        struct host_entry *e = &host_entries[i];

        fprintf( stderr, "wineios:host[%s]:   [%u] layer %p hwnd %p role %s "
                         "frame %d,%d %dx%d px  hidden=%d  drawable %.0fx%.0f  content %s\n",
                 when, i, (void *)e->layer, e->hwnd, role_name( e->role ),
                 e->x, e->y, e->w, e->h, e->hidden,
                 (double)e->layer.drawableSize.width, (double)e->layer.drawableSize.height,
                 e->layer->captured ? "yes" : "NONE" );
    }
}

/* Where a new layer goes. The rule is the one src/ios/wine_surface.m applies on
 * device: a window's overlay directly above that window's GDI surface, a GDI
 * surface directly below that window's overlay, anything else on top. */
static unsigned host_insert_index( void *hwnd, int role )
{
    unsigned i;

    if (hwnd)
    {
        if (role == HOST_ROLE_OVERLAY)
        {
            for (i = 0; i < host_entry_count; i++)
                if (host_entries[i].hwnd == hwnd && host_entries[i].role == HOST_ROLE_GDI)
                    return i + 1;
        }
        else if (role == HOST_ROLE_GDI)
        {
            for (i = 0; i < host_entry_count; i++)
                if (host_entries[i].hwnd == hwnd && host_entries[i].role == HOST_ROLE_OVERLAY)
                    return i;
        }
    }
    return host_entry_count;
}

/* The harness's stand-in for a rotation: KITSUNE_TEST_SCREEN_CHANGE. */
void wine_surface_host_test_resize( int width, int height )
{
    if (!host_enabled()) return;
    host_screen_w = width;
    host_screen_h = height;
}

int wine_surface_host_screen( int *width, int *height )
{
    if (!host_enabled()) return 0;
    *width = host_screen_w;
    *height = host_screen_h;
    return 1;
}

void *wine_surface_host_create_layer_ex( void *hwnd, int role, int width, int height,
                                         void **layer_out )
{
    WineHarnessLayer *layer;
    unsigned at, i;

    if (!host_enabled()) return NULL;
    if (width <= 0 || height <= 0) return NULL;

    layer = [[WineHarnessLayer layer] retain];
    layer.drawableSize = CGSizeMake( width, height );
    layer.framebufferOnly = NO;   /* the capture blit reads it */

    pthread_mutex_lock( &host_entries_lock );
    if (host_entry_count >= HOST_MAX_ENTRIES)
    {
        pthread_mutex_unlock( &host_entries_lock );
        [layer release];
        return NULL;
    }
    at = host_insert_index( hwnd, role );
    for (i = host_entry_count; i > at; i--) host_entries[i] = host_entries[i - 1];
    host_entries[at].layer = layer;
    host_entries[at].hwnd = hwnd;
    host_entries[at].role = role;
    host_entries[at].x = host_entries[at].y = 0;
    host_entries[at].w = width;
    host_entries[at].h = height;
    host_entry_count++;
    {
        char when[64];
        snprintf( when, sizeof(when), "create-%s", role_name( role ) );
        host_dump_locked( when );
    }
    pthread_mutex_unlock( &host_entries_lock );

    if (layer_out) *layer_out = (void *)layer;
    /* The LAYER is the token; see host_entry_for_token(). */
    return (void *)layer;
}

/*
 * Tokens are found by LAYER, not held as pointers into the array.
 *
 * The array is compacted on removal and shifted on insert, so an entry's
 * address is not stable and a token that was one would dangle the first time a
 * window closed. The driver hands the token straight back, so the layer it was
 * created with is the reliable identity.
 */
static struct host_entry *host_entry_for_token( void *token )
{
    unsigned i;

    for (i = 0; i < host_entry_count; i++)
        if (host_entries[i].layer == (WineHarnessLayer *)token) return &host_entries[i];
    return NULL;
}

void wine_surface_host_move( void *token, int x, int y, int width, int height )
{
    struct host_entry *e;

    if (!host_enabled() || !token) return;
    pthread_mutex_lock( &host_entries_lock );
    if ((e = host_entry_for_token( token )))
    {
        e->x = x; e->y = y;
        if (width > 0) e->w = width;
        if (height > 0) e->h = height;
    }
    pthread_mutex_unlock( &host_entries_lock );
}

/* As on device: the entry stays, and is left out of the composited screen. */
void wine_surface_host_set_hidden( void *token, int hidden )
{
    struct host_entry *e;

    if (!host_enabled() || !token) return;
    pthread_mutex_lock( &host_entries_lock );
    if ((e = host_entry_for_token( token )) && e->hidden != !!hidden)
    {
        e->hidden = !!hidden;
        host_dump_locked( hidden ? "hide" : "show" );
    }
    pthread_mutex_unlock( &host_entries_lock );
}

void wine_surface_host_detach( void *token )
{
    unsigned i;

    if (!host_enabled() || !token) return;
    pthread_mutex_lock( &host_entries_lock );
    for (i = 0; i < host_entry_count; i++)
        if (host_entries[i].layer == (WineHarnessLayer *)token)
        {
            char when[64];
            WineHarnessLayer *l = host_entries[i].layer;

            snprintf( when, sizeof(when), "detach-%s", role_name( host_entries[i].role ) );
            memmove( &host_entries[i], &host_entries[i + 1],
                     (host_entry_count - i - 1) * sizeof(host_entries[0]) );
            host_entry_count--;
            [l->captured release];
            l->captured = nil;
            [l release];
            host_dump_locked( when );
            break;
        }
    pthread_mutex_unlock( &host_entries_lock );
}

/* ---------------------------------------------------------------- compositor */

static unsigned char *host_composite_pixels( int *out_w, int *out_h )
{
    unsigned char *screen;
    size_t stride;
    unsigned i;
    int W = host_screen_w, H = host_screen_h;

    if (W <= 0 || H <= 0) return NULL;
    stride = (size_t)W * 4;
    if (!(screen = malloc( stride * H ))) return NULL;
    /* Not black and not white: both are colours a real bug produces, and a
     * cleared-to-nothing background that happens to match the failure is how a
     * check ends up unable to fail. */
    memset( screen, 0x40, stride * H );

    for (i = 0; i < host_entry_count; i++)
    {
        struct host_entry *e = &host_entries[i];
        id<MTLTexture> t = e->layer->captured;
        unsigned char *tile;
        int tw, th, y;

        if (!t || e->hidden) continue;
        tw = (int)t.width; th = (int)t.height;
        if (!(tile = malloc( (size_t)tw * th * 4 ))) continue;
        [t getBytes:tile bytesPerRow:tw * 4
         fromRegion:MTLRegionMake2D( 0, 0, tw, th ) mipmapLevel:0];

        for (y = 0; y < th; y++)
        {
            int sy = e->y + y, copy;

            if (sy < 0 || sy >= H) continue;
            if (e->x >= W) break;
            copy = tw;
            if (e->x + copy > W) copy = W - e->x;
            if (copy <= 0) break;
            memcpy( screen + (size_t)sy * stride + (size_t)e->x * 4,
                    tile + (size_t)y * tw * 4, (size_t)copy * 4 );
        }
        free( tile );
    }

    *out_w = W;
    *out_h = H;
    return screen;
}

/*
 * Paint the layer stack into one image and say what is where.
 *
 * The readout is per WINDOW, at the centre and the top-left corner of the
 * window's own rectangle in the composited image -- not at the centre of the
 * screen, because where a window sits is one of the things being tested and
 * hard-coding it would make the check agree with the bug.
 */
void wine_surface_host_composite( const char *path )
{
    unsigned char *screen;
    int W = 0, H = 0;
    unsigned i;
    FILE *f;

    if (!host_enabled()) return;

    pthread_mutex_lock( &host_entries_lock );
    screen = host_composite_pixels( &W, &H );
    if (!screen) { pthread_mutex_unlock( &host_entries_lock ); return; }

    for (i = 0; i < host_entry_count; i++)
    {
        struct host_entry *e = &host_entries[i];
        unsigned j, topmost = i;
        int cx, cy;
        const unsigned char *c, *k;

        /* Report once per window, from its TOPMOST layer: that is the one whose
         * rectangle the user is looking at. */
        for (j = i + 1; j < host_entry_count; j++)
            if (host_entries[j].hwnd == e->hwnd) topmost = j;
        if (topmost != i) continue;

        cx = e->x + e->w / 2;
        cy = e->y + e->h / 2;
        if (cx < 0 || cy < 0 || cx >= W || cy >= H) continue;
        c = screen + ((size_t)cy * W + cx) * 4;
        k = screen + ((size_t)(e->y < H ? e->y : 0) * W + (e->x < W ? e->x : 0)) * 4;

        fprintf( stderr, "wineios:host: screen hwnd %p rect %d,%d %dx%d top=%s "
                         "centre=%02x%02x%02x corner=%02x%02x%02x\n",
                 e->hwnd, e->x, e->y, e->w, e->h, role_name( e->role ),
                 c[2], c[1], c[0], k[2], k[1], k[0] );

        /*
         * The one invariant this compositor cannot observe, asserted instead.
         *
         * presentsWithTransaction on a layer that somebody else presents with
         * -[MTLCommandBuffer presentDrawable:] is the combination Apple
         * documents as invalid, and it is what kept a perfectly rendered D3D
         * frame off an iPhone's screen while every check here passed. DXMT
         * presents the overlay that way (dxmt_context.cpp), so the flag must be
         * off on it -- and no offscreen compositor will ever notice, because
         * nothing offscreen is transacting.
         */
        if (e->role == HOST_ROLE_OVERLAY && e->layer.presentsWithTransaction)
            fprintf( stderr, "wineios:host: FAIL overlay layer %p has "
                             "presentsWithTransaction set; DXMT presents it with "
                             "presentDrawable: and the frames will not reach the screen\n",
                     (void *)e->layer );
    }
    pthread_mutex_unlock( &host_entries_lock );

    if (path && *path && (f = fopen( path, "wb" )))
    {
        int x, y;

        fprintf( f, "P6\n%d %d\n255\n", W, H );
        for (y = 0; y < H; y++)
            for (x = 0; x < W; x++)
            {
                const unsigned char *p = screen + ((size_t)y * W + x) * 4;
                unsigned char rgb[3] = { p[2], p[1], p[0] };

                fwrite( rgb, 1, 3, f );
            }
        fclose( f );
        fprintf( stderr, "wineios:host: wrote composite %s (%dx%d)\n", path, W, H );
    }
    free( screen );
}

/*
 * A thread, because nothing else here has a run loop.
 *
 * KITSUNE_HOST_COMPOSITE=<path> writes the composited screen there every half
 * second for as long as the process lives, overwriting. The last write before
 * the guest exits is the one a check reads, and a periodic write means the
 * check does not have to guess when the picture is ready.
 */
static void *host_composite_thread( void *arg )
{
    const char *path = arg;

    for (;;)
    {
        usleep( 500 * 1000 );
        wine_surface_host_composite( path );
    }
    return NULL;
}

__attribute__((constructor))
static void host_surface_init( void )
{
    const char *path;

    if (!host_enabled()) return;
    fprintf( stderr, "wineios:host: harness surface enabled, screen %dx%d\n",
             host_screen_w, host_screen_h );
    if ((path = getenv( "KITSUNE_HOST_COMPOSITE" )) && *path)
    {
        pthread_t t;

        pthread_create( &t, NULL, host_composite_thread, (void *)path );
        pthread_detach( t );
    }
}
