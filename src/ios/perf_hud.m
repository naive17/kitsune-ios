#import "perf_hud.h"
#import "diagnostics.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <os/proc.h>

#define SAMPLES 16

static uint64_t (*present_count)(void);
static uint64_t (*gpu_busy_ns)(void);
static void (*gpu_timing_enable)(int);

/* winemetal.so is loaded by Wine from the bundle; RTLD_NOLOAD finds it
 * without loading it ourselves when no game has started Metal yet. */
static BOOL resolve_winemetal(void) {
  if (present_count) return YES;
  NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"lib/wine/aarch64-unix/winemetal.so"];
  void *h = dlopen(path.fileSystemRepresentation, RTLD_NOLOAD | RTLD_LAZY);
  if (!h) return NO;
  present_count = dlsym(h, "kitsune_get_present_count");
  gpu_busy_ns = dlsym(h, "kitsune_gpu_busy_ns");
  gpu_timing_enable = dlsym(h, "kitsune_gpu_timing_enable");
  return present_count != NULL;
}

static unsigned long long footprint_mb(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
  return (unsigned long long)(info.phys_footprint >> 20);
}

@implementation WinePerfHUD {
  UILabel *_label;
  NSTimer *_timer;
  double _times[SAMPLES];
  uint64_t _counts[SAMPLES];
  uint64_t _busy[SAMPLES];
  unsigned _head, _filled;
  BOOL _timing;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.layer.cornerRadius = 8;
    self.layer.zPosition = 2001;
    _label = [UILabel new];
    _label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _label.textColor = UIColor.whiteColor;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
      [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
      [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
      [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
      [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
    ]];
    self.hidden = YES;
  }
  return self;
}

- (void)setVisible:(BOOL)visible {
  self.hidden = !visible;
  [_timer invalidate];
  _timer = nil;
  _filled = 0;
  [self setTiming:visible];
  if (!visible) return;
  [self sample];
  _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(sample) userInfo:nil repeats:YES];
}

- (void)willMoveToWindow:(UIWindow *)window {
  if (!window) { [_timer invalidate]; _timer = nil; [self setTiming:NO]; }
}

/* GPU timing adds a completion handler per command buffer; only while shown. */
- (void)setTiming:(BOOL)on {
  if (on == _timing) return;
  if (on && !resolve_winemetal()) return;
  if (gpu_timing_enable) gpu_timing_enable(on);
  _timing = on && gpu_timing_enable != NULL;
}

/* FPS over the oldest sample that is at least a second old, so the reading
 * does not jump between multiples of the sampling rate. */
- (void)sample {
  double now = CACurrentMediaTime();
  NSString *fps = @"–", *gpu = @"";
  if (!self.hidden && !_timing) [self setTiming:YES];
  if (resolve_winemetal()) {
    uint64_t n = present_count(), busy = gpu_busy_ns ? gpu_busy_ns() : 0;
    _times[_head] = now;
    _counts[_head] = n;
    _busy[_head] = busy;
    _head = (_head + 1) % SAMPLES;
    if (_filled < SAMPLES) _filled++;
    for (unsigned i = _filled; i > 1; i--) {
      unsigned idx = (_head + SAMPLES - i) % SAMPLES;
      double dt = now - _times[idx];
      if (dt < 1.0) continue;
      fps = [NSString stringWithFormat:@"%.0f", (double)(n - _counts[idx]) / dt];
      if (_timing) gpu = [NSString stringWithFormat:NSLocalizedString(@" · GPU %.0f%%", nil), MIN(100.0, (double)(busy - _busy[idx]) / (dt * 1e7))];
      break;
    }
  }
  unsigned long long used = footprint_mb(), avail = os_proc_available_memory() >> 20;
  NSString *line = [NSString stringWithFormat:NSLocalizedString(@"%@ fps%@ · %.2f GB · %llu MB free", nil), fps, gpu, used / 1024.0, avail];
  UIColor *color = avail < 256 ? UIColor.systemRedColor : avail < 512 ? UIColor.systemYellowColor : UIColor.whiteColor;
  /* Logging costs frames (Full dumps every thread and walks the memory map every
   * 5 s), so a run with it on says so; the level is the one this launch runs with. */
  KitsuneDiagLevel level = KitsuneDiagLevelFromEnv();
  NSString *note = level == KitsuneDiagFull ? NSLocalizedString(@"Logging Full · slower · ", nil)
                 : level == KitsuneDiagBasic ? NSLocalizedString(@"Logging Basic · ", nil) : nil;
  if (!note) {
    _label.attributedText = nil;
    _label.text = line;
    _label.textColor = color;
    return;
  }
  NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:note
      attributes:@{ NSForegroundColorAttributeName: UIColor.systemOrangeColor, NSFontAttributeName: _label.font }];
  [text appendAttributedString:[[NSAttributedString alloc] initWithString:line
      attributes:@{ NSForegroundColorAttributeName: color, NSFontAttributeName: _label.font }]];
  _label.attributedText = text;
}

@end
