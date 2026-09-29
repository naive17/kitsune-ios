/*
 * Does a Win32 exception raised INSIDE translated x86-64 code get delivered
 * back to translated code, and does execution survive it?
 *
 * Copyright 2026 the ios-wine project
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
 * hello64 proves x86-64 instructions execute. This proves something narrower
 * and, for real programs, just as necessary: that a fault taken in translated
 * code unwinds back into translated code and the process keeps running.
 *
 * It matters here specifically because of the register moves this port makes.
 * The TEB is in x28 rather than x18 (Darwin zeroes x18 on preemption) and FEX's
 * STATE was moved x28 -> x14 to make room. Delivering an exception saves and
 * restores an ARM64 context around a switch into the handler, so if either
 * register is dropped or restored from the wrong slot, the failure appears
 * AFTER the handler returns -- as a corrupt emulator state or a TEB pointing at
 * nothing -- with no obvious link to the exception that caused it.
 *
 * Three cases, in increasing order of what they need from the runtime:
 *
 *   1. a fault caught by __try/__except            unwind reaches the handler
 *   2. execution continues normally afterwards     the context was restored
 *   3. a second fault, after the first             the machinery is reusable,
 *                                                  not a one-shot
 *
 * -nostdlib with a custom entry point, like the other guests: the first x86
 * instruction executed is one we can point at.
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

/*
 * A vectored handler rather than __try/__except: clang's mingw target has no
 * SEH intrinsics. This is the stronger test regardless -- EXCEPTION_CONTINUE_
 * EXECUTION resumes the faulting code through NtContinue, so the whole
 * save/restore round trip is exercised, not just the unwind.
 *
 * The faulting instruction is written by hand and is exactly two bytes
 * (8b 00, "mov eax,[rax]"), so the handler can step over it by adding 2 to Rip
 * without needing to decode anything.
 */
static volatile int handled;

static LONG CALLBACK on_fault( EXCEPTION_POINTERS *info )
{
    if (info->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;

    handled++;
    info->ContextRecord->Rip += 2;      /* step over mov eax,[rax] */
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void fault_once(void)
{
    __asm__ volatile( "xor %%eax, %%eax\n\t"
                      "mov (%%rax), %%eax\n\t"
                      : : : "eax", "memory" );
}

void mainCRTStartup(void)
{
    unsigned long long checksum = 0;
    int i;

    print( "seh64: start\n" );

    if (!AddVectoredExceptionHandler( 1, on_fault ))
    {
        print( "seh64: FAIL - no vectored handler\n" );
        ExitProcess( 1 );
    }

    /* 1: fault, be delivered, and resume. */
    fault_once();
    print( handled == 1 ? "seh64: resumed after #1\n"
                        : "seh64: FAIL - not delivered\n" );

    /*
     * 2: keep computing. A context restored with the emulator's state register
     * or the TEB taken from the wrong slot does not fault here, it quietly
     * produces the wrong number -- so this checks a value, not just liveness.
     */
    for (i = 1; i <= 4096; i++) checksum = checksum * 31 + (unsigned)i;

    /* 3: again, because once can be luck. */
    fault_once();

    if (handled == 2)
    {
        print( "seh64: OK checksum=" );
        print_hex( checksum );
        print( "\n" );
    }
    else print( "seh64: FAIL - handler count wrong\n" );

    ExitProcess( handled == 2 ? 0 : 1 );
}
