/*
 * QueryPerformanceCounter read in user mode (patches/wine 0022).
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
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The counter must never go backwards on any of four threads reading it at
 * once, and must stay within 1 ms of the system call it replaces, across the
 * once-a-second check of its offset. No CRT, like x64-hello.c.
 */
#include <windows.h>

typedef LONG (WINAPI *nt_qpc_fn)(LARGE_INTEGER *, LARGE_INTEGER *);

static volatile LONG backwards;

static DWORD WINAPI reader(void *arg) {
  LARGE_INTEGER prev, now;
  (void)arg;
  QueryPerformanceCounter(&prev);
  for (int i = 0; i < 200000; i++) {
    QueryPerformanceCounter(&now);
    if (now.QuadPart < prev.QuadPart) InterlockedIncrement(&backwards);
    prev = now;
  }
  return 0;
}

static void say(const char *s) {
  DWORD written = 0, n = 0;
  while (s[n]) n++;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, NULL);
}

void __stdcall mainCRTStartup(void) {
  nt_qpc_fn nt_qpc = (nt_qpc_fn)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryPerformanceCounter");
  HANDLE threads[4];
  LARGE_INTEGER user, sys;
  LONGLONG worst = 0;

  if (!nt_qpc) { say("QPC FAIL no NtQueryPerformanceCounter\r\n"); ExitProcess(1); }
  for (int i = 0; i < 4; i++) threads[i] = CreateThread(NULL, 0, reader, NULL, 0, NULL);
  WaitForMultipleObjects(4, threads, TRUE, INFINITE);

  /* 2.4 s of samples, so the offset is checked again at least twice. */
  for (int i = 0; i < 1200; i++) {
    LONGLONG d;
    QueryPerformanceCounter(&user);
    nt_qpc(&sys, NULL);
    d = sys.QuadPart - user.QuadPart;
    if (d < 0) d = -d;
    if (d > worst) worst = d;
    if (i % 100 == 0) Sleep(200);
  }

  if (backwards) say("QPC FAIL the counter went backwards\r\n");
  else if (worst >= 10000) say("QPC FAIL more than 1 ms from the system call\r\n");
  else say("QPC PASS\r\n");
  ExitProcess(0);
}
