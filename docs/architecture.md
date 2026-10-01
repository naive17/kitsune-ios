# Architecture

Kitsune runs Windows programs inside one iOS app process. Wine's unix side is
built for arm64-apple-ios and loaded from the app bundle, x86-64 code is
translated by FEX through ARM64EC, Direct3D 11 is implemented on Metal by DXMT,
and every page of code the program runs lives in a JIT arena that a debugger
made executable once at launch.

## Processes

iOS gives an app one process and no way to start another, so everything Wine
would spread over several processes shares that one:

- **wineserver** is linked into the app as `libwineserver.a` and runs as a
  thread (`server/ios_inproc.c`). It stays alive when its last client
  disconnects.
- **Windows child processes** run as threads of the same Mach task, each with
  its own Wine process state (`KITSUNE_THREADED_PROCESS`).
- **One session per app launch.** Wine boots once, with a session host
  (`src/session/session.c`) as its root process. The display driver's thread
  in the host starts each program the app queues (`src/ios/session.m`), and
  the in-process server's count of running programs tells the app when to
  show the Library again. Programs from one bottle share the session. A
  console program started before any session runs alone as Wine's root
  process.
- **Programs run elevated.** The first process gets a full administrator
  token and every child inherits it (`server/process.c`), as from "Run as
  administrator": an app has one user and no UAC prompt. Steam needs this;
  without admin rights it depends on its service, whose installer is 32-bit.
- **Another bottle is another process.** Wine's state cannot be torn down and
  started again inside one process, so opening a program from another bottle,
  or anything after Wine has stopped, restarts the app: it saves what to open
  (`Documents/pending-launch.plist`, or `launch-request.json` for Steam),
  exits, which ends the old bottle's programs and frees all they held, and
  StikDebug launches a new instance under JIT that opens it. It asks first
  when programs are running.

## Executing code

- **JIT arena.** iOS makes memory executable only for a process being
  debugged. StikDebug, running inside LiveContainer, attaches to the app at
  launch; the app maps a large arena, has it blessed executable through a
  breakpoint handshake with the StikDebug script in `jit-scripts/`, and the
  debugger detaches. PE images and FEX's translated code are placed in that
  arena (`src/ios/jit_arena.c`, `WINE_IOS_JIT_ARENA` in ntdll). Protection
  changes there are one-way, which is why PE modules use 64 KB section
  alignment: a 16 KB host page must never hold both code and writable data.
- **TEB register.** Darwin zeroes x18 when it preempts a thread, so the port
  keeps the TEB in x28 (`WINE_TEB_IN_X28`). Every unix translation unit and
  every native ARM64 PE module is built with `-ffixed-x28`.
- **x86-64 programs** run through FEX as `libarm64ecfex.dll`. Wine's own
  modules are ARM64 and ARM64EC and run natively; only x86-64 code is
  translated.

## Graphics, display and input

- **wineios.drv** is the display driver. Each top-level window is a
  `CAMetalLayer` in the app's view hierarchy (`src/ios/wine_surface.m`). The
  desktop is sized to the safe area at a chosen render scale, so a game's
  800x600 minimum fits in landscape.
- **DXMT** turns D3D11 into Metal. Its PE modules (`d3d11`, `dxgi`,
  `d3d10core`, `winemetal`) and its unix half `winemetal.so` form one pair and
  must come from the same build. GPUs without BC texture support get BC data
  decoded on the CPU, or transcoded to ETC2 when native textures are chosen.
  Shader translation goes through DXMT's DXBC to AIR compiler, which needs
  LLVM 15.
- **Input.** Touches become mouse input in three pointer modes (tap,
  trackpad, look); the session bar sends keys the soft keyboard lacks.
  Controllers from the GameController framework and the on-screen controller
  publish XInput state that Wine's builtin XInput reads from the app
  (`ios_gamepad.h`).
- **Audio** is winecoreaudio.drv on RemoteIO.

## Memory

A phone gives the app far less address space and memory than Windows programs
assume. The launch profile for Steam sets the policy that makes it fit: the
thread stack pool, the large-allocation pool, the band CEF allocates in, FEX's
and the arena's code budgets, and the swap file (`src/ios/launch_profile.h`).
Power modes set the QoS class of guest threads and cap presented frames live.

Child processes share the app's address space, so nothing but the port gives
their memory back. When a child exits, a reaper thread joins each of its
threads, then frees what the child's own code allocated or mapped: views
created through its memory syscalls, its members of the shared mid-size
bands and its CEF pools (`ios_reclaim_owner_arena_views` in `virtual.c`).
What Wine's shared unix libraries allocate is never counted as a child's.

A game started through Steam runs without Steam's web helper, its UI and its
largest process (`KITSUNE_STEAM_LEAN`, set for game launches): the helper is
ended when Steam starts the game, refused while the game runs, and back after
it exits (`NtCreateUserProcess` in `process.c`). With the helper alive, Dark
Souls: Remastered left 334 MB free and the phone compressing memory; without
it, 1.1 GB.

The debugger-blessed JIT arena holds the code the CPU runs: Wine's ARM64 and
ARM64EC modules and FEX's code buffers. For a Unity game, executable memory
the program allocates holds x86-64 code, which FEX only reads, so it is
ordinary memory (`ios_app_vm_call` in `virtual.c`). There its Windows protection applies, and
that is what makes self-modifying code work: FEX write-protects code it has
translated, one 16 KB host page at a time, and a JIT that patches its own code
(Mono) faults and gets it retranslated. FEX's Mono hack, which stops that
detection once it has hooked Mono's backpatcher, is off (`FEX_MONOHACKS=0`,
`wine_boot.m`). Every other launch keeps that memory in the arena, as before
the Unity work (`KITSUNE_APP_EXEC_IN_ARENA`, set by `launch_profile.h` when the
game directory has no `UnityPlayer.dll` or `MonoBleedingEdge`): Dark Souls:
Remastered has run in slow motion since it moved out.

Unity games started through Steam store large RGBA8 textures they only sample
as ETC2, a quarter of the size (`KITSUNE_RGBA_ETC2`, in winemetal): they ship
uncompressed atlases that would not fit the app's 4 GB. The first load of a
level pauses while they are encoded.

## Storage on the phone

| Path in the app's Documents | Contents |
|---|---|
| `wine/` | The runtime's PE tree and prefix template. The PE modules the bundle carries (ntdll, DXMT, XInput) win over the tree's copies; unix halves load only from the signed bundle. |
| `prefix/` | The default bottle |
| `Bottles/<name>/` | Other bottles, including `Steam` |
| `Apps/` | Imported programs and the Steam client |
| `wine-stderr.log`, `hb.log` | Wine's log and the heartbeat |

## The app

`src/ios/boot_vc.m` owns a launch: it installs or checks the runtime tree,
which needs no JIT, then waits for JIT, sets up the arena and the default
bottle, and runs the chosen program. A bottle made from an older template is
brought up to date before Wine starts (`KitsuneRepairBottle` in `bottles.h`). The launcher has three tabs: Library
(Steam, imported programs, Wine's own tools), Bottles, and Settings.
Diagnostics have three levels, and only Full pays for thread dumps, traces and
log snapshots (`src/ios/diagnostics.h`).

## Source and build

The port is kept as patches against pinned upstreams: the Wine series in
`patches/wine`, `patches/dxmt` and the FEX stack in `patches/fex`, with
revisions in `pins.env`. `scripts/setup.sh` runs the numbered build scripts in
order ([building.md](building.md)); `scripts/save-patches.sh` records the Wine
and DXMT trees after an edit.

Tests run at two levels: `scripts/test.sh` for host unit tests, and the macOS
harness (`16`, `20` and `21-regress.sh`) for the port's own logic: the
in-process server, threaded children, arena placement, D3D11, input and the
session host. What only the phone can answer (JIT, memory limits, the GPU) is
checked by running the app.
