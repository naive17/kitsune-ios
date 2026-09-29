/* Minimal x86-64 Windows console program.
 *
 * If this prints its product, an x86-64 instruction stream was translated by
 * FEX and executed on ARM64 under this Wine.  Deliberately avoids the CRT
 * (-nostdlib, custom entry) so that the first x86 instruction executed is one
 * we can point at, and so a failure cannot be blamed on mingw's startup
 * code. */
#include <windows.h>

void __stdcall mainCRTStartup(void) {
  static const char msg[] = "hello64: x86-64 code executed under FEX\r\n";
  DWORD written = 0;
  HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
  WriteFile(h, msg, sizeof(msg) - 1, &written, NULL);
  /* Prove real computation happened, not just a call-through. */
  volatile unsigned long long a = 0x0123456789abcdefULL, b = 0xfedcba9876543210ULL;
  unsigned long long s = a * b + (a ^ b);
  char buf[32];
  const char *hex = "0123456789abcdef";
  for (int i = 0; i < 16; i++) buf[i] = hex[(s >> ((15 - i) * 4)) & 0xf];
  buf[16] = '\r'; buf[17] = '\n';
  WriteFile(h, buf, 18, &written, NULL);
  ExitProcess(0);
}
