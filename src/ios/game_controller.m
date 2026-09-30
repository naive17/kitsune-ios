#import "game_controller.h"
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <stdlib.h>
#include "gamepad_state.h"

static pthread_mutex_t g_pad_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ios_gamepad_info g_pads = { .version = KITSUNE_GAMEPAD_VERSION };

__attribute__((visibility("default")))
void kitsune_gamepad_snapshot_v1(struct ios_gamepad_info *info) {
    pthread_mutex_lock(&g_pad_lock);
    *info = g_pads;
    pthread_mutex_unlock(&g_pad_lock);
}

@interface KitsuneGamepadBridge : NSObject
@end

@implementation KitsuneGamepadBridge {
    dispatch_queue_t _queue;
    GCController *_controllers[KITSUNE_GAMEPAD_COUNT];
    BOOL _active;
    unsigned _traceCount;
    struct ios_touch_pad _touch;
}

+ (instancetype)shared {
    static KitsuneGamepadBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [KitsuneGamepadBridge new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("dev.kitsune.gamepad", DISPATCH_QUEUE_SERIAL);
        _active = YES;
    }
    return self;
}

- (void)publish:(NSUInteger)slot {
    GCController *c = _controllers[slot];
    GCExtendedGamepad *pad = c.extendedGamepad;
    struct ios_gamepad_state next = {0};
    next.connected = c != nil;
    if (c) {
        // XInput BATTERY_TYPE_WIRED / UNKNOWN. Never invent a battery level.
        next.battery_type = c.isAttachedToDevice ? 1 : 255;
        if (@available(iOS 14.0, *)) {
            GCDeviceBattery *battery = c.battery;
            if (!c.isAttachedToDevice && battery && battery.batteryState != GCDeviceBatteryStateUnknown) {
                next.battery_type = 255; // Apple does not expose battery chemistry.
                float level = battery.batteryLevel;
                next.battery_level = level <= 0 ? 0 : level < 0.3f ? 1 : level < 0.7f ? 2 : 3;
            }
        }
    }
    if (pad && _active) {
        next.buttons = (pad.dpad.up.isPressed ? 0x0001 : 0) |
            (pad.dpad.down.isPressed ? 0x0002 : 0) |
            (pad.dpad.left.isPressed ? 0x0004 : 0) |
            (pad.dpad.right.isPressed ? 0x0008 : 0) |
            (pad.buttonMenu.isPressed ? 0x0010 : 0) |
            (pad.buttonOptions.isPressed ? 0x0020 : 0) |
            (pad.leftThumbstickButton.isPressed ? 0x0040 : 0) |
            (pad.rightThumbstickButton.isPressed ? 0x0080 : 0) |
            (pad.leftShoulder.isPressed ? 0x0100 : 0) |
            (pad.rightShoulder.isPressed ? 0x0200 : 0) |
            (pad.buttonA.isPressed ? 0x1000 : 0) |
            (pad.buttonB.isPressed ? 0x2000 : 0) |
            (pad.buttonX.isPressed ? 0x4000 : 0) |
            (pad.buttonY.isPressed ? 0x8000 : 0);
        if (@available(iOS 14.0, *)) if (pad.buttonHome.isPressed) next.buttons |= 0x0400;
        next.lx = KitsuneGamepadAxis(pad.leftThumbstick.xAxis.value);
        next.ly = KitsuneGamepadAxis(pad.leftThumbstick.yAxis.value);
        next.rx = KitsuneGamepadAxis(pad.rightThumbstick.xAxis.value);
        next.ry = KitsuneGamepadAxis(pad.rightThumbstick.yAxis.value);
        next.left_trigger = KitsuneGamepadTrigger(pad.leftTrigger.value);
        next.right_trigger = KitsuneGamepadTrigger(pad.rightTrigger.value);
    }
    if (slot == 0 && _active) KitsuneGamepadMergeTouch(&next, &_touch);
    pthread_mutex_lock(&g_pad_lock);
    uint32_t previousPacket = g_pads.pads[slot].packet;
    KitsuneGamepadPublish(&g_pads.pads[slot], next);
    next = g_pads.pads[slot];
    pthread_mutex_unlock(&g_pad_lock);

    // Opt-in and bounded: capture real button releases as well as presses
    // without filling logs on every analog callback or holding the pad lock.
    const char *trace = getenv("KITSUNE_XINPUT_TRACE");
    if (next.packet != previousPacket && trace && atoi(trace) && _traceCount < 128) {
        ++_traceCount;
        NSLog(@"[gc-xinput] state slot=%lu active=%d connected=%u packet=%u buttons=%04x lt=%u rt=%u l=%d,%d r=%d,%d trace=%u/128",
              (unsigned long)slot, _active, next.connected, next.packet, next.buttons,
              next.left_trigger, next.right_trigger, next.lx, next.ly, next.rx, next.ry, _traceCount);
    }
}

- (void)refresh {
    dispatch_async(_queue, ^{
        NSArray<GCController *> *controllers = GCController.controllers;
        for (NSUInteger i = 0; i < KITSUNE_GAMEPAD_COUNT; ++i) {
            GCController *old = self->_controllers[i];
            if (old && ![controllers containsObject:old]) {
                old.extendedGamepad.valueChangedHandler = nil;
                self->_controllers[i] = nil;
                [self publish:i];
                NSLog(@"[gc-xinput] disconnected slot=%lu", (unsigned long)i);
            }
        }
        for (GCController *c in controllers) {
            if (!c.extendedGamepad) continue;
            NSUInteger slot = KITSUNE_GAMEPAD_COUNT;
            BOOL known = NO;
            for (NSUInteger i = 0; i < KITSUNE_GAMEPAD_COUNT; ++i) {
                if (self->_controllers[i] == c) known = YES;
                if (!self->_controllers[i] && slot == KITSUNE_GAMEPAD_COUNT) slot = i;
            }
            if (known || slot == KITSUNE_GAMEPAD_COUNT) continue;
            self->_controllers[slot] = c;
            c.handlerQueue = self->_queue;
            c.playerIndex = (GCControllerPlayerIndex)slot;
            c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
                (void)element;
                if (self->_controllers[slot].extendedGamepad == pad) [self publish:slot];
            };
            [self publish:slot];
            NSLog(@"[gc-xinput] attached slot=%lu controller=%@", (unsigned long)slot, c.vendorName ?: @"unknown");
        }
    });
}

- (void)setTouch:(struct ios_touch_pad)touch {
    dispatch_async(_queue, ^{
        self->_touch = touch;
        [self publish:0];
    });
}

- (void)setActive:(BOOL)active {
    dispatch_async(_queue, ^{
        self->_active = active;
        for (NSUInteger i = 0; i < KITSUNE_GAMEPAD_COUNT; ++i) [self publish:i];
    });
}

@end

void GameController_SetTouchPad(const struct ios_touch_pad *state) {
    [[KitsuneGamepadBridge shared] setTouch:*state];
}

void GameController_Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
        KitsuneGamepadBridge *b = [KitsuneGamepadBridge shared];
        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            (void)n;
            [b refresh];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            (void)n;
            [b refresh];
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [b setActive:NO]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [b setActive:YES]; }];
        /* GCController requires the app to opt into receiving events; on iOS 14+
         * this also enables the on-screen virtual controller opt-out. */
        [b refresh];
        [b setActive:UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
        NSLog(@"[gc-xinput] started native four-slot bridge");
    });
    });
}
