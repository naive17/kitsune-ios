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
and bundle id in `ioswine-device.yml` belong to the maintainer's Apple team;
anyone else signs with their own, set by `IOSWINE_TEAM` and
`IOSWINE_BUNDLE_ID`. See `local.env.example` for the rest.

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

`02-fetch.sh` runs `scripts/apply-dxmt-port.sh`. That script creates the DXMT
base commit (v0.80 plus patches 0001 and 0002) and applies the full patch; see
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

The Xcode project is generated from `ioswine-device.yml` by xcodegen on every
build, and is not tracked. Signing is automatic. `-allowProvisioningUpdates`
creates a new certificate when none is valid, and that revokes the previous
one. If you build on more than one Mac, export the certificate as a .p12 and
import it on the others instead of letting each Mac create its own. The first
app build fetches the Mozilla CA bundle (`scripts/stage-ca-bundle.sh`).

A free (personal) Apple team can sign the app's entitlements
(`src/ios/ioswine.entitlements`: get-task-allow and the increased memory
limit). It cannot sign `increased-debugging-memory-limit` or
`extended-virtual-addressing`: adding either one fails the build with
profile errors that look like certificate problems, and both need a paid
Apple Developer Program membership.

A phone that has never had a Wine tree needs one `--full` install, or
`scripts/device.sh sync-tree`.

## Release IPA

`scripts/app.sh ipa` builds the full bundle without a development signature
and packages it for sideloading tools (SideStore, AltStore, Sideloadly), which
re-sign it with the installing user's certificate. It is ad-hoc signed with the
app's entitlements (`src/ios/ioswine.entitlements`), so they travel with the
IPA. It builds in `build/xc-ipa`, which leaves the development build alone.

`.github/workflows/release.yml` builds the same IPA on GitHub:

- Pushing a `v*` tag publishes the IPA as that tag's release.
- A manual run keeps the IPA as a workflow artifact for 14 days.
- One job builds the toolchains and caches them, under a key made from
  `pins.env` and their scripts. A second job restores that cache and runs
  `scripts/setup.sh` and `scripts/app.sh ipa`.
- It runs on the `xcode-27` runner, or on the runner named by the repository
  variable `IOSWINE_RUNNER`.

## Tests

```sh
scripts/test.sh                                  # host unit tests
scripts/16-host-harness.sh                       # the macOS harness
DECOY_DIR=/tmp/decoy scripts/20-decoy-split.sh   # device-shaped layout plus every test program
DECOY_DIR=/tmp/decoy scripts/21-regress.sh       # the regression suite
```

The harness runs the iOS-shaped Wine inside one macOS process, as the app
does, and is the gate for changes to the port. `20-decoy-split.sh` builds and
stages every program the suite runs: the x86-64 guests, the native ARM64
guests, the D3D11 tests and the process tests. `21-regress.sh` refuses to run
when one of them is missing, so a pass means every check ran.
`scripts/test.sh` also runs `tests/dwrite-backend-test.sh`, which checks the
static FreeType binding against a built tree and skips before setup has built
one.
