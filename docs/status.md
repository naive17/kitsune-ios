# Status

Where the port stands, what it cannot do yet, and what to look at next. How it
works is in [architecture.md](architecture.md).

## Working

- **Steam.** Installs from Valve's client packages and starts without
  downloading or unpacking again (the package folder holds the file index
  Steam's updater writes). Signs in with the QR code, runs as administrator so
  it needs no Steam service, and a game launched from the Library starts it
  hidden, in the tray.
- **Games.** Dark Souls Remastered runs on an iPhone 14 through DXMT, as a
  child of the session host, launched from the Library through Steam. While a
  game runs, Steam's web helper is ended and its memory returned.
- **Memory.** A child process that exits gives back what its own code
  allocated or mapped; see [architecture.md](architecture.md#memory).
- **Sessions.** Programs run in one Wine session per app launch. The session
  bar's Library button opens the Library over a running program, programs from
  the same bottle start alongside it, and the Library returns when the last one
  exits. Screen rotations reach Wine and input keeps working after them.
- **Input and audio.** Touch as mouse in three pointer modes, the on-screen and
  hardware controllers as XInput, the soft keyboard, and audio through
  RemoteIO. Hover menus close when the cursor leaves them.

## Limits

- Switching to another bottle restarts the app (through StikDebug), because
  Wine starts once per process; programs running in the old bottle close.
- Only 64-bit programs run. 32-bit Windows programs, including the official
  SteamSetup.exe and Steam's service, need FEX's WoW64 module, Wine's i386
  modules and address space below 4 GB, and the build makes none of these yet.
  FEX's WoW64 module also keeps its CPU state in x28, the register this port
  uses for the TEB.
- Direct3D 11 (and 10) only. The D3D9 and D3D12 translators in the tree
  (DXVK, vkd3d-proton) need a Vulkan driver, which the app does not bundle.
- iOS gives an app far less memory and address space than Windows programs
  expect. Steam fits because its launch profile sets the memory policy.
- Steam's overlay is unavailable in games: it needs the web helper.
- JIT needs StikDebug attached at every launch.
- Over Wi-Fi, `devicectl` copies of large files time out while the phone is
  locked.

## Next

1. **Dark Souls' fullscreen window.** In fullscreen mode its window is placed
   at 59,59 while its Direct3D layer stays at 0,0, leaving a rim at the top;
   borderless mode draws correctly.
2. **Steam's server connection during a game.** Once, Steam's servers dropped
   the connection as the game started, with the app near 3.6 GB, and it did not
   reconnect while the game ran. Check whether it recurs now that the web
   helper's memory is returned.
3. **Steam's web helper start.** About 40 s from launch to the login window;
   the next performance target.
