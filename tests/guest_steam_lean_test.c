/* Steam without its UI while a game runs (KITSUNE_STEAM_LEAN): stand-ins named
 * like Steam's processes. steam.exe starts its web helper, then a game under
 * steamapps\common; the helper must be ended and its memory returned, its
 * restart refused while the game runs, and allowed once the game has exited.
 * LEAN_ROLE: 0 steam.exe, 1 steamwebhelper.exe, 2 the game. */
#include <windows.h>

#define HELPER_BLOCK (128u << 20)

static void emit(const char *s) {
    DWORD length = 0, count;
    while (s[length]) ++length;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), s, length, &count, NULL);
}

static volatile ULONG_PTR *shared_block(void) {
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 4096,
                                        L"Local\\kitsune-steam-lean");
    return mapping ? MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 4096) : NULL;
}

#if LEAN_ROLE == 0
static WCHAR dir[1024];

static BOOL start(const WCHAR *relative, PROCESS_INFORMATION *process) {
    STARTUPINFOW startup = {sizeof(startup)};
    static WCHAR path[1024];
    lstrcpyW(path, dir);
    lstrcatW(path, relative);
    return CreateProcessW(path, NULL, NULL, NULL, FALSE, 0, NULL, dir, &startup, process);
}

static BOOL helper_ready(HANDLE ready, PROCESS_INFORMATION *helper) {
    HANDLE both[2] = {ready, helper->hProcess};
    return WaitForMultipleObjects(2, both, FALSE, 60000) == WAIT_OBJECT_0;
}
#endif

void mainCRTStartup(void) {
    volatile ULONG_PTR *shared = shared_block();
    HANDLE ready = CreateEventW(NULL, FALSE, FALSE, L"Local\\kitsune-lean-ready");
    if (!shared || !ready) { emit("STEAM-LEAN FAIL: shared objects\n"); ExitProcess(1); }
#if LEAN_ROLE == 1
    char *block = VirtualAlloc(NULL, HELPER_BLOCK, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!block) ExitProcess(20);
    for (unsigned offset = 0; offset < HELPER_BLOCK; offset += 4096) block[offset] = 1;
    shared[0] = (ULONG_PTR)block;
    SetEvent(ready);
    for (;;) Sleep(1000);
#elif LEAN_ROLE == 2
    Sleep(4000);
    ExitProcess(7);
#else
    PROCESS_INFORMATION helper, game, again;
    MEMORY_BASIC_INFORMATION info;
    DWORD length = GetModuleFileNameW(NULL, dir, 1024), status;
    unsigned tries;
    if (!length || length >= 1024) ExitProcess(2);
    while (length && dir[length - 1] != '\\' && dir[length - 1] != '/') --length;
    dir[length] = 0;

    if (!start(L"steamwebhelper.exe", &helper) || !helper_ready(ready, &helper)) {
        emit("STEAM-LEAN FAIL: the web helper did not start\n"); ExitProcess(3);
    }
    if (!start(L"steamapps\\common\\Game\\game.exe", &game)) {
        emit("STEAM-LEAN FAIL: the game did not start\n"); ExitProcess(4);
    }
    if (WaitForSingleObject(helper.hProcess, 20000) != WAIT_OBJECT_0) {
        emit("STEAM-LEAN FAIL: the web helper still runs with the game\n"); ExitProcess(5);
    }
    emit("STEAM-LEAN: the game started and the web helper was ended\n");
    for (tries = 0; tries < 100; ++tries) {
        if (VirtualQuery((void *)shared[0], &info, sizeof(info)) && info.State != MEM_COMMIT) break;
        Sleep(100);
    }
    if (tries == 100) { emit("STEAM-LEAN FAIL: the web helper's memory stayed committed\n"); ExitProcess(6); }
    emit("STEAM-LEAN: the web helper's memory came back\n");
    if (start(L"steamwebhelper.exe", &again)) {
        emit("STEAM-LEAN FAIL: the web helper restarted while the game runs\n"); ExitProcess(7);
    }
    emit("STEAM-LEAN: its restart was refused while the game runs\n");
    if (WaitForSingleObject(game.hProcess, 30000) != WAIT_OBJECT_0 ||
        !GetExitCodeProcess(game.hProcess, &status) || status != 7) {
        emit("STEAM-LEAN FAIL: the game did not exit\n"); ExitProcess(8);
    }
    if (!start(L"steamwebhelper.exe", &again) || !helper_ready(ready, &again)) {
        emit("STEAM-LEAN FAIL: the web helper did not come back after the game\n"); ExitProcess(9);
    }
    TerminateProcess(again.hProcess, 0);
    emit("STEAM-LEAN PASS: helper ended for the game, memory returned, back after it\n");
    ExitProcess(0);
#endif
}
