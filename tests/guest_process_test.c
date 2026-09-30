/* A child process boots, shares the parent's wineserver namespace and loads
 * system modules the way programs name them. */
#include <windows.h>
static void emit(const char *s) {
    DWORD length = 0, count;
    while (s[length]) ++length;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), s, length, &count, NULL);
}
static void emit_error(const char *message) {
    DWORD error = GetLastError();
    char digits[9];
    static const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < 8; ++i) digits[i] = hex[(error >> (28 - 4 * i)) & 15];
    digits[8] = 0;
    emit(message); emit(" error=0x"); emit(digits); emit("\n");
}
void mainCRTStartup(void) {
#if PROCESS_GATE_CHILD
    HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, L"Local\\kitsune-process-gate");
    emit("PROCESS-GATE CHILD: reached PE entry\n");
    if (!event || !SetEvent(event)) { emit_error("PROCESS-GATE CHILD: shared event failed"); ExitProcess(10); }
    CloseHandle(event);
    emit("PROCESS-GATE CHILD: shared event signaled\n");
    /* Neither names a file in the prefix: the prefix has no placeholder DLLs. */
    if (!LoadLibraryW(L"api-ms-win-power-base-l1-1-0.dll")) {
        emit_error("PROCESS-GATE CHILD: API set load failed"); ExitProcess(11);
    }
    if (!LoadLibraryW(L"C:\\windows\\system32\\dwmapi.dll")) {
        emit_error("PROCESS-GATE CHILD: system directory load failed"); ExitProcess(12);
    }
    emit("PROCESS-GATE CHILD: system modules loaded; exiting 42\n");
    ExitProcess(42);
#else
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;
    DWORD status;
    static WCHAR child[1024], directory[1024];
    DWORD length = GetModuleFileNameW(NULL, child, 1024);
    if (!length || length >= 1024) ExitProcess(5);
    DWORD basename = length;
    while (basename && child[basename - 1] != '\\' && child[basename - 1] != '/') --basename;
    if (!basename || basename + 32 >= 1024) ExitProcess(6);
    child[basename] = 0;
    lstrcpyW(directory, child);
#ifndef PROCESS_GATE_CHILD_NAME
#define PROCESS_GATE_CHILD_NAME L"process-child-arm64.exe"
#endif
    lstrcpyW(child + basename, PROCESS_GATE_CHILD_NAME);
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, L"Local\\kitsune-process-gate");
    if (!event) ExitProcess(1);
    emit("PROCESS-GATE PARENT: creating real child\n");
    /* Keep the child/JIT gate independent of the in-process server's current
     * directory bug. A separate relative-path regression remains necessary. */
    if (!CreateProcessW(child, NULL, NULL, NULL, FALSE,
                         0, NULL, directory, &startup, &process)) {
        emit_error("PROCESS-GATE FAIL: CreateProcessW"); ExitProcess(2);
    }
    emit("PROCESS-GATE PARENT: CreateProcessW returned handles\n");
    if (WaitForSingleObject(event, 45000) != WAIT_OBJECT_0) {
        emit("PROCESS-GATE FAIL: shared event\n"); ExitProcess(3);
    }
    if (WaitForSingleObject(process.hProcess, 45000) != WAIT_OBJECT_0 ||
        !GetExitCodeProcess(process.hProcess, &status) || status != 42) {
        emit("PROCESS-GATE FAIL: child exit code\n"); ExitProcess(4);
    }
    CloseHandle(event); CloseHandle(process.hProcess); CloseHandle(process.hThread);
    emit("PROCESS-GATE PASS: child boot, shared event, exit status 42\n");
    ExitProcess(0);
#endif
}
