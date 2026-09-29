/* A child that exits holding a soft pool, as Steam's web helper does, must not
 * take the app with it: the pool is released on a thread Wine did not create. */
#include <windows.h>
static void emit(const char *s) {
    DWORD length = 0, count;
    while (s[length]) ++length;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), s, length, &count, NULL);
}
void mainCRTStartup(void) {
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;
    static WCHAR self[1024];
    WCHAR role[8];
    DWORD status;
    if (GetEnvironmentVariableW(L"CHILD_POOL_ROLE", role, 8)) {
        /* The image occupies the hinted address, so the reservation misses
         * the normal path and is served from a soft pool. */
        void *pool = VirtualAlloc(GetModuleHandleW(NULL), (SIZE_T)16 << 30, MEM_RESERVE, PAGE_NOACCESS);
        emit(pool ? "CHILD-POOL CHILD: reserved 16 GB\n" : "CHILD-POOL CHILD: reservation failed\n");
        ExitProcess(pool ? 42 : 11);
    }
    if (!GetModuleFileNameW(NULL, self, 1024)) ExitProcess(5);
    SetEnvironmentVariableW(L"CHILD_POOL_ROLE", L"child");
    if (!CreateProcessW(self, NULL, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
        emit("CHILD-POOL FAIL: CreateProcessW\n"); ExitProcess(2);
    }
    if (WaitForSingleObject(process.hProcess, 45000) != WAIT_OBJECT_0 ||
        !GetExitCodeProcess(process.hProcess, &status) || status != 42) {
        emit("CHILD-POOL FAIL: child\n"); ExitProcess(3);
    }
    Sleep(2000);  /* the pool is released after the child's last thread is gone */
    emit("CHILD-POOL PASS: the parent outlived a child holding a soft pool\n");
    ExitProcess(0);
}
