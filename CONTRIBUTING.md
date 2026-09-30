# Contributing

## Setup

```sh
cp local.env.example local.env   # your Apple team and bundle id; see the file
scripts/setup.sh                 # Xcode checks, toolchains, sources, every build step
npm install                      # the commit-msg hook (setup.sh does this too)
```

`scripts/setup.sh --check` checks the machine without building anything.
[docs/building.md](docs/building.md) covers each step and how to rebuild one
part; [docs/device.md](docs/device.md) covers the phone.

## App text

Every text the app shows is in `src/ios/en.lproj/Localizable.strings`, one
`"key" = "value";` line each: edit the value, never the key. The key is the
English text the code looks up, so a missing entry shows the key itself.

## Commits

Every commit subject is `<type>: <message>`, with the message at most ten
words. A husky `commit-msg` hook refuses anything else.

| Type | For |
|---|---|
| `add` | something new: a feature, a script, a test |
| `update` | a change to something that exists |
| `fix` | a bug fix |
| `remove` | deleting code, files or features |
| `docs` | documentation only |

```
fix: keep the prefix symlinks when installing the tree
update: Steam launch profile caps the CEF band at 2 GB
```

The body is free-form: say why, and what was measured. Merge, revert and
`fixup!`/`squash!` subjects that git writes itself pass as they are.

## Working on the ports

Wine, DXMT and FEX are kept as patches against the upstream revisions in
`pins.env`; `third_party/` holds the patched checkouts and is not tracked.

- **Wine**: the port is the numbered series in `patches/wine`
  ([README](patches/wine/README)), kept as one commit per patch in
  `third_party/wine`: `git log` there lists it and `git diff` shows what is
  not recorded yet. Edit the checkout, then run `scripts/save-patches.sh`,
  which folds each edit into the patch that changes that file and writes the
  series out.
- **DXMT**: edit `third_party/dxmt`, then run `scripts/save-patches.sh`. Until
  then the change exists only in that checkout, and a `git checkout` there
  discards it.
- **FEX**: the port is the numbered stack in `patches/fex`, applied in order by
  `scripts/06-fex-arm64ec.sh`, which resets `third_party/fex` first. Change a
  patch, or add the next number
  ([Recording a FEX change](docs/building.md#recording-a-fex-change)).
- **After a pull** that changed `patches/`, `scripts/sync-sources.sh` moves the
  checkouts to the new patches ([After a pull](docs/building.md#after-a-pull)).

After a change to Wine's unix side, `scripts/11-wine-ios.sh` rebuilds it
incrementally and `scripts/19-stage-runtime.sh` stages it for a thin app build.
[After you edit a component](docs/building.md#after-you-edit-a-component)
lists what to rebuild and how to get each part onto the phone.

## Tests

Run these before sending a change:

```sh
scripts/test.sh                                  # host unit tests
scripts/16-host-harness.sh                       # the macOS harness
DECOY_DIR=/tmp/decoy scripts/20-decoy-split.sh   # builds every test program
DECOY_DIR=/tmp/decoy scripts/21-regress.sh       # the regression suite
```

The harness runs the iOS-shaped Wine on the Mac: the in-process server,
threaded child processes, the arena and the session host. It catches most
regressions in the port without a phone. What only the device can answer
(JIT, Metal on the phone's GPU, memory limits) needs a run on the phone; say
in the change what you ran there.

## Licensing

Kitsune's own code, including its changes to Wine, DXMT and FEX, is
GPL-3.0-or-later. Upstream code keeps its own license: leave its headers in
place, and add a component you bundle to [LICENSES/README.md](LICENSES/README.md)
with its license text.
