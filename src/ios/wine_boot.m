
#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <unistd.h>

#include "wine_boot.h"
#include "diagnostics.h"
#include "jit_arena.h"

struct wine_preload_info;
__attribute__((visibility("default")))
const struct wine_preload_info *wine_main_preload_info = NULL;

static void set_env(const char *k, NSString *v) {
  setenv(k, v.fileSystemRepresentation, 1);
}

/* The app's Documents: programs, bottles, logs and the Wine tree. */
NSString *IOSWinePersistentDocuments(void) {
  static NSString *cached;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cached = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                 NSUserDomainMask, YES).firstObject;
  });
  return cached;
}

/* The signed unix halves, inside the app bundle. */
NSString *WineUnixRoot(void) {
  return [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:@"lib/wine/aarch64-unix"];
}

NSString *WineTreeRoot(void) {
  return [IOSWinePersistentDocuments() stringByAppendingPathComponent:@"wine"];
}

NSString *WineShaderCacheRoot(void) {
  NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                         NSUserDomainMask, YES)
                         .firstObject;
  return [caches stringByAppendingPathComponent:@"dxmt"];
}

/* The PE tree is installed into Documents, from the bundle or from a Mac; the
 * signed unix halves stay in the bundle. */
BOOL WineTreeInstalled(void) {
  NSString *marker = [WineTreeRoot()
      stringByAppendingPathComponent:@"lib/wine/aarch64-windows/ntdll.dll"];
  return [NSFileManager.defaultManager fileExistsAtPath:marker];
}

static void rewrite_stale_container_paths(NSString *prefix, NSString *docs) {
  NSString *current = nil;
  NSArray<NSString *> *parts = docs.pathComponents;
  for (NSUInteger i = 0; i + 1 < parts.count; i++)
    if ([parts[i] caseInsensitiveCompare:@"Application"] == NSOrderedSame) { current = parts[i + 1]; break; }
  if (current.length != 36) return;

  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:@"(var[/\\\\]+mobile[/\\\\]+containers[/\\\\]+data[/\\\\]+application[/\\\\]+)([0-9A-Fa-f-]{36})"
                           options:NSRegularExpressionCaseInsensitive error:nil];
  NSMutableArray<NSString *> *files = [NSMutableArray array];
  for (NSString *n in @[ @"system.reg", @"user.reg", @"userdef.reg" ])
    [files addObject:[prefix stringByAppendingPathComponent:n]];
  NSString *steam = [docs stringByAppendingPathComponent:@"Apps/Steam"];
  for (NSString *n in @[ @"config/config.vdf", @"config/libraryfolders.vdf", @"steamapps/libraryfolders.vdf",
                         @"config/loginusers.vdf" ])
    [files addObject:[steam stringByAppendingPathComponent:n]];

  for (NSString *path in files) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) continue;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!text) continue;
    __block NSUInteger fixed = 0;
    NSMutableString *out = [text mutableCopy];
    NSArray<NSTextCheckingResult *> *hits = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *m in hits.reverseObjectEnumerator) {
      NSRange u = [m rangeAtIndex:2];
      NSString *old = [text substringWithRange:u];
      if ([old caseInsensitiveCompare:current] == NSOrderedSame) continue;
      /* keep the file's own case convention (Steam writes lowercase) */
      BOOL lower = [old isEqualToString:old.lowercaseString];
      [out replaceCharactersInRange:u withString:lower ? current.lowercaseString : current.uppercaseString];
      fixed++;
    }
    if (!fixed) continue;
    NSData *outData = [out dataUsingEncoding:NSUTF8StringEncoding];
    if (outData && [outData writeToFile:path atomically:YES])
      NSLog(@"[ioswine] container-path fix: %lu stale path(s) -> %@ in %@", (unsigned long)fixed, current,
            path.lastPathComponent);
  }
}

static void prune_when_disk_is_low(NSString *docs)
{
  NSFileManager *fm = NSFileManager.defaultManager;
  NSDictionary *attrs = [fm attributesOfFileSystemForPath:docs error:nil];
  unsigned long long freeMB = [attrs[NSFileSystemFreeSize] unsignedLongLongValue] >> 20;

  NSLog(@"[ioswine] disk: %llu MB free", freeMB);
  if (freeMB > 1500) return;

  NSArray *prunable = @[ @"Apps/Steam/package",
                         @"Apps/Steam/htmlcache",
                         @"Apps/Steam/config/htmlcache",
                         @"Apps/Steam/steamapps/shadercache",
                         @"Apps/Steam/steamapps/downloading",
                         @"Apps/Steam/depotcache" ];
  for (NSString *rel in prunable) {
    NSString *path = [docs stringByAppendingPathComponent:rel];
    if (![fm fileExistsAtPath:path]) continue;
    NSError *err = nil;
    if ([fm removeItemAtPath:path error:&err])
      NSLog(@"[ioswine] disk: pruned %@", rel);
    else
      NSLog(@"[ioswine] disk: could not prune %@: %@", rel, err);
  }
  attrs = [fm attributesOfFileSystemForPath:docs error:nil];
  NSLog(@"[ioswine] disk: %llu MB free after pruning",
        [attrs[NSFileSystemFreeSize] unsignedLongLongValue] >> 20);
}

static void configure_environment(NSString *root) {
  /* Same root as WineTreeRoot()/WineBootPrefix(): HOME and WINEPREFIX are
   * derived here independently, so they MUST resolve to the identical directory
   * or Wine would boot a different prefix than the app checks and rebuilds. */
  NSString *docs = IOSWinePersistentDocuments();
  set_env("HOME", docs);
  set_env("WINEPREFIX", WineBootPrefix());
  rewrite_stale_container_paths(WineBootPrefix(), docs);
  prune_when_disk_is_low(docs);
  setenv("USER", "wine", 1);
  set_env("WINEDLLPATH", [root stringByAppendingPathComponent:@"lib/wine"]);
  set_env("WINEDATADIR", [NSBundle.mainBundle.bundlePath
                             stringByAppendingPathComponent:@"share/wine"]);
  /* Trust material ships with the signed app, never with an untrusted peer.
   * crypt32 still checks certificate signatures and builds the normal chain.
   * A missing bundle leaves no implicit trust; this is not iOS keychain access. */
  set_env("IOSWINE_CA_BUNDLE", [NSBundle.mainBundle.bundlePath
                                 stringByAppendingPathComponent:@"share/wine/cacert.pem"]);

  setenv("WINEBOOTSTRAPMODE", "1", 1);
  setenv("FEX_SILENTLOG", "0", 1);
  setenv("WINE_IOS_WRITE_FORWARD", "1", 1);
  /* wineios.drv is the display driver; the overrides below disable winemac.drv
   * and winex11.drv so Wine never tries them. */
  setenv("WINE_DISPLAY_DRIVER", "wineios.drv", 1);
  {
    static const char dll_defaults[] = "winemac.drv,winex11.drv=;d3d11,dxgi,d3d10core=b";
    const char *user_overrides = getenv("WINEDLLOVERRIDES");
    if (user_overrides && *user_overrides)
    {
      char merged[1024];
      snprintf(merged, sizeof(merged), "%s;%s", user_overrides, dll_defaults);
      setenv("WINEDLLOVERRIDES", merged, 1);
    }
    else setenv("WINEDLLOVERRIDES", dll_defaults, 1);
  }
  setenv("DISPLAY", "", 1);
  setenv("SDL_RENDER_DRIVER", "software", 0);
  if (!getenv("SDL_AUDIODRIVER")) setenv("SDL_AUDIODRIVER", "directsound", 1);
  NSString *scache = WineShaderCacheRoot();
  [NSFileManager.defaultManager createDirectoryAtPath:scache
                          withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil];
  set_env("DXMT_SHADER_CACHE_PATH", scache);
  /* The diagnostics level's environment and WINEDEBUG, for launches that did
   * not bring them; what a launch request set is kept. */
  {
    IOSWineDiagLevel level = IOSWineDiagLevelFromEnv();
    NSDictionary<NSString *, NSString *> *diag = IOSWineDiagLaunchEnv(level);
    for (NSString *k in diag) setenv(k.UTF8String, diag[k].UTF8String, 0);
    if (!getenv("WINEDEBUG")) setenv("WINEDEBUG", IOSWineDiagPolicyFor(level).winedebug_other, 1);
  }
}

#include "launch_request.h"
static NSString *selectedBottle;
BOOL WineBootSelectBottle(NSString *name) {
  if (name && !IOSWineBottleNameValid(name)) return NO;
  selectedBottle = [name copy];
  return YES;
}
NSString *WineBootPrefix(void) {
  NSString *relative = selectedBottle
      ? [@"Bottles" stringByAppendingPathComponent:selectedBottle] : @"prefix";
  return [IOSWinePersistentDocuments() stringByAppendingPathComponent:relative];
}

static char g_wine_log_path[1024];

const char *WineLogPathC(void) {
  if (!g_wine_log_path[0]) {
    NSString *p = [IOSWinePersistentDocuments()
                      stringByAppendingPathComponent:@"wine-stderr.log"];
    strlcpy(g_wine_log_path, p.fileSystemRepresentation ?: "", sizeof(g_wine_log_path));
  }
  return g_wine_log_path;
}

NSString *WineLogPath(void) {
  return [NSString stringWithUTF8String:WineLogPathC()];
}

static int redirect_wine_output(char *why, size_t whylen) {
  const char *path = WineLogPathC();

  /* Create and prove writability with a raw fd first: if freopen() fails there
   * is no stderr left to report the failure on, and the previous run left an
   * empty log with no explanation. */
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    snprintf(why, whylen, "open(%s): %s", path, strerror(errno));
    return 0;
  }
  const char *hdr = "=== ios-wine: wine log opened ===\n";
  if (write(fd, hdr, strlen(hdr)) < 0) {
    snprintf(why, whylen, "write: %s", strerror(errno));
    close(fd);
    return 0;
  }
  close(fd);

  if (!freopen(path, "a", stderr)) {
    snprintf(why, whylen, "freopen(stderr): %s", strerror(errno));
    return 0;
  }
  freopen(path, "a", stdout);
  setvbuf(stderr, NULL, _IONBF, 0);
  setvbuf(stdout, NULL, _IONBF, 0);
  return 1;
}

typedef struct {
  void (*entry)(int, char **);
  int argc;
  char **argv;
} wine_thread_args;

mach_port_t wine_guest_thread = MACH_PORT_NULL;

/* Wine reports each program's first thread as it starts (Steam's web helper
 * aside): the heartbeat samples that rather than the session host, which
 * only waits for work. */
__attribute__((visibility("default")))
void wine_boot_guest_thread_started(unsigned int port) {
  wine_guest_thread = port;
}

static void *wine_thread_main(void *p) {
  wine_thread_args *a = p;

  wine_guest_thread = mach_thread_self();
  a->entry(a->argc, a->argv);
  return NULL; /* not reached */
}

void WineBootSampleGuest(char *out, size_t outlen) {
  arm_thread_state64_t st;
  mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
  Dl_info di = {0};
  unsigned long long pc, lr, sp, fp;

  if (wine_guest_thread == MACH_PORT_NULL) {
    snprintf(out, outlen, "guest=not-started");
    return;
  }
  if (thread_get_state(wine_guest_thread, ARM_THREAD_STATE64,
                       (thread_state_t)&st, &count) != KERN_SUCCESS) {
    snprintf(out, outlen, "guest=unreadable");
    return;
  }
  pc = (unsigned long long)arm_thread_state64_get_pc(st);
  lr = (unsigned long long)arm_thread_state64_get_lr(st);
  sp = (unsigned long long)arm_thread_state64_get_sp(st);
  fp = (unsigned long long)arm_thread_state64_get_fp(st);

  {
    int resolved = dladdr((void *)(uintptr_t)pc, &di);
    const char *image = resolved ? di.dli_fname : NULL;
    const char *symbol = resolved ? di.dli_sname : NULL;
    const char *fname = image
                        ? (strrchr(image, '/') ? strrchr(image, '/') + 1 : image)
                        : "unsymbolised";
    const char *sname = symbol ? symbol : "?";
    char fdinfo[PATH_MAX + 32] = "";

    if (symbol &&
        (!strcmp(symbol, "read") || !strcmp(symbol, "__read_nocancel") ||
         !strcmp(symbol, "write") || !strcmp(symbol, "recvfrom") ||
         !strcmp(symbol, "sendto") || !strcmp(symbol, "recvmsg"))) {
      int fd = (int)st.__x[0];
      char path[PATH_MAX];

      if (fd >= 0 && fcntl(fd, F_GETPATH, path) == 0)
        snprintf(fdinfo, sizeof(fdinfo), " fd=%d(%s)", fd, path);
      else
        snprintf(fdinfo, sizeof(fdinfo), " fd=%d(socket/pipe)", fd);

      {
        const unsigned int *inflight = dlsym(RTLD_DEFAULT, "ios_server_req_in_flight");
        const unsigned int *calls    = dlsym(RTLD_DEFAULT, "ios_server_call_count");

        if (inflight && calls) {
          size_t used = strlen(fdinfo);
          if (*inflight == ~0u)
            snprintf(fdinfo + used, sizeof(fdinfo) - used,
                     " srv=idle calls=%u", *calls);
          else
            snprintf(fdinfo + used, sizeof(fdinfo) - used,
                     " srv=req%u(unanswered) calls=%u", *inflight, *calls);
        }
      }
    }
    snprintf(out, outlen, "guest pc=%#llx (%s!%s)%s lr=%#llx sp=%#llx fp=%#llx",
             pc, fname, sname, fdinfo, lr, sp, fp);
  }
}

static volatile int g_wine_exited = 0;
static volatile int g_wine_status = 0;

__attribute__((visibility("default")))
void ios_wine_process_exited(int status) {
  void (*flush)(void) = dlsym(RTLD_DEFAULT, "wineserver_inproc_flush");
  if (flush) flush();
  g_wine_status = status;
  __atomic_store_n(&g_wine_exited, 1, __ATOMIC_RELEASE);
}

int WineBootExited(int *status) {
  if (!__atomic_load_n(&g_wine_exited, __ATOMIC_ACQUIRE)) return 0;
  if (status) *status = g_wine_status;
  return 1;
}

static void flush_prefix_at_exit(void) {
  void (*flush)(void) = dlsym(RTLD_DEFAULT, "wineserver_inproc_flush");
  if (flush) flush();
}

int WineBootRun(NSArray<NSString *> *args, WineBootLog log, char *err,
                size_t errlen) {
  NSString *root = WineTreeRoot();
  NSString *ntdll =
      [WineUnixRoot() stringByAppendingPathComponent:@"ntdll.so"];

  if (!WineTreeInstalled()) {
    snprintf(err, errlen, "wine tree not installed at %s",
             root.fileSystemRepresentation);
    return 0;
  }

  configure_environment(root);
  if (log) log([NSString stringWithFormat:@"WINEPREFIX=%s", getenv("WINEPREFIX")]);

  /* RTLD_GLOBAL so ntdll's own dlsym(RTLD_DEFAULT, ...) lookups -- and ours --
   * can see everything it pulls in. */
  void *handle = dlopen(ntdll.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!handle) {
    const char *e = dlerror();
    if (e && strstr(e, "code signature"))
      snprintf(err, errlen,
               "dlopen refused (code signature). JIT is not enabled: tap Enable "
               "JIT, which opens StikDebug with the ios-wine script. Detail: %s", e);
    else
      snprintf(err, errlen, "dlopen(ntdll.so): %s", e ? e : "?");
    return 0;
  }
  if (log) log(@"ntdll.so loaded");
  {
    Dl_info di;
    void *sym = dlsym(handle, "__wine_main");
    if (sym && dladdr(sym, &di) && log)
      log([NSString stringWithFormat:@"IMAGE ntdll.so base=%p", di.dli_fbase]);
  }

  void (*wine_main)(int, char **) = dlsym(handle, "__wine_main");
  if (!wine_main) {
    snprintf(err, errlen, "__wine_main not found in ntdll.so");
    return 0;
  }

  /* Sanity-check the other half of the single-process design before handing
   * control over: if this is missing, start_server() would fatal_error() deep
   * inside Wine with far less context. */
  if (!dlsym(RTLD_DEFAULT, "wineserver_inproc_main")) {
    snprintf(err, errlen,
             "wineserver_inproc_main not visible -- libwineserver.a must be "
             "linked with -Wl,-export_dynamic");
    return 0;
  }
  if (log) log(@"in-process wineserver entry visible");

  int argc = (int)args.count;
  char **argv = calloc((size_t)argc + 1, sizeof(char *));
  for (int i = 0; i < argc; i++) argv[i] = strdup(args[i].UTF8String);
  argv[argc] = NULL;

  if (log) log([NSString stringWithFormat:@"calling __wine_main(%d args)", argc]);

  atexit(flush_prefix_at_exit);

  /* Last thing before handing over: after this, our logging is gone. */
  char why[256] = {0};
  if (!redirect_wine_output(why, sizeof(why))) {
    snprintf(err, errlen, "cannot capture wine output: %s", why);
    return 0;
  }
  if (log) log(@"wine stderr captured to Documents/wine-stderr.log");
  fprintf(stderr, "=== ios-wine app %s %s ===\n", __DATE__, __TIME__);
  for (int i = 0; i < argc; i++)
    fprintf(stderr, "=== argv[%d] %s\n", i, argv[i] ? argv[i] : "(null)");
  fprintf(stderr, "=== entering __wine_main ===\n");

  static wine_thread_args targs;
  targs.entry = wine_main;
  targs.argc = argc;
  targs.argv = argv;

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
  pthread_t tid;
  int perr = pthread_create(&tid, &attr, wine_thread_main, &targs);
  pthread_attr_destroy(&attr);
  if (perr) {
    snprintf(err, errlen, "pthread_create for wine: %s", strerror(perr));
    return 0;
  }

  /* Wine owns that thread now and will not return. Park here so the caller's
   * logging thread stays alive to observe. */
  pthread_join(tid, NULL);

  /* Reached only because exit_process() handed control back rather than
   * calling exit(). Anything else means Wine's entry returned, which it
   * is not supposed to do. */
  if (WineBootExited(NULL)) return 1;
  snprintf(err, errlen, "__wine_main returned unexpectedly");
  return 0;
}


static int safe_read8(uint64_t addr, uint64_t *out) {
  vm_size_t got = 0;
  if (!addr || (addr & 7)) return 0;
  return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, 8,
                           (vm_address_t)(uintptr_t)out, &got) == KERN_SUCCESS && got == 8;
}

static void describe_pc(uint64_t pc, void *alo, size_t asz, char *out, size_t outlen) {
  if (alo && pc >= (uint64_t)(uintptr_t)alo && pc < (uint64_t)(uintptr_t)alo + asz)
    snprintf(out, outlen, "arena+%#llx", (unsigned long long)(pc - (uint64_t)(uintptr_t)alo));
  else
    out[0] = 0;
}

void WineBootDumpThreads(const char *tag, void (*emit)(const char *)) {
  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0, i;
  mach_port_t self = mach_thread_self();
  void *alo = NULL; size_t asz = 0; ptrdiff_t adl = 0;
  char line[600];

  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
    emit("THREADS: task_threads failed");
    return;
  }
  ios_jit_arena_bounds(&alo, &asz, &adl);
  snprintf(line, sizeof line, "THREADS %s: %u host threads (arena %p+%#zx)",
           tag ? tag : "", count, alo, asz);
  emit(line);

  for (i = 0; i < count; i++) {
    thread_t t = threads[i];
    arm_thread_state64_t st;
    mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
    thread_basic_info_data_t bi;
    mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
    int run = -1, susp = -1;
    uint64_t pc, lr, sp, fp, teb, tid = 0, pid = 0, x0;
    char where[160], chain[200];
    size_t n = 0;
    int k;

    if (t == self) { mach_port_deallocate(mach_task_self(), t); continue; }
    if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&bi, &bc) == KERN_SUCCESS) {
      run = bi.run_state;
      susp = bi.suspend_count;
    }
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &sc) != KERN_SUCCESS) {
      snprintf(line, sizeof line, "thr %02u mach=%#x run=%d state unreadable", i, t, run);
      emit(line);
      mach_port_deallocate(mach_task_self(), t);
      continue;
    }
    pc = (uint64_t)arm_thread_state64_get_pc(st);
    lr = (uint64_t)arm_thread_state64_get_lr(st);
    sp = (uint64_t)arm_thread_state64_get_sp(st);
    fp = (uint64_t)arm_thread_state64_get_fp(st);
    x0 = st.__x[0];
    teb = st.__x[28];
    if (teb) {
      uint64_t a = 0, b = 0;
      if (safe_read8(teb + 0x40, &a) && safe_read8(teb + 0x48, &b) &&
          a < 0x100000 && b < 0x100000) { pid = a; tid = b; }
    }
    describe_pc(pc, alo, asz, where, sizeof where);

    chain[0] = 0;
    for (k = 0; k < 8 && fp; k++) {
      uint64_t nf = 0, rl = 0;
      if (!safe_read8(fp, &nf) || !safe_read8(fp + 8, &rl)) break;
      n += (size_t)snprintf(chain + n, sizeof chain > n ? sizeof chain - n : 0,
                            " %llx", (unsigned long long)rl);
      if (nf <= fp) break;
      fp = nf;
    }

    snprintf(line, sizeof line,
             "thr %02u mach=%#x run=%d susp=%d win=%04llx/%04llx pc=%#llx %s lr=%#llx sp=%#llx x0=%#llx ret:%s",
             i, t, run, susp, (unsigned long long)pid, (unsigned long long)tid,
             (unsigned long long)pc, where, (unsigned long long)lr,
             (unsigned long long)sp, (unsigned long long)x0, chain);
    emit(line);

    if (pid && sp) {
      char gl[600];
      size_t gn = (size_t)snprintf(gl, sizeof gl, "  gret %04llx:", (unsigned long long)tid);
      unsigned hits = 0;
      uint64_t buf[512];
      for (uint64_t base = sp & ~7ull; base < (sp & ~7ull) + 48 * 1024 && hits < 24; base += sizeof buf) {
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)base, sizeof buf,
                              (vm_address_t)(uintptr_t)buf, &got) != KERN_SUCCESS || got != sizeof buf) break;
        for (unsigned q = 0; q < 512 && hits < 24; q++) {
          uint64_t v = buf[q];
          uint8_t b[8];
          vm_size_t g2 = 0;
          if (v < 0x100000000ull || v >= 0x8000000000ull) continue;
          if (vm_read_overwrite(mach_task_self(), (vm_address_t)(v - 8), 8,
                                (vm_address_t)(uintptr_t)b, &g2) != KERN_SUCCESS || g2 != 8) continue;
          if (b[3] == 0xE8 || (b[2] == 0xFF && b[3] == 0x15) ||
              (b[6] == 0xFF && (b[7] & 0x38) == 0x10 && (b[7] & 0xC0) == 0xC0) ||
              (b[5] == 0xFF && (b[6] & 0x38) == 0x10 && (b[6] & 0xC0) == 0x40)) {
            gn += (size_t)snprintf(gl + gn, gn < sizeof gl ? sizeof gl - gn : 0, " %llx", (unsigned long long)v);
            hits++;
          }
        }
      }
      if (hits) emit(gl);
    }
    mach_port_deallocate(mach_task_self(), t);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)threads,
                count * sizeof(thread_t));
  mach_port_deallocate(mach_task_self(), self);
}

void WineBootDumpVM(const char *tag, void (*emit)(const char *)) {
  vm_address_t a = 0, run_lo = 0, run_hi = 0, prev_end = 0, first_map = 0;
  vm_prot_t run_prot = 0, run_max = 0;
  uint64_t mapped_lo = 0, mapped_hi = 0, holes_lo = 0, holes_hi = 0;
  uint64_t use_lo = 0, use_hi = 0, big_lo = 0, big_hi = 0;
  unsigned regions = 0, lines = 0;
  char line[256];
  const vm_address_t LOW = 0x1000000000ULL;   /* 64GB */
  const vm_address_t CARVE_LO = 0x0fc0000000ULL;
  const vm_address_t CARVE_HI = 0x7000000000ULL;
  const vm_address_t VA_TOP   = 0x8000000000ULL;

#define USABLE_HOLE(s, e) do { \
    vm_address_t hs = (s), he = (e); \
    if (he > hs) { \
      vm_address_t cs = hs < first_map ? first_map : hs, ce = he < CARVE_LO ? he : CARVE_LO; \
      if (ce > cs) { use_lo += ce - cs; if (ce - cs > big_lo) big_lo = ce - cs; } \
      cs = hs < CARVE_HI ? CARVE_HI : hs; ce = he < VA_TOP ? he : VA_TOP; \
      if (ce > cs) { use_hi += ce - cs; if (ce - cs > big_hi) big_hi = ce - cs; } \
    } } while (0)

#define FLUSH_RUN() do { \
    if (run_hi > run_lo && (run_hi - run_lo) >= (256u << 20) && lines < 80) { \
      vm_address_t ta = run_lo; vm_size_t tsz = 0; natural_t depth = 1; \
      vm_region_submap_info_data_64_t ti; mach_msg_type_number_t tc = VM_REGION_SUBMAP_INFO_COUNT_64; \
      unsigned tag = 0, sub = 0; \
      if (vm_region_recurse_64(mach_task_self(), &ta, &tsz, &depth, (vm_region_recurse_info_t)&ti, &tc) == KERN_SUCCESS) \
        { tag = ti.user_tag; sub = ti.is_submap; } \
      snprintf(line, sizeof line, "VM map %#lx-%#lx %5lu MB %c%c%c/%c%c%c tag=%u%s", \
               (unsigned long)run_lo, (unsigned long)run_hi, \
               (unsigned long)((run_hi - run_lo) >> 20), \
               (run_prot & VM_PROT_READ) ? 'r' : '-', (run_prot & VM_PROT_WRITE) ? 'w' : '-', \
               (run_prot & VM_PROT_EXECUTE) ? 'x' : '-', \
               (run_max & VM_PROT_READ) ? 'r' : '-', (run_max & VM_PROT_WRITE) ? 'w' : '-', \
               (run_max & VM_PROT_EXECUTE) ? 'x' : '-', tag, sub ? " submap" : ""); \
      emit(line); lines++; \
    } } while (0)

  struct { unsigned tag; unsigned count; uint64_t bytes; } hist[64];
  unsigned hist_n = 0, tiny = 0, small = 0, medium = 0, big = 0;

  snprintf(line, sizeof line, "VM %s: begin", tag ? tag : ""); emit(line);
  for (;;) {
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    regions++;
    {
      /* size classes: <=64KB, <=1MB, <=16MB, bigger */
      if (sz <= (64u << 10)) tiny++;
      else if (sz <= (1u << 20)) small++;
      else if (sz <= (16u << 20)) medium++;
      else big++;
      /* per-tag tally (tag needs the recurse call; cheap enough here) */
      {
        vm_address_t ta = a; vm_size_t tsz = 0; natural_t depth = 1;
        vm_region_submap_info_data_64_t ti; mach_msg_type_number_t tc = VM_REGION_SUBMAP_INFO_COUNT_64;
        unsigned utag = 0, k;
        if (vm_region_recurse_64(mach_task_self(), &ta, &tsz, &depth,
                                 (vm_region_recurse_info_t)&ti, &tc) == KERN_SUCCESS)
          utag = ti.user_tag;
        for (k = 0; k < hist_n; k++) if (hist[k].tag == utag) break;
        if (k == hist_n && hist_n < 64) { hist[hist_n].tag = utag; hist[hist_n].count = 0; hist[hist_n].bytes = 0; hist_n++; }
        if (k < 64 && k < hist_n) { hist[k].count++; hist[k].bytes += sz; }
      }
    }
    if (!first_map) { first_map = a; prev_end = a; }   /* never count PAGEZERO as a hole */
    if (a > prev_end) {
      uint64_t hole = a - prev_end;
      if (prev_end < LOW) holes_lo += (a < LOW ? hole : LOW - prev_end);
      if (a > LOW) holes_hi += (prev_end > LOW ? hole : a - LOW);
      USABLE_HOLE( prev_end, a );
      if (hole >= (64u << 20) && lines < 80) {
        snprintf(line, sizeof line, "VM hole %#lx-%#lx %5lu MB", (unsigned long)prev_end,
                 (unsigned long)a, (unsigned long)(hole >> 20));
        emit(line); lines++;
      }
    }
    if (a == run_hi && info.protection == run_prot && info.max_protection == run_max) {
      run_hi = a + sz;
    } else {
      FLUSH_RUN();
      run_lo = a; run_hi = a + sz; run_prot = info.protection; run_max = info.max_protection;
    }
    if (a < LOW) mapped_lo += (a + sz <= LOW) ? sz : LOW - a;
    if (a + sz > LOW) mapped_hi += (a >= LOW) ? sz : a + sz - LOW;
    prev_end = a + sz;
    a += sz;
    if (!a) break;
  }
  FLUSH_RUN();
  USABLE_HOLE( prev_end, VA_TOP );          /* the tail above the last mapping */
#undef FLUSH_RUN
#undef USABLE_HOLE
  snprintf(line, sizeof line,
           "VM %s: %u regions; below 64G mapped %llu MB free %llu MB; above 64G mapped %llu MB free(to last map) %llu MB; last end %#lx",
           tag ? tag : "", regions, (unsigned long long)(mapped_lo >> 20),
           (unsigned long long)(holes_lo >> 20), (unsigned long long)(mapped_hi >> 20),
           (unsigned long long)(holes_hi >> 20), (unsigned long)prev_end);
  emit(line);
  /* The line that actually predicts survival. Everything above is history. */
  snprintf(line, sizeof line,
           "VM %s: USABLE free low %llu MB (largest %llu MB), high %llu MB (largest %llu MB); "
           "pagezero %llu MB excluded, first map %#lx",
           tag ? tag : "", (unsigned long long)(use_lo >> 20), (unsigned long long)(big_lo >> 20),
           (unsigned long long)(use_hi >> 20), (unsigned long long)(big_hi >> 20),
           (unsigned long long)(first_map >> 20), (unsigned long)first_map);
  emit(line);
  /* Size classes and the busiest tags: who is using the task's vm_map
   * entries. */
  snprintf(line, sizeof line, "VM %s: sizes <=64K=%u <=1M=%u <=16M=%u >16M=%u",
           tag ? tag : "", tiny, small, medium, big);
  emit(line);
  {
    unsigned shown, k, best;
    for (shown = 0; shown < 6 && shown < hist_n; shown++) {
      best = 0;
      for (k = 1; k < hist_n; k++) if (hist[k].count > hist[best].count) best = k;
      if (!hist[best].count) break;
      snprintf(line, sizeof line, "VM %s: tag=%u %u regions %llu MB",
               tag ? tag : "", hist[best].tag, hist[best].count,
               (unsigned long long)(hist[best].bytes >> 20));
      emit(line);
      hist[best].count = 0;   /* consume so the next loop finds the runner-up */
    }
  }
}

/* Image bases for offline symbolisation of thread-dump pcs. Only safe while
 * no guest thread can be inside dlopen(); callers pick that moment. */
void WineBootLogImageBases(void (*emit)(const char *)) {
  struct { const char *what; void *sym; } probes[] = {
    { "libsystem_kernel", (void *)&read },
    { "libsystem_pthread", (void *)&pthread_mutex_lock },
    { "libdyld", (void *)&dlopen },
    { "app", (void *)&WineBootDumpVM },
  };
  Dl_info di;
  char line[300];
  for (size_t i = 0; i < sizeof probes / sizeof probes[0]; i++) {
    if (dladdr(probes[i].sym, &di) && di.dli_fname) {
      snprintf(line, sizeof line, "IMAGE %s base=%p (%s)", probes[i].what, di.dli_fbase, di.dli_fname);
      emit(line);
    }
  }
}

void WineBootProbeFixedMap(void (*emit)(const char *)) {
  static const uint64_t probes[] = { 0xfbfff0000ULL, 0x800000000ULL, 0x2000000000ULL, 0x6ff0000000ULL };
  char line[256];
  size_t page = (size_t)getpagesize();
  for (size_t i = 0; i < sizeof probes / sizeof probes[0]; i++) {
    vm_address_t a = (vm_address_t)probes[i];
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    char before[40] = "none";
    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) == KERN_SUCCESS && a <= probes[i]) {
      snprintf(before, sizeof before, "%#lx+%#lx %c%c%c/%c%c%c", (unsigned long)a, (unsigned long)sz,
               (info.protection & 1) ? 'r' : '-', (info.protection & 2) ? 'w' : '-', (info.protection & 4) ? 'x' : '-',
               (info.max_protection & 1) ? 'r' : '-', (info.max_protection & 2) ? 'w' : '-', (info.max_protection & 4) ? 'x' : '-');
    }
    void *got = mmap((void *)probes[i], page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    int werr = errno, wrote = 0;
    if (got != MAP_FAILED) {
      volatile uint32_t *w = (volatile uint32_t *)got;
      *w = 0x5a5a1234u;
      wrote = (*w == 0x5a5a1234u);
      munmap(got, page);
    }
    snprintf(line, sizeof line, "VA-PROBE %#llx: before=[%s] mmap(FIXED,rw)=%s%s%s", (unsigned long long)probes[i], before,
             got == MAP_FAILED ? "FAILED errno=" : (got == (void *)probes[i] ? "OK" : "ELSEWHERE"),
             got == MAP_FAILED ? strerror(werr) : "", wrote ? " write-ok" : "");
    emit(line);
  }
}

/* Snapshot the growing Wine log so the host can pull it while the app runs
 * (devicectl refuses a file that changes size mid-transfer). */
void WineBootSnapshotLog(const char *src, const char *dst) {
  int in = open(src, O_RDONLY), out;
  char buf[65536];
  ssize_t n;
  if (in < 0) return;
  out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (out < 0) { close(in); return; }
  while ((n = read(in, buf, sizeof buf)) > 0) { if (write(out, buf, (size_t)n) != n) break; }
  close(out); close(in);
}

void WineBootPreflightUnixLibs(const char *dir, void (*emit)(const char *)) {
  NSString *d = [NSString stringWithUTF8String:dir];
  NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:d error:nil];
  char line[900];
  for (NSString *n in names) {
    if (![n hasSuffix:@".so"]) continue;
    NSString *path = [d stringByAppendingPathComponent:n];
    bool ok = dlopen_preflight(path.fileSystemRepresentation);
    const char *e = ok ? "" : dlerror();
    snprintf(line, sizeof line, "PREFLIGHT %s: %s%s", n.UTF8String, ok ? "ok" : "FAIL ", e ? e : "");
    emit(line);
  }
}
