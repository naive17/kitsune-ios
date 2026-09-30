#ifndef KITSUNE_JIT_ARENA_H
#define KITSUNE_JIT_ARENA_H
#include <stddef.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Occupy an address so the debugger's allocator will not place the arena on
 * it. Call BEFORE ios_jit_arena_init, release after. See jit_arena.c. */
int  ios_jit_arena_reserve(void *addr, size_t len, char *err, size_t errlen);
void ios_jit_arena_release_reserved(void);
/* 1 when the arena is ready, 0 when it cannot be set up in this process, and
 * -1 when no debugger with the JIT script answered; the pin is then kept, so a
 * later attach with the script can succeed. Must run before jit_detach():
 * nothing can be blessed afterwards. */
int  ios_jit_arena_init(size_t size, char *err, size_t errlen);
/* Called between the steps in which the debugger prepares the arena, with the
 * fraction done. */
void ios_jit_arena_set_progress(void (*progress)(double done, void *ctx), void *ctx);
int  ios_jit_arena_pin_low(void *addr, size_t len);
/* One line describing the pin outcome and where the arena then landed. */
const char *ios_jit_arena_pin_note(void);
int  ios_jit_arena_available(void);
size_t ios_jit_arena_size(void);
/* Returns 1 and sets both addresses; 0 if exhausted or not initialised. */
int  ios_jit_arena_alloc(size_t size, size_t align, void **exec, void **write);
void ios_jit_arena_publish(void *exec_addr, size_t len);
/* Bounds of the arena, for callers that must recognise their own pages. */
void ios_jit_arena_bounds(void **exec_lo, size_t *size, ptrdiff_t *delta);
/* [base, base+size) of the arena reserved for fixed-base (relocs-stripped) exes. */
void ios_jit_arena_exe_window(void **base, size_t *size);
int ios_jit_arena_pin_low_adaptive(void *addr, size_t min_len, size_t max_len);
size_t ios_jit_arena_pinned_len(void);
void ios_jit_arena_free_jit(void *exec, size_t size);
#ifdef __cplusplus
}
#endif
#endif
