/* The root process of every Wine session the app runs. It starts nothing
 * itself: it loads the display driver, whose drain thread in this process
 * starts the programs the app queues, and then waits for the session to end
 * with the app. It creates the desktop window, as the first process of a
 * session does, and stays an ordinary process so the programs it starts share
 * its desktop; the app leaves it out when counting programs.
 *
 * The desktop window is this thread's, so this thread answers the messages
 * sent to it. A screen change sends it WM_DISPLAYCHANGE from the drain thread
 * and waits for the reply; a thread that only slept left that wait, and with
 * it all input and every later screen change, stuck for good. */
#include <windows.h>

void mainCRTStartup(void) {
    MSG msg;

    if (!LoadLibraryW(L"wineios.drv")) ExitProcess(1);
    GetDesktopWindow();
    for (;;)
        if (GetMessageW(&msg, NULL, 0, 0) > 0) DispatchMessageW(&msg);
}
