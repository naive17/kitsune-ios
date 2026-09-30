# Kitsune

A port of [Wine](https://www.winehq.org) that run on iOS through JIT to run Steam games and x86 apps.

## Currently booting

- Steam, fully working login, install and launch
- Dark Souls Remastered running in game, 60fps with dips here and there

## Stack

- Wine's unix side is compiled for arm64-apple-ios.
- x86-64 code is translated by [FEX](https://github.com/FEX-Emu/FEX) through
  ARM64EC.
- Direct3D 11 runs on Metal through [DXMT](https://github.com/3Shain/dxmt).

## How to use

- Using iLoader or Sidestore install the unsigned ipa of Kitsune.
- Then either use Stikdebug in Livecontainer or sideload Stikdebug.
- Install LocalDevVPN and enable it.
- Copy kitsune.js from the Kitsune folder in files to the Stikdebug scripts folders.
- Open StikDebug and longpress on Kitsune to assign the kitsune.js script to allow for JIT.
- Launch Kitsune.
- Install Steam.
- Allow Steam to open stikdebug and allow JIT.
- Wait up to 2 minutes to let steam run, login, install games and launch

## Caveats
- Steam takes a lot of memory, so you may find it easier to install through steam, kill the app and relaunch through the library, it launches steam in silent mode, without the rendering of the ui, which reserves more memory for the games.
- Memory is very limited for apps on ios without special entitlments.

## Build from source

To build you need a Mac with Apple silicon, Xcode, Homebrew and about 16 GB of free disk.

```sh
cp local.env.example local.env   # your Apple team and a bundle id registered to it
scripts/setup.sh                 # checks available space and installed stuff, then it fetches external dependencies and compiles them
scripts/app.sh ipa               # builds the app and outputs an ipa ready to install


# to reiterate on development

scripts/app.sh install --full    # full build and coredevice install with usb cable or network
scripts/app.sh install           # progressive build and install with usb cable or network
```

`scripts/setup.sh` resumes where it stopped and skips finished steps, and
`scripts/setup.sh --check` checks the Mac without building.
[docs/building.md](docs/building.md) covers every step, thin app updates and
release IPAs.

## Documentation

- [Architecture](docs/architecture.md): how one iOS process runs Wine
- [Building](docs/building.md): the setup script, every build step, the app and releases
- [Device](docs/device.md): JIT, launching, logs and test switches
- [Status](docs/status.md): what works, the limits, what's next
- [Contributing](CONTRIBUTING.md): setup, commit format, working on the ports, tests