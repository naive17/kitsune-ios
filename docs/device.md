# Device

The app's bundle id is `dev.kitsune.app`, or your `KITSUNE_BUNDLE_ID`. iOS
lets an app run generated code only while a debugger is attached, so the app
gets JIT from StikDebug running inside LiveContainer. The Mac-side scripts use
the only paired iPhone and the LiveContainer installed on it; `UDID` and
`LIVECONTAINER` (in `local.env` or the environment) pick others. Everything
here works over USB or Wi-Fi pairing.

## What the phone needs

1. Developer Mode, turned on in Settings.
2. LiveContainer with StikDebug in it, a valid pairing file imported into
   StikDebug, and StikDebug's VPN running. These are installed by hand; the
   port is tested with these revisions:
   - LiveContainer `bbd398fb51e6a9ab71ce6e38f890f45f9c5073c8`
     (https://github.com/LiveContainer/LiveContainer)
   - StikDebug `66e359c7e2197c969a34227d3df0b0cf1af6a155`
     (https://github.com/StephenDev0/StikDebug)
3. For a build from source: the phone paired with the Mac, so that
   `xcrun devicectl list devices` shows it as paired.

## Installing

**From source.** Run `scripts/app.sh install --full` once, then trust the
developer certificate in Settings > General > VPN & Device Management. Later
updates can be thin (`scripts/app.sh install`). Then, in the app, Library >
Install Steam downloads Valve's client into its own bottle.

**From a release.** Release IPAs are not signed for any device. Install one
with a sideloading tool (SideStore, AltStore or Sideloadly), which signs it
with your Apple ID. The IPA bundles the Wine runtime as native libraries
outside the usual Frameworks folder. If the app cannot load its runtime after
installing, your tool did not re-sign those libraries: try another tool, or
build from source.

## Launch

The app's Play rows queue `Documents/launch-request.json`. When JIT is not yet
granted, the app opens StikDebug with its bundled `jit-scripts/kitsune.js`,
and the Enable JIT button does the same.

StikDebug's own app list runs a script only when one is assigned to the app.
To use it: in the Files app, open the app's folder, import `kitsune.js` into
StikDebug's Scripts, and assign it to Kitsune. Without that, StikDebug only
sets the debug flag, and the app asks you to tap Enable JIT to attach the
script.

From a Mac:

```sh
scripts/dev/ensure-jit-run.sh assets/dsr-rendering-launch.json 4 1024   # launch a request under JIT
scripts/dev/remote.sh --wait 2000 "key 69"                              # send input; coordinates are Wine pixels
```

## Logs

`Documents/wine-stderr.log` is Wine's stderr. `Documents/hb.log` is the
heartbeat; it is written with write(2), so it is the record that survives a
kill. Steam's own logs are under `Documents/Apps/Steam/logs`.

```sh
scripts/dev/device.sh logs           # copies hb.log and wine-stderr.log to .deploy/device/logs/
```

Settings > About > Share logs exports the same files from the phone.
Settings > Diagnostics sets how much the app records:

| Level | What it records |
|---|---|
| Off | A 30 s liveness tick |
| Basic | Adds the guest sampler |
| Full | Also thread dumps, log snapshots, the Mach exception monitor, and Metal and XInput traces |

## Test switches

- **`Documents/dxmt-gpu-debug.txt`**
  - The file holds a single number:
    - 1 waits for every command buffer to complete.
    - 2 turns DontCare stores into Store.
    - 3 does both.
  - It is read only with Diagnostics at Basic or Full, on the first present and then every 60th.
  - A Steam launch deletes it. For a Steam game, write the file after tapping Play; it takes effect within 60 frames.
- **`KITSUNE_NIL_DRAWABLE_EVERY=N`**, in a launch request's `env`, makes every Nth `nextDrawable` return nil. This exercises DXMT's dropped-frame path. The log reports the first nil and every 240th.
- **`Documents/render-scale`** overrides the render scale that the Resolution setting chooses.

## Runtime files

- **PE modules** load from the app bundle first, and from the phone's `Documents/wine` tree otherwise. The bundle carries ntdll, apisetschema, DXMT and XInput, so DXMT's PE modules always match the bundle's `winemetal.so`.
- **iOS unix halves** load only from the signed bundle.
- **Documents also holds:** `Bottles/<name>`, `Apps/` (imported programs and Steam), and `render-scale`.
- **Orientation** is decided when a program starts: from `KITSUNE_LANDSCAPE` in a launch request's environment, otherwise from the Other Programs setting.

`scripts/dev/device.sh sync-tree` replaces `Documents/wine` with `out/wine-core`.
`scripts/dev/device.sh sync-fex` replaces only the x86-64 emulator in it. Relaunch
the app after either.
