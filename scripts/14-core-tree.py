#!/usr/bin/env python3
"""Copy out/wine-tree to out/wine-core, the Wine tree the app ships.

Usage: python3 scripts/14-core-tree.py [TREE [DEST]]

Every PE module is copied: a program that needs a missing one exits with
c0000135 and no crash report. 15-dxmt-ios.sh, 17-prefix-template.sh and
18-stamp-tree.sh then add to out/wine-core.
"""
import os
import shutil
import sys

TREE = sys.argv[1] if len(sys.argv) > 1 else "out/wine-tree"
DEST = sys.argv[2] if len(sys.argv) > 2 else "out/wine-core"
PARTS = ("lib/wine/aarch64-windows", "lib/wine/aarch64-unix", "share/wine")


def main():
    pe = os.path.join(TREE, PARTS[0])
    if not os.path.isdir(pe):
        sys.exit(f"no PE dir at {pe}")

    # Start from an empty DEST: a stale module from an earlier run would still
    # load.
    if os.path.isdir(DEST):
        shutil.rmtree(DEST)
    for part in PARTS:
        shutil.copytree(os.path.join(TREE, part), os.path.join(DEST, part))

    modules = len(os.listdir(os.path.join(DEST, PARTS[0])))
    total = sum(os.path.getsize(os.path.join(root, f))
                for root, _, files in os.walk(DEST) for f in files)
    print(f"PE modules     : {modules}")
    print(f"core tree size : {total/1048576:.0f} MB  -> {DEST}")


if __name__ == "__main__":
    main()
