
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>

#include "wine_surface.h"
#include "launcher_settings.h"

static id      host_root_view;
static int     host_screen_width;
static int     host_screen_height;
static CGFloat host_scale = 1.0;

static CGFloat host_render_scale( UIScreen *screen, CGSize area_pt )
{
    CGFloat native = screen.nativeScale > 0 ? screen.nativeScale : 1.0;
    CGFloat cap = 2.0;
    double requested;

    @autoreleasepool
    {
        requested = KitsuneRenderScaleStored( NSUserDefaults.standardUserDefaults );
        if (!(requested >= 1.0))
        {
            NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/render-scale"];
            NSString *f = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
            if (f) requested = [f doubleValue];
        }
    }
    if (requested >= 1.0) cap = (CGFloat)requested;
    else if (area_pt.width > area_pt.height && area_pt.height > 0)
        /* Landscape and nothing chosen: the smallest scale at which an 800x600
         * mode still fits the desktop. Every render target scales with the
         * desktop, so this is also the cheapest valid configuration. */
        cap = (CGFloat)KitsuneMinimumScaleForPoints( area_pt.width, area_pt.height );
    return MIN( native, cap );
}

static int host_safe_area_enabled( void )
{
    @autoreleasepool { return KitsuneSafeAreaStored( NSUserDefaults.standardUserDefaults ); }
}

/* The part of the root view the desktop may use: the safe area when the
 * setting asks for it and the layout has produced one, else the whole view. */
static CGRect host_available_rect( UIView *root )
{
    CGRect f = root.bounds;

    if (!host_safe_area_enabled()) return f;
    if (@available(iOS 11.0, *))
    {
        CGRect safe = root.safeAreaLayoutGuide.layoutFrame;
        if (safe.size.width >= 200 && safe.size.height >= 200) f = safe;
    }
    return f;
}

enum { HOST_ROLE_GDI = 0, HOST_ROLE_OVERLAY = 1, HOST_ROLE_UNKNOWN = -1 };

struct host_layer
{
    CAMetalLayer *layer;
    UIView       *view;    /* the view whose backing layer it is */
    void         *hwnd;    /* the Windows window this belongs to; may be NULL */
    int           role;    /* HOST_ROLE_* */
    struct host_layer *next;
};

static struct host_layer *host_layers;
static pthread_mutex_t host_layers_lock = PTHREAD_MUTEX_INITIALIZER;

static void host_layers_add( struct host_layer *h )
{
    pthread_mutex_lock( &host_layers_lock );
    h->next = host_layers;
    host_layers = h;
    pthread_mutex_unlock( &host_layers_lock );
}

static void host_layers_remove( struct host_layer *h )
{
    struct host_layer **p;

    pthread_mutex_lock( &host_layers_lock );
    for (p = &host_layers; *p; p = &(*p)->next)
        if (*p == h) { *p = h->next; break; }
    pthread_mutex_unlock( &host_layers_lock );
}

static const char *host_role_name( int role )
{
    switch (role)
    {
    case HOST_ROLE_GDI:     return "gdi";
    case HOST_ROLE_OVERLAY: return "overlay";
    default:                return "?";
    }
}

/* The registry entry a CALayer belongs to, or NULL if the layer is not ours. */
static struct host_layer *host_layer_for_calayer( CALayer *l )
{
    struct host_layer *h, *found = NULL;

    pthread_mutex_lock( &host_layers_lock );
    for (h = host_layers; h; h = h->next)
        if ((CALayer *)h->layer == l) { found = h; break; }
    pthread_mutex_unlock( &host_layers_lock );
    return found;
}

@interface WineMetalView : UIView
@end

@implementation WineMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

void wine_surface_host_init( void *root_view )
{
    @autoreleasepool
    {
        UIView *view = (__bridge UIView *)root_view;
        UIScreen *screen = view ? view.window.windowScene.screen : nil;

        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!screen) screen = [UIScreen mainScreen];
        #pragma clang diagnostic pop

        /* nativeBounds, not bounds: bounds is in points and is also rotated
         * with the interface. Scale the native pixel extent down by the same
         * ratio used for the layer so UIKit and Wine coordinates still agree. */
        {
            CGFloat native = screen.nativeScale > 0 ? screen.nativeScale : 1.0;
            host_scale = host_render_scale( screen, CGSizeZero );
            host_screen_width  = (int)lround( screen.nativeBounds.size.width * host_scale / native );
            host_screen_height = (int)lround( screen.nativeBounds.size.height * host_scale / native );
        }
        host_root_view = (__bridge id)root_view;
        [host_root_view retain];

        NSLog( @"wine_surface: root %p screen %dx%d px scale %.1f",
               root_view, host_screen_width, host_screen_height, (double)host_scale );
    }
}

/* The landscape desktop for the current screen and settings, and its scale. */
static int host_landscape_desktop( int *width, int *height, CGFloat *scale )
{
    __block int w = 0, h = 0;
    __block CGFloat sc = 0;
    dispatch_block_t work = ^{
        @autoreleasepool
        {
            UIView *root = (UIView *)host_root_view;
            UIScreen *screen = root.window.windowScene.screen;
            CGRect b = root ? root.bounds : CGRectZero;
            CGFloat lw, lh, s;

            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (!screen) screen = [UIScreen mainScreen];
            #pragma clang diagnostic pop
            if (!root || !screen || b.size.width <= 0 || b.size.height <= 0) return;
            lw = MAX( b.size.width, b.size.height );
            lh = MIN( b.size.width, b.size.height );
            if (host_safe_area_enabled())
            {
                UIEdgeInsets in = root.window.safeAreaInsets;
                if (b.size.width > b.size.height) { lw -= in.left + in.right; lh -= in.top + in.bottom; }
                else
                {
                    /* Portrait now: the notch inset becomes the side inset in
                     * landscape and the home indicator strip is 21 pt there. */
                    lw -= 2 * in.top;
                    lh -= in.bottom > 0 ? 21 : 0;
                }
            }
            s = host_render_scale( screen, CGSizeMake( lw, lh ) );
            w = (int)lround( lw * s );
            h = (int)lround( lh * s );
            sc = s;
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync( dispatch_get_main_queue(), work );
    if (w <= 0 || h <= 0) return 0;
    *width = w;
    *height = h;
    if (scale) *scale = sc;
    return 1;
}

int wine_surface_expected_landscape_desktop( int *width, int *height )
{
    return host_landscape_desktop( width, height, NULL );
}

int wine_surface_host_screen( int *width, int *height )
{
    if (host_screen_width <= 0 || host_screen_height <= 0) return 0;
    *width = host_screen_width;
    *height = host_screen_height;
    return 1;
}

/* Forward-declared: defined below with the desktop views. */
static void host_desktop_sync( void );

static void host_sync_all_drawables( void )
{
    struct host_layer *h;
    CGFloat s = host_scale > 0 ? host_scale : 1.0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    pthread_mutex_lock( &host_layers_lock );
    for (h = host_layers; h; h = h->next)
    {
        CAMetalLayer *layer = (CAMetalLayer *)h->view.layer;
        CGSize b;


        layer.contentsScale = s;
        b = h->view.bounds.size;
        if (b.width > 0 && b.height > 0)
            layer.drawableSize = CGSizeMake( b.width * s, b.height * s );
    }
    pthread_mutex_unlock( &host_layers_lock );
    [CATransaction commit];
}

void wine_surface_host_set_landscape( int landscape )
{
    int w, h;
    CGFloat sc;

    /* The startup snapshot runs before the view has a size, so Auto could not
     * pick the smallest scale an 800x600 game fits and took the 2x fallback
     * (1688x780 on an iPhone 14); the resize on rotation needs the display
     * driver, which is not loaded yet. Size the landscape desktop here, before
     * Wine reads it; 1688x780 is 56% more pixels per frame than 1350x624. */
    if (landscape && host_landscape_desktop( &w, &h, &sc ))
    {
        host_screen_width  = w;
        host_screen_height = h;
        host_scale = sc;
        NSLog( @"wine_surface: landscape desktop %dx%d px scale %.2f", w, h, (double)sc );
        return;
    }
    if (landscape ? host_screen_height > host_screen_width : host_screen_width > host_screen_height)
    {
        int t = host_screen_width;
        host_screen_width  = host_screen_height;
        host_screen_height = t;
    }
}

int wine_surface_host_screen_is_portrait( void )
{
    return host_screen_height > host_screen_width;
}

void wine_surface_host_rotate( void )
{
    dispatch_block_t work = ^{
        @autoreleasepool
        {
            UIView *root = (UIView *)host_root_view;
            UIScreen *screen;
            CGFloat s;
            int new_w, new_h;

            if (!root) return;

            /* Scale can change (the window can move between displays); re-read
             * it. Prefer the scene's screen, fall back to mainScreen. */
            screen = root.window.windowScene.screen;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (!screen) screen = [UIScreen mainScreen];
            #pragma clang diagnostic pop
            CGRect area = host_available_rect( root );

            if (screen) host_scale = host_render_scale( screen, area.size );

            s = host_scale > 0 ? host_scale : 1.0;

            new_w = (int)lround( area.size.width  * s );
            new_h = (int)lround( area.size.height * s );

            {
                static void (*notify)( void );

                if (!notify) notify = dlsym( RTLD_DEFAULT, "wineios_metal_screen_changed" );
                if (notify && new_w > 0 && new_h > 0)
                {
                    host_screen_width  = new_w;
                    host_screen_height = new_h;
                    host_desktop_sync();   /* size the desktop to the new screen
                                            * before the guest re-reads it */
                    host_sync_all_drawables();
                    notify();
                    return;
                }
            }

            /* No guest-side resize available: just re-fit to the new bounds. */
            host_desktop_sync();
            host_sync_all_drawables();
        }
    };

    if ([NSThread isMainThread]) work();
    else dispatch_async( dispatch_get_main_queue(), work );
}

static UIView *host_fit_view;        /* virtual screen -> available area */
static UIView *host_desktop_view;    /* the zoomed one; holds the windows */
static CGFloat host_fit_scale = 1.0; /* points on the glass per desktop point */
static CGFloat host_zoom = 1.0;
static CGFloat host_pan_x, host_pan_y;   /* fit-view points */

/* Main thread. Translation applied after the scale, so the pan is in the
 * parent's units and the clamp below is expressible. */
static void host_desktop_apply( void )
{
    CGAffineTransform t;

    if (!host_desktop_view) return;
    t = CGAffineTransformMakeTranslation( host_pan_x, host_pan_y );
    host_desktop_view.transform = CGAffineTransformScale( t, host_zoom, host_zoom );
}

/* Main thread only. Idempotent, and re-fits on every call so a rotation or a
 * safe-area change is picked up without a separate notification. */
static void host_desktop_sync( void )
{
    UIView *root = (UIView *)host_root_view;
    CGFloat s = host_scale > 0 ? host_scale : 1.0;
    CGFloat vw, vh, fit;

    if (!root) return;

    vw = host_screen_width / s;
    vh = host_screen_height / s;
    if (vw <= 0 || vh <= 0) { vw = root.bounds.size.width; vh = root.bounds.size.height; }
    if (vw <= 0 || vh <= 0) return;

    if (!host_fit_view)
    {
        host_fit_view = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, vw, vh )];
        /* The host owns input; a Wine window must never swallow a touch. */
        host_fit_view.userInteractionEnabled = NO;
        host_fit_view.backgroundColor = [UIColor clearColor];
        /* Above the app's log view, below the input overlay (2000) and its
         * button bar (2001). */
        host_fit_view.layer.zPosition = 1000;
        [root addSubview:host_fit_view];

        host_desktop_view = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, vw, vh )];
        host_desktop_view.userInteractionEnabled = NO;
        host_desktop_view.backgroundColor = [UIColor clearColor];
        [host_fit_view addSubview:host_desktop_view];
    }

    CGRect area = host_available_rect( root );

    fit = fmin( area.size.width / vw, area.size.height / vh );
    if (!(fit > 0)) fit = 1.0;
    host_fit_scale = fit;
    fprintf( stderr, "wineios:host[desktop-sync]: root %.0fx%.0f pt, screen %dx%d px, scale %.2f -> desktop %.0fx%.0f pt, fit %.3f\n",
             (double)root.bounds.size.width, (double)root.bounds.size.height,
             host_screen_width, host_screen_height, (double)s, (double)vw, (double)vh, (double)fit );

    host_fit_view.bounds = CGRectMake( 0, 0, vw, vh );
    host_fit_view.center = CGPointMake( CGRectGetMidX( area ), CGRectGetMidY( area ) );
    host_fit_view.transform = CGAffineTransformMakeScale( fit, fit );

    /* Bounds and centre only: the transform belongs to zoom and pan, and a
     * re-fit must not throw them away. */
    host_desktop_view.bounds = CGRectMake( 0, 0, vw, vh );
    host_desktop_view.center = CGPointMake( vw / 2, vh / 2 );
    host_desktop_apply();
}

/* The view holding a given window's given role, or nil. Main thread. */
static UIView *host_view_for( void *hwnd, int role )
{
    struct host_layer *h;
    UIView *found = nil;

    if (!hwnd) return nil;
    pthread_mutex_lock( &host_layers_lock );
    for (h = host_layers; h; h = h->next)
        if (h->hwnd == hwnd && h->role == role && h->view.superview == host_desktop_view)
        { found = h->view; break; }
    pthread_mutex_unlock( &host_layers_lock );
    return found;
}

static void host_dump_hierarchy( const char *when )
{
    NSArray<CALayer *> *layers;
    NSUInteger i;

    if (!host_desktop_view)
    {
        fprintf( stderr, "wineios:host[%s]: no desktop view\n", when );
        return;
    }

    layers = host_desktop_view.layer.sublayers;
    fprintf( stderr, "wineios:host[%s]: desktop now has %lu layers (last = topmost)\n",
             when, (unsigned long)layers.count );
    for (i = 0; i < layers.count; i++)
    {
        CALayer *l = layers[i];
        struct host_layer *h = host_layer_for_calayer( l );
        CGRect f = l.frame;
        CGSize d = [l isKindOfClass:[CAMetalLayer class]] ? ((CAMetalLayer *)l).drawableSize
                                                          : CGSizeZero;

        fprintf( stderr, "wineios:host[%s]:   [%lu] layer %p view %p hwnd %p role %s "
                         "frame %.0f,%.0f %.0fx%.0f pt  hidden=%d alpha=%.2f opaque=%d "
                         "scale=%.1f drawable %.0fx%.0f px\n",
                 when, (unsigned long)i, (void *)l, (void *)(h ? h->view : nil),
                 h ? h->hwnd : NULL, host_role_name( h ? h->role : HOST_ROLE_UNKNOWN ),
                 f.origin.x, f.origin.y, f.size.width, f.size.height,
                 (int)l.hidden, (double)l.opacity, (int)l.opaque,
                 (double)l.contentsScale, (double)d.width, (double)d.height );
    }
}

void wine_surface_desktop_zoom( double scale, double pan_dx, double pan_dy )
{
    CGFloat vw, vh, max_x, max_y;

    if (!host_desktop_view) return;
    if (scale > 0)
    {
        host_zoom *= scale;
        if (host_zoom < 1.0) host_zoom = 1.0;    /* below 1 the desktop shrinks
                                                  * inside a screen it already
                                                  * exactly fills */
        if (host_zoom > 8.0) host_zoom = 8.0;
    }

    /* Root points -> fit-view points: the pan happens inside the fit view. */
    if (host_fit_scale > 0)
    {
        host_pan_x += pan_dx / host_fit_scale;
        host_pan_y += pan_dy / host_fit_scale;
    }

    /* Do not let the desktop be dragged off the glass: at zoom z the scaled
     * desktop overhangs by (z-1)/2 on each side, and that is exactly how far
     * it may travel before an edge comes into view. */
    vw = host_desktop_view.bounds.size.width;
    vh = host_desktop_view.bounds.size.height;
    max_x = vw * (host_zoom - 1) / 2;
    max_y = vh * (host_zoom - 1) / 2;
    if (host_pan_x >  max_x) host_pan_x =  max_x;
    if (host_pan_x < -max_x) host_pan_x = -max_x;
    if (host_pan_y >  max_y) host_pan_y =  max_y;
    if (host_pan_y < -max_y) host_pan_y = -max_y;

    host_desktop_apply();
}

void wine_surface_desktop_reset( void )
{
    host_zoom = 1.0;
    host_pan_x = host_pan_y = 0;
    host_desktop_apply();
}

/* Wine screen pixels -> points inside the desktop view. No centring: the
 * window goes where Windows put it. */
static CGRect host_rect( int x, int y, int width, int height )
{
    CGFloat s = host_scale > 0 ? host_scale : 1.0;

    return CGRectMake( x / s, y / s, width / s, height / s );
}

void *wine_surface_host_create_layer_ex( void *hwnd, int role,
                                         int width, int height, void **layer_out )
{
    __block struct host_layer *host = NULL;

    if (!host_root_view) return NULL;

    dispatch_block_t make = ^{
        @autoreleasepool
        {
            WineMetalView *view;
            UIView *sibling;
            CGRect frame;

            host_desktop_sync();
            if (!host_desktop_view) return;
            frame = host_rect( 0, 0, width, height );

            if (!(host = calloc( 1, sizeof(*host) ))) return;

            view = [[WineMetalView alloc] initWithFrame:frame];
            /* The Wine window must not swallow touches; the host owns input. */
            view.userInteractionEnabled = NO;
            view.layer.contentsScale = host_scale;
            /* Aspect-fit D3D drawables letterbox inside the raw fullscreen
             * frame. Hide the GDI/log view behind those unused pixels. */
            if (role == HOST_ROLE_OVERLAY) view.backgroundColor = [UIColor blackColor];

            host->hwnd = hwnd;
            host->role = role;
            host->view = view;                       /* +1 from alloc */
            host->layer = (CAMetalLayer *)[view.layer retain];
            ((CAMetalLayer *)view.layer).drawableSize = CGSizeMake( width, height );

            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (role == HOST_ROLE_OVERLAY &&
                (sibling = host_view_for( hwnd, HOST_ROLE_GDI )))
                [host_desktop_view insertSubview:view aboveSubview:sibling];
            else if (role == HOST_ROLE_GDI &&
                     (sibling = host_view_for( hwnd, HOST_ROLE_OVERLAY )))
                [host_desktop_view insertSubview:view belowSubview:sibling];
            else
                [host_desktop_view addSubview:view];
            [CATransaction commit];
            [CATransaction flush];
            host_layers_add( host );

            {
                char when[64];

                snprintf( when, sizeof(when), "create-%s", host_role_name( role ) );
                host_dump_hierarchy( when );
            }
        }
    };

    if ([NSThread isMainThread]) make();
    else dispatch_sync( dispatch_get_main_queue(), make );

    if (!host) return NULL;
    if (layer_out) *layer_out = (void *)host->layer;
    return host;
}

int wine_surface_view_to_screen( double vx, double vy, int *out_x, int *out_y )
{
    CGFloat s = host_scale > 0 ? host_scale : 1.0;
    CGPoint local;
    int x, y;

    if (!host_root_view || !host_desktop_view) return 0;

    local = [host_desktop_view convertPoint:CGPointMake( vx, vy )
                                   fromView:(UIView *)host_root_view];
    x = (int)(local.x * s);
    y = (int)(local.y * s);

    if (x < 0 || y < 0) return 0;
    if (host_screen_width > 0 && x >= host_screen_width) return 0;
    if (host_screen_height > 0 && y >= host_screen_height) return 0;

    *out_x = x;
    *out_y = y;
    return 1;
}

void wine_surface_host_move( void *token, int x, int y, int width, int height )
{
    struct host_layer *host = token;

    if (!host) return;

    dispatch_async( dispatch_get_main_queue(), ^{
        host_desktop_sync();
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        host->view.frame = host_rect( x, y, width, height );
        [CATransaction commit];
        /* Flush now: nothing else may commit for a while. */
        [CATransaction flush];
    });
}

/* A hidden window keeps its layer, since Windows programs hide and show the
 * same window (Steam's menus), but must not stay on screen. */
void wine_surface_host_set_hidden( void *token, int hidden )
{
    struct host_layer *host = token;

    if (!host) return;

    dispatch_async( dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        host->view.hidden = hidden ? YES : NO;
        [CATransaction commit];
        [CATransaction flush];
    });
}

void wine_surface_host_detach( void *token )
{
    struct host_layer *host = token;

    if (!host) return;

    host_layers_remove( host );
    dispatch_async( dispatch_get_main_queue(), ^{
        char when[64];

        snprintf( when, sizeof(when), "detach-%s", host_role_name( host->role ) );
        [host->view removeFromSuperview];
        [host->view release];
        [host->layer release];
        free( host );
        host_dump_hierarchy( when );
    });
}
