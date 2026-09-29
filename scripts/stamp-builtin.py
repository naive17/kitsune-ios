#!/usr/bin/env python3
"""Stamp PE files as Wine builtin DLLs.  Usage: stamp-builtin.py FILE...

Wine treats a DLL as builtin only if winebuild's 32-byte signature is at offset
64 (tools/winebuild/spec32.c). DXMT's DLLs lack it, so each one must be stamped.
"""
import sys

SIG = b"Wine builtin DLL".ljust(32, b"\0")

for path in sys.argv[1:]:
    with open(path, "r+b") as f:
        head = f.read(64)
        if head[:2] != b"MZ":
            sys.exit(f"{path}: not a PE")
        e_lfanew = int.from_bytes(head[60:64], "little")
        if e_lfanew < 64 + len(SIG):
            sys.exit(f"{path}: no room for signature (e_lfanew={e_lfanew:#x})")
        f.seek(64)
        f.write(SIG)
    print(f"stamped {path}")
