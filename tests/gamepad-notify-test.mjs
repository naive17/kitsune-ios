// Exercise the actual iOS notification collector/worker, not a second model.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const wine = path.join(root, 'third_party/wine');
const source = fs.readFileSync(path.join(wine, 'dlls/sechost/service.c'), 'utf8');
const scratch = path.join(root, '.deploy/tests/xinput');
fs.mkdirSync(scratch, {recursive: true});
function between(a, b) {
  const start = source.indexOf(a), end = source.indexOf(b, start);
  assert(start >= 0 && end > start, a);
  return source.slice(start, end);
}
const code = `
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <pthread.h>
#include "${wine}/include/wine/list.h"
#include "${wine}/include/wine/ios_gamepad.h"
typedef uint32_t DWORD; typedef wchar_t WCHAR; typedef void *HANDLE;
typedef int BOOL,SYSTEM_INFORMATION_CLASS;
typedef struct {uint32_t a; uint16_t b,c; uint8_t d[8];} GUID;
typedef struct {DWORD dbch_size,dbch_devicetype,dbch_reserved;} DEV_BROADCAST_HDR;
typedef struct {DWORD dbcc_size,dbcc_devicetype,dbcc_reserved;GUID dbcc_classguid;WCHAR dbcc_name[1];} DEV_BROADCAST_DEVICEINTERFACE_W;
typedef struct {DWORD dbch_size,dbch_devicetype,dbch_reserved;HANDLE dbch_handle,dbch_hdevnotify;} DEV_BROADCAST_HANDLE;
typedef DWORD (*device_notify_callback)(HANDLE,DWORD,DEV_BROADCAST_HDR*);
#define TRUE 1
#define FALSE 0
#define WINAPI
#define DBT_DEVTYP_DEVICEINTERFACE 5
#define DBT_DEVTYP_HANDLE 6
#define DBT_DEVICEARRIVAL 0x8000
#define DBT_DEVICEREMOVECOMPLETE 0x8004
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define C_ASSERT(x) _Static_assert(x,#x)
#define IsEqualGUID(a,b) (!memcmp(a,b,sizeof(GUID)))
#define FIXME(...) ((void)0)
#define WINE_MESSAGE(...) ((void)0)
static pthread_mutex_t service_cs=PTHREAD_MUTEX_INITIALIZER;
#define EnterCriticalSection pthread_mutex_lock
#define LeaveCriticalSection pthread_mutex_unlock
static HANDLE GetCurrentThread(void) {return NULL;}
static void SetThreadDescription(HANDLE t,const WCHAR *n) {(void)t;(void)n;}
static struct ios_gamepad_info test_info={.version=1};
static int test_snapshot_error,fail_alloc;
static int NtQuerySystemInformation(int c,void*p,size_t n,void*len) {
 assert(c==1001 && n==sizeof(test_info));(void)len;
 if(test_snapshot_error)return -1;
 memcpy(p,&test_info,n);return 0;
}
static void *test_calloc(size_t n,size_t size) {
 if(fail_alloc){--fail_alloc;return NULL;}return calloc(n,size);
}
static void Sleep(DWORD ms);
#define calloc test_calloc
${between('static struct list device_notify_list', 'static DWORD WINAPI device_notify_proc')
  .replace(/\/\* service_cs held; one native notification worker[\s\S]*$/, '')}
#undef calloc

static unsigned callback_count;
static struct device_notify *callback_subscription;
static DWORD callback(HANDLE handle,DWORD code,DEV_BROADCAST_HDR *hdr) {
 assert(handle==(void*)123 && code==DBT_DEVICEARRIVAL && hdr->dbch_devicetype==5);
 // User32 callbacks may unregister and call XInput without deadlocking.
 assert(!pthread_mutex_trylock(&service_cs));
 list_remove(&callback_subscription->entry);free(callback_subscription);callback_subscription=NULL;
 pthread_mutex_unlock(&service_cs);
 struct ios_gamepad_info info;assert(ios_gamepad_snapshot(&info));
 ++callback_count;return 0;
}
static void Sleep(DWORD ms) {assert(ms==16);}
static struct device_notify *subscribe(DWORD pid,BOOL enabled) {
 struct device_notify*n=calloc(1,sizeof(*n)+sizeof(DEV_BROADCAST_HDR));
 assert(n);n->magic=DEVICE_NOTIFY_MAGIC;n->owner_pid=pid;n->ios_gamepads=enabled;
 n->handle=(void*)123;n->callback=callback;list_add_tail(&device_notify_list,&n->entry);return n;
}
static unsigned consume(struct list *events,DWORD code) {
 struct device_notify*e,*next;unsigned n=0;
 LIST_FOR_EACH_ENTRY_SAFE(e,next,events,struct device_notify,entry) {
  struct ios_gamepad_broadcast*b=(void*)e->header;
  assert(e->ios_event==code && b->type==5 && b->reserved==0);
  assert(b->size==offsetof(struct ios_gamepad_broadcast,name)+(wcslen(b->name)+1)*sizeof(WCHAR));
  assert(wcsstr(b->name,L"KITSUNE#GameController#"));
  list_remove(&e->entry);free(e);++n;
 }
 return n;
}
int main(void) {
 struct ios_gamepad_broadcast b;ios_gamepad_event(&b,3);
 assert(wcsstr(b.name,L"#3#"));
 DEV_BROADCAST_HDR all={0};
 assert(notification_filter_matches(&all,L"",(void*)&b,L""));
 DEV_BROADCAST_DEVICEINTERFACE_W filter={.dbcc_size=offsetof(DEV_BROADCAST_DEVICEINTERFACE_W,dbcc_name),.dbcc_devicetype=5,.dbcc_classguid=b.guid};
 assert(notification_filter_matches((void*)&filter,L"",(void*)&b,L""));
 filter.dbcc_classguid.a^=1;
 assert(!notification_filter_matches((void*)&filter,L"",(void*)&b,L""));
 filter.dbcc_size=offsetof(DEV_BROADCAST_DEVICEINTERFACE_W,dbcc_classguid);
 assert(notification_filter_matches((void*)&filter,L"",(void*)&b,L""));
 filter.dbcc_devicetype=6;
 assert(!notification_filter_matches((void*)&filter,L"",(void*)&b,L""));
 struct ios_gamepad_info snapshot;
 assert(ios_gamepad_snapshot(&snapshot));test_snapshot_error=1;
 assert(!ios_gamepad_snapshot(&snapshot));test_snapshot_error=0;
 test_info.version=2;assert(!ios_gamepad_snapshot(&snapshot));test_info.version=1;

 struct list events=LIST_INIT(events);
 struct device_notify*a=subscribe(10,TRUE),*bsub=subscribe(20,TRUE),*ignored=subscribe(10,FALSE);
 assert(ios_collect_gamepad_events(10,&test_info,&events)&&list_empty(&events));
 // Already attached pads are announced to each new process/subscription.
 test_info.pads[0].connected=1;
 assert(ios_collect_gamepad_events(10,&test_info,&events));assert(consume(&events,DBT_DEVICEARRIVAL)==1);
 assert(a->ios_seen==1 && !bsub->ios_seen && !ignored->ios_seen);
 assert(ios_collect_gamepad_events(20,&test_info,&events));assert(consume(&events,DBT_DEVICEARRIVAL)==1);
 for(unsigned i=0;i<1000;++i) {++test_info.pads[0].packet;test_info.pads[0].buttons^=0x1000;
  assert(ios_collect_gamepad_events(10,&test_info,&events));assert(list_empty(&events));}
 // Allocation failure retries; no fake removal on a failed native query.
 test_info.pads[1].connected=1;fail_alloc=1;
 assert(ios_collect_gamepad_events(10,&test_info,&events)&&list_empty(&events)&&a->ios_seen==1);
 assert(ios_collect_gamepad_events(10,&test_info,&events));assert(consume(&events,DBT_DEVICEARRIVAL)==1);
 assert(ios_collect_gamepad_events(10,NULL,&events)&&list_empty(&events)&&a->ios_seen==3);
 test_info.pads[0].connected=test_info.pads[1].connected=0;
 assert(ios_collect_gamepad_events(10,&test_info,&events));assert(consume(&events,DBT_DEVICEREMOVECOMPLETE)==2);
 for(unsigned i=0;i<4;++i)test_info.pads[i].connected=1;
 assert(ios_collect_gamepad_events(10,&test_info,&events));assert(consume(&events,DBT_DEVICEARRIVAL)==4);
 list_remove(&a->entry);free(a);list_remove(&bsub->entry);free(bsub);list_remove(&ignored->entry);free(ignored);
 assert(!ios_collect_gamepad_events(10,&test_info,&events));

 // Run the real worker: callback unregisters itself, worker exits and removes
 // its owner entry rather than keeping a stale process-wide "started" flag.
 for(unsigned i=1;i<4;++i)test_info.pads[i].connected=0;
 callback_subscription=subscribe(30,TRUE);
 struct ios_gamepad_listener*listener=calloc(1,sizeof(*listener));listener->pid=30;
 list_add_tail(&ios_gamepad_listeners,&listener->entry);
 assert(!ios_gamepad_notify_proc(listener));
 assert(callback_count==1 && !callback_subscription && list_empty(&ios_gamepad_listeners));
 puts("GAMEPAD NOTIFY PASS: HID/all-class filters, initial arrival, four slots, per-owner baselines, no analog spam, allocation retry, removal and reentrant unregister");
}
`;
const input = path.join(scratch, 'gamepad-notify.c');
const output = path.join(scratch, 'gamepad-notify');
fs.writeFileSync(input, code);
execFileSync('xcrun', ['--sdk', 'macosx', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
  '-fsanitize=address,undefined', input, '-o', output], {stdio:'inherit'});
execFileSync(output, [], {stdio:'inherit', timeout:30000});
assert(source.includes('if (notify->ios_gamepads) ios_start_gamepad_listener( notify->owner_pid );'));
assert(source.includes('sizeof(*notify) + max(filter->dbch_size, sizeof(*filter))'));
