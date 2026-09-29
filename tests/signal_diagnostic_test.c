#include <assert.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "wine-diagnostic-read.inc"
int main(void)
{
    const size_t page = getpagesize();
    char *mapping = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    uint64_t value = 0x1234567890abcdef, readback = 0;
    assert(mapping != MAP_FAILED);
    memcpy(mapping, &value, sizeof(value));
    assert(ios_diagnostic_read(mapping, &readback, sizeof(readback)) && readback == value);
    assert(!ios_diagnostic_read(NULL, &readback, sizeof(readback)));
    assert(!ios_diagnostic_read((void *)1, &readback, sizeof(readback)));
    assert(!ios_diagnostic_read((void *)UINTPTR_MAX, &readback, sizeof(readback)));
    assert(!mprotect(mapping + page, page, PROT_NONE));
    assert(!ios_diagnostic_read(mapping + page, &readback, sizeof(readback)));
    assert(!ios_diagnostic_read(mapping + page - 4, &readback, sizeof(readback)));
    assert(!munmap(mapping, page * 2));
    assert(!ios_diagnostic_read(mapping, &readback, sizeof(readback)));
    puts("PASS: diagnostic reader rejects NULL, bad registers, PROT_NONE, cross-page and unmapped reads without faulting");
    return 0;
}
