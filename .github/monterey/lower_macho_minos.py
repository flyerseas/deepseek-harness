#!/usr/bin/env python3
"""Lower LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX minos on Mach-O files (never raise).

Used for optional natives we cannot conveniently rebuild (e.g. sherpa-onnx.node).
Prefer rebuilding with MACOSX_DEPLOYMENT_TARGET for code we control.
"""
from __future__ import annotations
import os, struct, sys

MH_MAGIC_64, MH_CIGAM_64 = 0xFEEDFACF, 0xCFFAEDFE
MH_MAGIC, MH_CIGAM = 0xFEEDFACE, 0xCEFAEDFE
FAT_MAGIC, FAT_CIGAM = 0xCAFEBABE, 0xBEBAFECA
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24


def pack_ver(s: str) -> int:
  parts = [int(x) for x in s.split('.')]
  while len(parts) < 3:
    parts.append(0)
  maj, minor, patch = parts[:3]
  return (maj << 16) | (minor << 8) | patch


def unpack_ver(v: int) -> str:
  maj, minor, patch = v >> 16, (v >> 8) & 0xFF, v & 0xFF
  return f'{maj}.{minor}' + (f'.{patch}' if patch else '')


def ver_key(s: str) -> tuple:
  parts = [int(x) for x in s.split('.')]
  while len(parts) < 3:
    parts.append(0)
  return tuple(parts[:3])


def patch_thin(buf: bytearray, off: int, target: int, path: str, changes: list) -> None:
  magic = struct.unpack_from('<I', buf, off)[0]
  if magic not in (MH_MAGIC_64, MH_MAGIC):
    # big-endian rare on mac; skip
    return
  is64 = magic == MH_MAGIC_64
  ncmds = struct.unpack_from('<I', buf, off + 16)[0]
  p = off + (32 if is64 else 28)
  for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', buf, p)
    if sz < 8:
      break
    if cmd == LC_BUILD_VERSION and sz >= 24:
      cur = struct.unpack_from('<I', buf, p + 12)[0]
      if cur > target:
        changes.append((path, 'LC_BUILD_VERSION', unpack_ver(cur), unpack_ver(target)))
        struct.pack_into('<I', buf, p + 12, target)
    elif cmd == LC_VERSION_MIN_MACOSX and sz >= 16:
      cur = struct.unpack_from('<I', buf, p + 8)[0]
      if cur > target:
        changes.append((path, 'LC_VERSION_MIN_MACOSX', unpack_ver(cur), unpack_ver(target)))
        struct.pack_into('<I', buf, p + 8, target)
    p += sz


def patch_file(path: str, target_s: str) -> list:
  target = pack_ver(target_s)
  with open(path, 'rb') as f:
    data = bytearray(f.read())
  if len(data) < 8:
    return []
  changes: list = []
  magic_be = struct.unpack_from('>I', data, 0)[0]
  magic_le = struct.unpack_from('<I', data, 0)[0]
  if magic_be in (FAT_MAGIC, FAT_CIGAM):
    nfat = struct.unpack_from('>I', data, 4)[0]
    if nfat > 30:
      return []
    for i in range(nfat):
      _cputype, _cpusub, offset, _size, _align = struct.unpack_from('>iiIII', data, 8 + i * 20)
      patch_thin(data, offset, target, path, changes)
  elif magic_le in (MH_MAGIC_64, MH_MAGIC):
    patch_thin(data, 0, target, path, changes)
  else:
    return []
  if changes:
    # break hardlinks into the pnpm store before writing
    os.chmod(path, os.stat(path).st_mode | 0o200)
    tmp = path + '.minos-tmp'
    with open(tmp, 'wb') as f:
      f.write(data)
    os.replace(tmp, path)
  return changes


def main() -> int:
  if len(sys.argv) < 3:
    print(f'usage: {sys.argv[0]} TARGET_MINOS path [path ...]', file=sys.stderr)
    return 2
  target = sys.argv[1]
  ver_key(target)  # validate
  all_changes = []
  for arg in sys.argv[2:]:
    if os.path.isdir(arg):
      for root, _ds, fs in os.walk(arg):
        for fn in fs:
          p = os.path.join(root, fn)
          if os.path.islink(p) or not os.path.isfile(p):
            continue
          with open(p, 'rb') as f:
            h = f.read(4)
          if h in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
            all_changes.extend(patch_file(p, target))
    elif os.path.isfile(arg):
      all_changes.extend(patch_file(arg, target))
    else:
      print(f'skip missing: {arg}', file=sys.stderr)
  for path, kind, old, new in all_changes:
    print(f'lowered {kind} {old} -> {new}: {path}')
  print(f'files changed: {len({c[0] for c in all_changes})}; load-command edits: {len(all_changes)}')
  return 0


if __name__ == '__main__':
  raise SystemExit(main())
