/* A threaded child's memory comes back when it exits. Children share the app's
 * address space, so nothing but the reaper returns what one allocated: the
 * child commits and touches 256 MB, loads a DLL and runs more threads than
 * the reaper once tracked, then exits, and the parent checks the block is
 * no longer committed. Large blocks live in a shared band, so released they
 * read as reserved rather than free. */
#include <windows.h>

#define BLOCK_SIZE (256u << 20)
#define THREADS 150

static void emit(const char *s) {
    DWORD length = 0, count;
    while (s[length]) ++length;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), s, length, &count, NULL);
}

#if RECLAIM_CHILD
static DWORD WINAPI short_thread(void *arg) {
    (void)arg;
    return 0;
}
#endif

void mainCRTStartup(void) {
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 4096,
                                        L"Local\\kitsune-child-reclaim");
    volatile ULONG_PTR *shared;
    if (!mapping) { emit("CHILD-RECLAIM FAIL: file mapping\n"); ExitProcess(1); }
    shared = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 4096);
    if (!shared) { emit("CHILD-RECLAIM FAIL: map view\n"); ExitProcess(1); }
#if RECLAIM_CHILD
    for (unsigned i = 0; i < THREADS; ++i) {
        HANDLE thread = CreateThread(NULL, 0, short_thread, NULL, 0, NULL);
        if (!thread) { emit("CHILD-RECLAIM CHILD: CreateThread failed\n"); ExitProcess(10); }
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
    }
    char *block = VirtualAlloc(NULL, BLOCK_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!block) { emit("CHILD-RECLAIM CHILD: VirtualAlloc failed\n"); ExitProcess(11); }
    for (unsigned offset = 0; offset < BLOCK_SIZE; offset += 4096) block[offset] = 1;
    if (!LoadLibraryW(L"C:\\windows\\system32\\dwmapi.dll")) {
        emit("CHILD-RECLAIM CHILD: LoadLibrary failed\n"); ExitProcess(12);
    }
    {
        /* A read caches the handle's unix descriptor; left open, the reaper
         * must close it. */
        static WCHAR self[1024];
        char byte;
        DWORD got;
        HANDLE file;
        GetModuleFileNameW(NULL, self, 1024);
        file = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        if (file == INVALID_HANDLE_VALUE || !ReadFile(file, &byte, 1, &got, NULL)) {
            emit("CHILD-RECLAIM CHILD: reading a file failed\n"); ExitProcess(13);
        }
    }
    shared[0] = (ULONG_PTR)block;
    emit("CHILD-RECLAIM CHILD: 256 MB committed after 150 threads; exiting 42\n");
    ExitProcess(42);
#else
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;
    MEMORY_BASIC_INFORMATION info;
    DWORD status;
    static WCHAR child[1024], directory[1024];
    DWORD length = GetModuleFileNameW(NULL, child, 1024);
    if (!length || length >= 1024) ExitProcess(5);
    DWORD basename = length;
    while (basename && child[basename - 1] != '\\' && child[basename - 1] != '/') --basename;
    if (!basename || basename + 32 >= 1024) ExitProcess(6);
    child[basename] = 0;
    lstrcpyW(directory, child);
    lstrcpyW(child + basename, L"child-reclaim-child.exe");
    shared[0] = 0;
    if (!CreateProcessW(child, NULL, NULL, NULL, FALSE, 0, NULL, directory, &startup, &process)) {
        emit("CHILD-RECLAIM FAIL: CreateProcessW\n"); ExitProcess(2);
    }
    if (WaitForSingleObject(process.hProcess, 120000) != WAIT_OBJECT_0 ||
        !GetExitCodeProcess(process.hProcess, &status) || status != 42 || !shared[0]) {
        emit("CHILD-RECLAIM FAIL: child did not finish\n"); ExitProcess(3);
    }
    CloseHandle(process.hProcess); CloseHandle(process.hThread);
    /* The reaper runs after the child's last thread is joined. */
    for (unsigned tries = 0; tries < 100; ++tries) {
        if (VirtualQuery((void *)shared[0], &info, sizeof(info)) && info.State != MEM_COMMIT) {
            emit("CHILD-RECLAIM PASS: the child's 256 MB is no longer committed after it exited\n");
            ExitProcess(0);
        }
        Sleep(100);
    }
    emit("CHILD-RECLAIM FAIL: the child's 256 MB is still allocated\n");
    ExitProcess(4);
#endif
}
