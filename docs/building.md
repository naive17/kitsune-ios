# Building

Requirements: a Mac with Apple silicon, Xcode with the iPhoneOS SDK,
Homebrew, about 16 GB of free disk, and network access for the first run. The
first setup takes about an hour on an M1, most of it building LLVM 15 twice;
later runs rebuild only what changed. The
scripts use the selected Xcode, or the first one found in `/Applications`, on
an external volume or in `~/Downloads`; `DEVELOPER_DIR` overrides the choice.

## Setup

```sh
cp local.env.example local.env   # your Apple team and bundle id
scripts/setup.sh                 # toolchains, sources and every build step
scripts/app.sh install --full    # first install on a phone (device.md)
```

`setup.sh` first checks Xcode: its license, its first launch, and the Metal
toolchain, which it downloads when it is missing. It installs any missing
Homebrew packages and the commit-msg hook, then runs the steps in sections 1
to 3 below, in order. A step is skipped when its output exists and it last
succeeded with the same script and `pins.env`. Once a build step runs, every
later one runs too. Each step's log goes to `build/setup/`.

| Option | Effect |
|---|---|
| `--list` | Shows which steps would run |
| `--from STEP` | Redoes STEP and every step after it |
| `--toolchain` | Stops after section 1 |
| `--check` | Checks the machine without building anything |

`local.env` holds per-developer settings, and every script reads it. The team
and bundle id in `kitsune-device.yml` belong to the maintainer's Apple team;
anyone else signs with their own, set by `KITSUNE_TEAM` and
`KITSUNE_BUNDLE_ID`. See `local.env.example` for the rest.

The port is committed as patches against the upstream revisions pinned in
`pins.env`, and the scripts apply them. Everything these steps produce is
ignored by git: build directories go to `build/`, outputs to `out/`, and the
staged app runtime to `.deploy/runtime`. The sections below list the steps
`setup.sh` runs, which you can also run one at a time to rebuild a single part.

## 1. Toolchains and sources

```sh
scripts/01-toolchain.sh          # llvm-mingw (PE cross compiler)
scripts/02-fetch.sh              # pinned checkouts; applies the Wine and DXMT ports
scripts/03-llvm15.sh             # LLVM 15 for macOS (DXMT's DXBC-to-AIR compiler)
TARGET=ios scripts/03-llvm15.sh  # and its iOS libraries
scripts/04-freetype.sh           # FreeType for macOS and iOS
scripts/05-gnutls-ios.sh         # GnuTLS for iOS (schannel TLS, crypt32 PFX)
```

`02-fetch.sh` applies the Wine port, the numbered series in `patches/wine`, as
one commit per patch on the pin (`patches/wine/README`). It runs
`scripts/apply-dxmt-port.sh`, which creates the DXMT base commit (v0.80 plus
patches 0001 and 0002) and applies the full patch; see
`patches/dxmt/ios-dxmt-full-vs-upstream.README`. The FEX patch stack in
`patches/fex` is applied by FEX's build script.

## 2. Windows side (PE)

```sh
scripts/06-fex-arm64ec.sh        # libarm64ecfex.dll (downloads the llvm-mingw fork it needs)
scripts/07-wine-macos.sh         # Wine's PE modules and host tools (widl, winebuild)
scripts/08-dxvk.sh               # d3d9 (DXVK), kept for a future Vulkan path
scripts/09-vkd3d.sh              # d3d12 (vkd3d-proton), same
scripts/10-dxmt.sh               # DXMT's d3d11, dxgi, d3d10core and winemetal PE modules
```

## 3. Unix side and the tree

```sh
scripts/11-wine-ios.sh           # the iOS unix halves (ntdll.so, win32u.so, wineios.so, ...) and libwineserver.a
scripts/12-stage-prefix.sh       # the FEX and D3D modules laid over the tree
scripts/13-stage-wine-tree.sh    # out/wine-tree: the full PE and unix tree
python3 scripts/14-core-tree.py  # out/wine-core: the tree the app ships
scripts/15-dxmt-ios.sh           # winemetal.so for iOS; stages DXMT into out/wine-core
scripts/16-host-harness.sh       # the macOS harness, which makes the prefix template
scripts/17-prefix-template.sh    # out/wine-core/prefix-template
scripts/18-stamp-tree.sh         # out/wine-core/TREE_VERSION
scripts/19-stage-runtime.sh      # .deploy/runtime, bundled by thin app builds
```

The unix side must be built with `-ffixed-x28 -DWINE_TEB_IN_X28
-DWINE_IOS_JIT_ARENA`, and the scripts set these. `11-wine-ios.sh` runs
configure once and builds incrementally after that; `--reconfigure` forces
configure again. After you edit Wine's unix side, `scripts/11-wine-ios.sh`
rebuilds it, `scripts/save-patches.sh` records both ports, and
`scripts/app.sh install` stages the runtime and installs a thin build.

## 4. The app

```sh
scripts/app.sh build             # thin: bundles .deploy/runtime; the phone keeps its tree
scripts/app.sh build --full      # also bundles out/wine-core (first install on a phone)
scripts/app.sh install [--full]  # build, then install on the paired iPhone
scripts/app.sh ipa [file.ipa]    # a full build packaged for sideloading
scripts/app.sh sign-check        # the signing identity the phone will accept
```

The Xcode project is generated from `kitsune-device.yml` by xcodegen on every
build, and is not tracked. Signing is automatic. `-allowProvisioningUpdates`
creates a new certificate when none is valid, and that revokes the previous
one. If you build on more than one Mac, export the certificate as a .p12 and
import it on the others instead of letting each Mac create its own. The first
app build fetches the Mozilla CA bundle (`scripts/lib/stage-ca-bundle.sh`).

A free (personal) Apple team can sign the app's entitlements
(`src/ios/kitsune.entitlements`: get-task-allow and the increased memory
limit). It cannot sign `increased-debugging-memory-limit` or
`extended-virtual-addressing`: adding either one fails the build with
profile errors that look like certificate problems, and both need a paid
Apple Developer Program membership.

A phone that has never had a Wine tree needs one `--full` install, or
`scripts/dev/device.sh sync-tree`.

## After a pull

A pull that changes `patches/` leaves the checkouts in `third_party/` on the
old patches, and `setup.sh` does not see it: its stamps cover the scripts and
`pins.env`, not the patches.

```sh
scripts/sync-sources.sh           # reset stale checkouts to the pin, apply the current patches
scripts/setup.sh --from STEP      # the step it names
```

`sync-sources.sh` resets a checkout only when its files are exactly its pin
plus the patches of some commit, so it never loses anything git does not
have. It leaves a checkout alone if it has edits that no commit has, such as
Wine or DXMT work not yet recorded with `save-patches.sh`. It saves those
edits to `build/source-backups/`. `--discard` resets that checkout too, and
`git -C <checkout> apply -3 <saved patch>` then carries the edits onto the
new patches. Record them with `save-patches.sh` only after that, because
running it before the sync overwrites the pulled patch with your old one.
A Wine checkout whose files already are the series, as one set up before the
port was split into it, only gets the series' commits; no file is written, so
nothing rebuilds. `--check` only reports, and naming checkouts (`wine`,
`fex`) limits it to them.

## After you edit a component

`setup.sh` does not notice source edits: a step it has finished stays done
until its script or `pins.env` changes, so a plain rerun reports nothing to
do. `--from STEP` redoes that step and every step after it; the steps after it
rebuild incrementally.

| You edited | Rebuild | Get it onto the phone |
|---|---|---|
| FEX | `scripts/setup.sh --from fex` | `scripts/dev/device.sh sync-fex` |
| Wine's unix side (`*/unix/*.c`) | `scripts/11-wine-ios.sh` | `scripts/app.sh install` |
| Wine's PE modules | `scripts/setup.sh --from wine-macos` | `scripts/dev/device.sh sync-tree`, or an `install --full` |
| DXMT | `scripts/setup.sh --from dxmt` | `scripts/app.sh install` |
| The app (`src/ios`) | `scripts/app.sh build` | `scripts/app.sh install` |

A thin install carries every iOS unix half but only a few PE modules (see
`19-stage-runtime.sh`): ntdll, apisetschema, sechost, `wineios.drv`, the
session host, DXMT and XInput. Every other PE module, FEX included, lives in
the phone's `Documents/wine` ([device.md](device.md#runtime-files)) and changes
only through `sync-tree`, `sync-fex` or a `--full` install.

`11-wine-ios.sh` alone refreshes `out/ios-unix`, which is all a thin install
needs. `out/wine-core`, the prefix template and the IPA are built from it
later, so before a `--full` install or `app.sh ipa`, run
`scripts/setup.sh --from wine-ios` instead. After a change to `dlls/ntdll/unix`,
run the harness and the regression suite (`CONTRIBUTING.md`) before a device
run.

### Recording a FEX change

`06-fex-arm64ec.sh` resets `third_party/fex` to the pin and applies
`patches/fex` in order, so an edit made in the checkout is lost the next time
it runs. Record it as the next patch in the stack:

```sh
git -C third_party/fex add -A        # after 06 has run: the pin plus the stack
# edit; for a new file: git -C third_party/fex add -N <file>
git -C third_party/fex diff --ignore-submodules > patches/fex/0012-name.patch
git -C third_party/fex reset -q      # 06's `git checkout -- .` restores from the index
```

Then add an `apply_patch` line for it to `06-fex-arm64ec.sh`, add a line to
`patches/fex/README`, and run `scripts/setup.sh --from fex`. The diff holds
only your edit because the index holds the stack. `--ignore-submodules` keeps
out the `External/rpmalloc` dirty marker that patch 0002 leaves; an edit
inside rpmalloc is a diff in that submodule, like 0002.

To try a FEX change before recording it, rebuild in place and push the result:

```sh
cmake --build build/fex-arm64ec --target arm64ecfex -j4
scripts/dev/device.sh sync-fex build/fex-arm64ec/Bin/libarm64ecfex.dll
```

This skips 06's checks (imports only ntdll, no x18 reads), so run 06 before
you commit.

## Release IPA

`scripts/app.sh ipa` builds the full bundle without a development signature
and packages it for sideloading tools (SideStore, AltStore, Sideloadly), which
re-sign it with the installing user's certificate. It is ad-hoc signed with the
app's entitlements (`src/ios/kitsune.entitlements`), so they travel with the
IPA. It builds in `build/xc-ipa`, which leaves the development build alone.

`.github/workflows/release.yml` builds the same IPA on GitHub:

- Pushing a `v*` tag publishes the IPA as that tag's release.
- A manual run keeps the IPA as a workflow artifact for 14 days.
- One job builds the toolchains and caches them, under a key made from
  `pins.env` and their scripts. A second job restores that cache and runs
  `scripts/setup.sh` and `scripts/app.sh ipa`.
- It runs on the `xcode-27` runner, or on the runner named by the repository
  variable `KITSUNE_RUNNER`.

## Tests

```sh
scripts/test.sh                                  # host unit tests
scripts/16-host-harness.sh                       # the macOS harness
TEST_LAYOUT_DIR=/tmp/kitsune-test-layout scripts/20-test-layout.sh   # device-shaped layout plus every test program
TEST_LAYOUT_DIR=/tmp/kitsune-test-layout scripts/21-regress.sh       # the regression suite
```

The harness runs the iOS-shaped Wine inside one macOS process, as the app
does, and is the gate for changes to the port. `20-test-layout.sh` builds and
stages every program the suite runs: the x86-64 guests, the native ARM64
guests, the D3D11 tests and the process tests. `21-regress.sh` refuses to run
when one of them is missing, so a pass means every check ran.
`scripts/test.sh` also runs `tests/dwrite-backend-test.sh`, which checks the
static FreeType binding against a built tree and skips before setup has built
one.
