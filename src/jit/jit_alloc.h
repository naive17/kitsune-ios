#ifndef IOS_WINE_JIT_ALLOC_H
#define IOS_WINE_JIT_ALLOC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  void *exec;      /* RX  -- execute/branch target                     */
  void *write;     /* RW  -- emit code through this pointer            */
  ptrdiff_t delta; /* write - exec; add to convert exec addr -> write  */
  size_t size;
} jit_region;

int jit_alloc_available(char *err, size_t errlen);

int jit_region_alloc(size_t size, jit_region *out, char *err, size_t errlen);

/* jit_region_alloc, with the debugger preparing the region `step` bytes at a
 * time; the process runs between steps and `progress` gets the fraction done.
 * A script without the allocate-only command prepares it in one request. */
int jit_region_alloc_stepwise(size_t size, size_t step, void (*progress)(double done, void *ctx), void *ctx,
                              jit_region *out, char *err, size_t errlen);

void jit_region_free(jit_region *r);

int jit_detach(char *err, size_t errlen);

void jit_region_publish(const jit_region *r, void *exec_addr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* IOS_WINE_JIT_ALLOC_H */
