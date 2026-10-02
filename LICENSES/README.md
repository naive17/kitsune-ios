# Licenses

The app bundles this directory. Each shipped component and the text of its
license:

| Component | License | Text |
|---|---|---|
| Kitsune: the app, its tools, and this port's changes to Wine, DXMT and FEX | GPL-3.0-or-later | GPL-3.0-or-later.txt |
| Madeira (code adapted in this port's changes to Wine and DXMT, listed below) | GPL-3.0-or-later for the DXMT parts; LGPL-2.1-or-later for the Wine parts | GPL-3.0-or-later.txt, LGPL-2.1.txt |
| Wine | LGPL-2.1-or-later | LGPL-2.1.txt |
| DXMT | MIT | MIT-DXMT.txt |
| bcdec (vendored in the DXMT port) | MIT | MIT-bcdec.txt |
| etcpak (vendored in the DXMT port) | BSD-3-Clause | BSD-3-Clause-etcpak.txt |
| LLVM 15 (IR and bitcode libraries in winemetal.so) | Apache-2.0 WITH LLVM-exception | Apache-2.0-WITH-LLVM-exception.txt |
| FEX | MIT | MIT-FEX.txt |
| DXVK (d3d9) | zlib | Zlib-DXVK.txt |
| vkd3d-proton (d3d12) | LGPL-2.1-or-later | LGPL-2.1.txt |
| FreeType 2.13.3 (linked into win32u) | FreeType License | FTL-FreeType.txt |
| GnuTLS 3.8.9 (libgnutls.30.dylib) | LGPL-2.1-or-later | LGPL-2.1.txt |
| nettle 3.10.1, GMP 6.3.0 (linked into libgnutls) | LGPL-3.0-or-later (elected from LGPL-3.0+ or GPL-2.0+) | LGPL-3.0.txt |
| LLVM runtime libraries from llvm-mingw (in the PE modules) | Apache-2.0 WITH LLVM-exception | Apache-2.0-WITH-LLVM-exception.txt |
| LZMA SDK decoder (src/lzma) | Public domain | none |
| Mozilla CA bundle | MPL-2.0 | ../assets/ca-bundle-NOTICE.txt |

Portions of this software are copyright © The FreeType Project
(https://freetype.org). All rights reserved.

## Code adapted from Madeira

Parts of this port are adapted from [Madeira](https://github.com/willfaust/Madeira)
and its forks, Copyright © 2026 Will Faust, and 125hz where noted. Each is
marked where it sits in the code and in its patch's message.

| What | Patch | From | License |
|---|---|---|---|
| Managed storage as Shared on iOS | patches/dxmt 0005 | willfaust/dxmt d7ffd08 | GPL-3.0-or-later |
| BC textures decoded at upload | patches/dxmt 0007 | willfaust/dxmt bc6d4c7 | GPL-3.0-or-later |
| Uncompressed fallback for BC formats, upload pitch check | patches/dxmt 0009 | willfaust/dxmt ec30e12 | GPL-3.0-or-later |
| TCP state numbering on Apple systems | patches/wine 0001 | willfaust/wine d3d5a179a5 | LGPL-2.1-or-later |
| Per-process fd cache | patches/wine 0006 | willfaust/Madeira 9dc2324 | LGPL-2.1-or-later |
| Soft pools for CEF | patches/wine 0008 | willfaust/Madeira 69496fd | LGPL-2.1-or-later |
| NSI served in process (the missing-device cache by 125hz) | patches/wine 0019 | willfaust/wine d3d5a179a5, 5c4d1f7a6f | LGPL-2.1-or-later |
| QueryPerformanceCounter in user mode | patches/wine 0022 | willfaust/wine e828644329 | LGPL-2.1-or-later |
