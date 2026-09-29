#import "boot_status.h"

NSNotificationName const WineBootStatusDidChangeNotification = @"WineBootStatusDidChange";

@implementation WineBootStatus

+ (instancetype)shared {
  static WineBootStatus *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [WineBootStatus new];
    s->_message = NSLocalizedString(@"Preparing the runtime", nil);
    s->_progress = -1;
  });
  return s;
}

- (void)setPhase:(WineBootPhase)phase message:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_phase = phase;
    self->_message = [message copy];
    self->_progress = -1;
    [NSNotificationCenter.defaultCenter postNotificationName:WineBootStatusDidChangeNotification object:self];
  });
}

- (void)setProgress:(double)fraction {
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_progress = fraction;
    [NSNotificationCenter.defaultCenter postNotificationName:WineBootStatusDidChangeNotification object:self];
  });
}

@end
