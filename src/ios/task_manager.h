/*
 * Running-program manager.
 *
 * The driver enumerates top-level windows on a Wine thread and reports them
 * here; close posts WM_CLOSE, kill terminates the owning process. Requests
 * are forwarded to entry points the driver registers at init.
 */
#ifndef IOSWINE_TASK_MANAGER_H
#define IOSWINE_TASK_MANAGER_H

#import <UIKit/UIKit.h>

/* Same layout as struct wineios_task in dlls/wineios.drv/input.c. */
typedef struct {
  void *hwnd;
  unsigned pid, tid;
  int visible;
  char title[96];
} WineTask;

extern NSNotificationName const WineTasksDidUpdateNotification;

BOOL WineTasksAvailable(void);
void WineTasksRequest(void);
NSArray<NSDictionary *> *WineTasksSnapshot(void);   /* @{ hwnd, pid, tid, title } */
void WineTasksClose(void *hwnd);
void WineTasksKill(unsigned pid);

@interface WineTaskListVC : UITableViewController
@end

#endif
