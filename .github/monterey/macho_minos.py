#!/usr/bin/env python3
"""Scan files/dirs (or tar members) for Mach-O and print arch + minos (LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX)."""
import os,struct,sys,tarfile,io
CPU={0x01000007:'x86_64',0x0100000c:'arm64',7:'i386'}
def ver(v): return f"{v>>16}.{(v>>8)&0xff}" + (f".{v&0xff}" if v&0xff else "")
def thin(b,off=0):
  magic=struct.unpack_from('<I',b,off)[0]
  if magic not in (0xfeedfacf,0xfeedface): return None
  cpu,_,ftype,ncmds,_=struct.unpack_from('<iiIII',b,off+4)
  p=off+(32 if magic==0xfeedfacf else 28); mn=None
  for _ in range(ncmds):
    cmd,sz=struct.unpack_from('<II',b,p)
    if cmd==0x32: mn=ver(struct.unpack_from('<I',b,p+12)[0])
    elif cmd==0x24: mn=ver(struct.unpack_from('<I',b,p+8)[0])
    p+=sz
    if sz==0: break
  return (CPU.get(cpu & 0xffffffff,hex(cpu&0xffffffff)),mn)
def analyze(b):
  if len(b)<32: return None
  m=struct.unpack_from('>I',b,0)[0]
  if m in (0xcafebabe,):
    n=struct.unpack_from('>I',b,4)[0]
    if n>30: return None  # java class
    res=[]
    for i in range(n):
      _,_,o,_,_=struct.unpack_from('>iiIII',b,8+i*20); r=thin(b,o)
      if r: res.append(r)
    return res
  r=thin(b); return [r] if r else None
def key(v): return tuple(int(x) for x in v.split('.')) if v else (0,)
def report(name,b,limit,bad):
  r=analyze(b)
  if not r: return 0
  flag=any(key(mn)>key(limit) for _,mn in r) or any(a!='x86_64' for a,_ in r)
  if flag: bad.append(name)
  if flag or os.environ.get('VERBOSE'): print(('BAD ' if flag else 'ok  ')+name, r)
  return 1
def main():
  limit=os.environ.get('LIMIT','12.0'); bad=[]; n=0
  for t in sys.argv[1:]:
    if t.endswith(('.tar.gz','.tgz','.tar.xz')):
      with tarfile.open(t) as tf:
        for m in tf:
          if m.isfile() and m.size>=32:
            f=tf.extractfile(m); h=f.read(4)
            if h in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe'): n+=report(t+'!'+m.name,h+f.read(),limit,bad)
      continue
    for root,ds,fs in os.walk(t) if os.path.isdir(t) else [('',[],[t])]:
      for fn in fs:
        p=os.path.join(root,fn)
        if os.path.islink(p) or not os.path.isfile(p): continue
        with open(p,'rb') as f: h=f.read(4)
        if h in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe'):
          n+=report(p,open(p,'rb').read(),limit,bad)
  print(f"Mach-O files: {n}; exceeding minos {limit} or non-x86_64: {len(bad)}")
main()
