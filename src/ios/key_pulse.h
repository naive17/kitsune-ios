/* Nonblocking key pulses for frame-polled games. All calls on UIKit's queue. */
#ifndef KITSUNE_KEY_PULSE_H
#define KITSUNE_KEY_PULSE_H
#include <stdint.h>
#include <string.h>

/* mods: 1 Ctrl, 2 Alt, 4 Shift; 8 means vk is a character, sent as Unicode. */
struct ios_key_pulse { uint16_t vk, mods; };
struct ios_key_pulses {
    struct ios_key_pulse items[64];
    unsigned head, tail, phase;
    uint64_t deadline;
};
typedef void (*ios_key_sink)(int vk, int scan, int down);
typedef void (*ios_text_sink)(int codepoint, int down);

/* A character typed in game mode. Letters, digits and space become their keys,
 * capitals with Shift, so a frame-polled game sees them held; anything else
 * stays a character. Both go through one queue, so text keeps its order. */
static inline struct ios_key_pulse KitsuneGameTextPulse(uint16_t c) {
    if (c >= 'a' && c <= 'z') return (struct ios_key_pulse){ (uint16_t)(c - 'a' + 'A'), 0 };
    if (c >= 'A' && c <= 'Z') return (struct ios_key_pulse){ c, 4 };
    if ((c >= '0' && c <= '9') || c == ' ') return (struct ios_key_pulse){ c, 0 };
    return (struct ios_key_pulse){ c, 8 };
}

static inline void KitsunePulseEmit(struct ios_key_pulse p, int down, ios_key_sink sink, ios_text_sink text) {
    if (p.mods & 8) {
        if (text) text(p.vk, down);
        return;
    }
    if (!sink) return;
    if (down) {
        if (p.mods & 1) sink(0x11, 0, 1);
        if (p.mods & 2) sink(0x12, 0, 1);
        if (p.mods & 4) sink(0x10, 0, 1);
        sink(p.vk, 0, 1);
    } else {
        sink(p.vk, 0, 0);
        if (p.mods & 4) sink(0x10, 0, 0);
        if (p.mods & 2) sink(0x12, 0, 0);
        if (p.mods & 1) sink(0x11, 0, 0);
    }
}

static inline int KitsunePulsePush(struct ios_key_pulses *q, int vk, int mods) {
    unsigned next = (q->head + 1) % 64;
    if (next == q->tail) return 0;
    q->items[q->head] = (struct ios_key_pulse){ (uint16_t)vk, (uint16_t)mods };
    q->head = next;
    return 1;
}

static inline void KitsunePulseTick(struct ios_key_pulses *q, uint64_t now, ios_key_sink sink, ios_text_sink text) {
    if (q->phase && now < q->deadline) return;
    if (q->phase == 1) {
        KitsunePulseEmit(q->items[q->tail], 0, sink, text);
        q->tail = (q->tail + 1) % 64;
        q->phase = 2;
        q->deadline = now + 50; // A game must observe release before a repeated E.
        return;
    }
    q->phase = 0;
    if (q->tail != q->head) {
        KitsunePulseEmit(q->items[q->tail], 1, sink, text);
        q->phase = 1;
        q->deadline = now + 80;
    }
}

static inline void KitsunePulseCancel(struct ios_key_pulses *q, ios_key_sink sink, ios_text_sink text) {
    if (q->phase == 1) KitsunePulseEmit(q->items[q->tail], 0, sink, text);
    memset(q, 0, sizeof(*q));
}
#endif
