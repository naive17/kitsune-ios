/*
 * The x86 -> ARM64EC exception boundary, end to end.
 *
 * Copyright 2026 the Kitsune project
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * seh64.exe proves an exception raised in translated code is delivered back to
 * translated code. It cannot prove anything about the BOUNDARY, for a
 * structural reason: it uses a vectored handler, and vectored handlers are
 * process-wide and run before any frame-based search happens. The unwind never
 * has to cross anything for one to fire.
 *
 * Showing the crossing needs a frame-based handler on an x86 frame, with the
 * fault raised in ARM64EC code that the x86 frame called. Then reaching the
 * handler is only possible if the unwind walked out of EC code, found the x86
 * frame's AMD64 unwind data, and kept going.
 *
 * That cannot be written in C here: __try is not available for
 * x86_64-windows-gnu with this clang --
 *
 *   error: use of undeclared identifier '__try'
 *
 * -- so the guarded frame is hand-written, with .seh_proc/.seh_handler
 * emitting the .pdata and .xdata that the unwinder is being tested on.
 *
 * The faulting call is RtlMoveMemory (kernel32's memmove) reading from address
 * 1. It is reached through the normal import path, so the callee is ARM64EC
 * code, and memmove has no SEH of its own -- the fault propagates out of it
 * rather than being swallowed.
 *
 * The handler prints and exits rather than resuming: returning
 * ExceptionContinueExecution would need surgery on an AMD64 context that FEX
 * owns, and this test is about whether the handler is REACHED. Reaching it is
 * the whole claim.
 */

#include <windows.h>

static void print( const char *s )
{
    DWORD written;
    HANDLE out = GetStdHandle( STD_OUTPUT_HANDLE );
    const char *p = s;
    DWORD len = 0;

    while (p[len]) len++;
    WriteFile( out, s, len, &written, NULL );
}

static void print_hex( unsigned long long v )
{
    static const char digits[] = "0123456789abcdef";
    char buf[17];
    int i;

    for (i = 15; i >= 0; i--) { buf[i] = digits[v & 0xf]; v >>= 4; }
    buf[16] = 0;
    print( buf );
}

/* Referenced from the asm below; must have external linkage. */
char seh_cross_buf[64];
void *seh_cross_target;

EXCEPTION_DISPOSITION seh_cross_handler( EXCEPTION_RECORD *rec, void *frame,
                                         CONTEXT *ctx, void *dispatch );
EXCEPTION_DISPOSITION seh_cross_handler( EXCEPTION_RECORD *rec, void *frame,
                                         CONTEXT *ctx, void *dispatch )
{
    (void)frame; (void)ctx; (void)dispatch;

    /* Unwinding is what was being tested, and it worked. Say so precisely:
     * the code proves it was the access violation and not something else. */
    print( "seh-cross: OK handler reached, code=" );
    print_hex( rec->ExceptionCode );
    print( " addr=" );
    print_hex( (unsigned long long)(ULONG_PTR)rec->ExceptionAddress );
    print( "\n" );
    ExitProcess( 0 );
    return ExceptionContinueSearch;
}

/*
 * The guarded frame. .seh_handler is what puts seh_cross_handler into this
 * function's .xdata; without the surrounding .seh_proc/.seh_endprologue there
 * is no .pdata entry for the frame and the unwinder has nothing to find.
 */
void guarded_call(void);
__asm__( ".text\n\t"
         ".globl guarded_call\n"
         "guarded_call:\n\t"
         ".seh_proc guarded_call\n\t"
         "pushq %rbp\n\t"
         ".seh_pushreg %rbp\n\t"
         "movq %rsp, %rbp\n\t"
         ".seh_setframe %rbp, 0\n\t"
         "subq $48, %rsp\n\t"
         ".seh_stackalloc 48\n\t"
         ".seh_handler seh_cross_handler, @except\n\t"
         ".seh_endprologue\n\t"
         /* RtlMoveMemory( seh_cross_buf, (void *)1, 16 ) -- faults in EC code */
         "leaq seh_cross_buf(%rip), %rcx\n\t"
         "movq $1, %rdx\n\t"
         "movq $16, %r8\n\t"
         "callq *seh_cross_target(%rip)\n\t"
         /*
          * These nops are load-bearing. Without them the return address lands
          * on the first byte of the epilogue, and AMD64 SEH says a pc in the
          * epilogue has NO handler -- the frame is already being torn down.
          * RtlVirtualUnwind2 duly returns handler_ret = NULL
          * (is_inside_epilog, unwind.c), the handler is never called, and the
          * test looks like a Wine bug when it is a malformed guest.
          */
         "nop\n\t"
         "nop\n\t"
         "nop\n\t"
         "nop\n\t"
         "addq $48, %rsp\n\t"
         "popq %rbp\n\t"
         "retq\n\t"
         ".seh_endproc\n" );

void mainCRTStartup(void)
{
    HMODULE k32;

    print( "seh-cross: start\n" );

    k32 = GetModuleHandleA( "kernel32.dll" );
    if (!k32) { print( "seh-cross: FAIL - no kernel32\n" ); ExitProcess( 1 ); }

    seh_cross_target = (void *)GetProcAddress( k32, "RtlMoveMemory" );
    if (!seh_cross_target)
    {
        print( "seh-cross: FAIL - no RtlMoveMemory\n" );
        ExitProcess( 1 );
    }

    guarded_call();

    /* Only reached if the fault never happened, which would mean the test is
     * measuring nothing -- report that rather than passing silently. */
    print( "seh-cross: FAIL - no exception raised\n" );
    ExitProcess( 1 );
}
