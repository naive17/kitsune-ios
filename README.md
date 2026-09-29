# ios-wine

Windows programs on an iPhone, inside one app. The app carries its own build of
[Wine](https://www.winehq.org):

- Wine's unix side is compiled for arm64-apple-ios.
- x86-64 code is translated by [FEX](https://github.com/FEX-Emu/FEX) through
  ARM64EC.
- Direct3D 11 runs on Metal through [DXMT](https://github.com/3Shain/dxmt).
- Generated code lives in a JIT region that a debugger (StikDebug) makes
  executable at launch.

Steam installs, starts and reaches its login window, and Dark Souls Remastered
runs on an iPhone 14. It is experimental: see [docs/status.md](docs/status.md)
for what works and what does not.

## Requirements

- An iPhone with Developer Mode enabled.
- LiveContainer with StikDebug, for JIT ([docs/device.md](docs/device.md)).
- To build: a Mac with Apple silicon, Xcode, Homebrew and about 16 GB of free disk.

## Install a release

Release IPAs are unsigned. Install one with a sideloading tool (SideStore,
AltStore or Sideloadly) that signs it with your Apple ID, then follow
[docs/device.md](docs/device.md) to set up JIT.

## Build from source

```sh
cp local.env.example local.env   # your Apple team and a bundle id registered to it
scripts/setup.sh                 # checks the Mac, then builds the toolchains and the port
scripts/app.sh install --full    # builds the app and installs it on the paired iPhone
```

`scripts/setup.sh` resumes where it stopped and skips finished steps, and
`scripts/setup.sh --check` checks the Mac without building.
[docs/building.md](docs/building.md) covers every step, thin app updates and
release IPAs.

## Using the app

- **Library** lists Steam and its games, imported programs, and Wine's own
  tools. Install Steam downloads Valve's client into its own bottle.
- **Bottles** holds the Wine prefixes with their programs and tools, and opens a
  bottle's drive C in the Files app.
- **Settings** holds the display, power, texture, controller and diagnostics
  choices.

When JIT is not yet granted, the app opens StikDebug through LiveContainer and
continues once you return.

While a program runs, the session bar can:

- switch the pointer mode;
- show the on-screen controller and the keyboard;
- send Esc, Tab, Ctrl and Alt;
- list the running windows;
- toggle the performance overlay and Battery mode.

## Layout

| Path | Contents |
|---|---|
| `src/ios/` | The app: boot, launcher, Steam library, settings, display host, input, audio, diagnostics |
| `src/ios/en.lproj/Localizable.strings` | Every text the app shows, in one file |
| `src/jit/` | The JIT memory allocator the app shares with Wine |
| `src/session/` | The session host, the root process of every Wine session |
| `src/lzma/` | The LZMA SDK decoder, for Steam's client packages |
| `src/host/` | The macOS harness, which runs the iOS-shaped Wine inside one Mac process |
| `src/fex/`, `src/guests/` | Test programs for the harness |
| `patches/` | The port: Wine, DXMT and FEX as patches against the upstreams pinned in `pins.env` |
| `scripts/` | `setup.sh`, the numbered build steps, `app.sh` and the device tools |
| `tests/` | Host-side unit tests (`scripts/test.sh`) |
| `jit-scripts/` | The StikDebug script that enables JIT |
| `assets/` | Launch requests for the device tools |

`third_party/`, `build/`, `out/`, `toolchains/` and `.deploy/` are created by
the build and ignored by git.

## Documentation

- [Architecture](docs/architecture.md): how one iOS process runs Wine
- [Building](docs/building.md): the setup script, every build step, the app and releases
- [Device](docs/device.md): JIT, launching, logs and test switches
- [Status](docs/status.md): what works, the limits, what's next
- [Contributing](CONTRIBUTING.md): setup, commit format, working on the ports, tests

## License

ios-wine's own code, including its changes to Wine, DXMT and FEX, is
GPL-3.0-or-later ([LICENSE](LICENSE)). Wine, DXMT, FEX and the other
components keep their own licenses; see [LICENSES/](LICENSES/README.md).
