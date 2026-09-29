
#ifndef IOSWINE_WINE_SURFACE_H
#define IOSWINE_WINE_SURFACE_H

#ifdef __cplusplus
extern "C" {
#endif

void wine_surface_host_init(void *root_view);

/* Screen size in physical pixels. Returns 0 if init has not run, which makes
 * the driver fall back to its default. */
int wine_surface_host_screen(int *width, int *height);
/* The landscape desktop a game launch will get once the interface has rotated:
 * the safe area (when enabled) at the scale the launcher would choose. For
 * game configs written before the rotation happens. Main-thread safe. */
int wine_surface_expected_landscape_desktop(int *width, int *height);

void wine_surface_host_rotate(void);

/* The desktop's orientation for the program about to start. Call on the main
 * thread before Wine starts; later rotations resize it through the driver. */
void wine_surface_host_set_landscape(int landscape);

int wine_surface_host_screen_is_portrait(void);

/* A window's CAMetalLayer, as the backing layer of a host view; `role` says
 * whether it is the window's GDI surface or its D3D overlay. Returns an opaque
 * token, or NULL if there is nothing to attach to. Coordinates everywhere are
 * physical pixels with a top-left origin (Win32 convention). */
void *wine_surface_host_create_layer_ex(void *hwnd, int role,
                                        int width, int height, void **layer_out);

/* Reposition/resize a layer, same coordinate convention. */
void wine_surface_host_move(void *token, int x, int y, int width, int height);

/* Remove the layer and drop the token. */
void wine_surface_host_detach(void *token);

/* Root-view point -> Windows screen pixel. Returns 0 only when the point is
 * outside the virtual screen -- i.e. over the app's own chrome. Undoes the
 * desktop's fit, zoom and pan. Wine does the window hit-testing. */
int wine_surface_view_to_screen(double vx, double vy, int *out_x, int *out_y);

/* Zoom and pan the whole desktop, not one window: a menu and the window that
 * opened it are one scene. `scale` is a multiplicative delta (<= 0 means "pan
 * only"), the pan is in root-view points. */
void wine_surface_desktop_zoom(double scale, double pan_dx, double pan_dy);
void wine_surface_desktop_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* IOSWINE_WINE_SURFACE_H */
