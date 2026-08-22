#!/usr/bin/env python3
"""Derive task_struct field offsets from the device's own BTF blob.

No tracepoint on this kernel carries a numeric uclamp value -- all 1932 of them
were searched, see data/2026-08-22/s2a-tracing-capability.txt. The only way to
read requested and effective uclamp at the instant of a placement is a kprobe
that dereferences the task_struct argument, and this kernel rejects BTF-typed
kprobe arguments (`$arg1->pid`), so the probe needs literal byte offsets.

A literal byte offset that came from a guess, a blog post, or another kernel is
a magic number that will silently read the wrong field. This derives them from
/sys/kernel/btf/vmlinux on the device the probe will run on:

    adb shell 'su -c "cat /sys/kernel/btf/vmlinux > /data/local/tmp/vmlinux.btf"'
    adb pull /data/local/tmp/vmlinux.btf
    tools/btf-offsets.py vmlinux.btf

Re-run it after any kernel update. The offsets are not portable across builds.
"""

import struct
import sys

# vlen-dependent trailing bytes per BTF kind (include/uapi/linux/btf.h)
TRAIL = {
    1: lambda v: 4, 2: lambda v: 0, 3: lambda v: 12, 4: lambda v: 12 * v,
    5: lambda v: 12 * v, 6: lambda v: 8 * v, 7: lambda v: 0, 8: lambda v: 0,
    9: lambda v: 0, 10: lambda v: 0, 11: lambda v: 0, 12: lambda v: 0,
    13: lambda v: 8 * v, 14: lambda v: 4, 15: lambda v: 12 * v, 16: lambda v: 0,
    17: lambda v: 4 * v, 18: lambda v: 0, 19: lambda v: 8 * v,
}
WANTED = {
    "task_struct": ("pid", "tgid", "comm", "prio", "uclamp_req", "uclamp"),
    "uclamp_se": None,  # every member
}


def load(path):
    d = open(path, "rb").read()
    magic, _ver, _flags, hdr_len = struct.unpack_from("<HBBI", d, 0)
    if magic != 0xEB9F:
        sys.exit(f"{path}: not a BTF blob (magic {magic:#x})")
    type_off, type_len, str_off, str_len = struct.unpack_from("<IIII", d, 8)
    strs = d[hdr_len + str_off: hdr_len + str_off + str_len]

    def name(o):
        return "" if o == 0 else strs[o: strs.index(b"\0", o)].decode()

    out = {}
    off, end = hdr_len + type_off, hdr_len + type_off + type_len
    while off < end:
        name_off, info, size = struct.unpack_from("<III", d, off)
        vlen, kind, kflag = info & 0xFFFF, (info >> 24) & 0x1F, (info >> 31) & 1
        body, nm = off + 12, name(name_off)
        if kind in (4, 5) and nm in WANTED:
            members = []
            o = body
            for _ in range(vlen):
                m_name, _m_type, m_off = struct.unpack_from("<III", d, o)
                o += 12
                bit_size = (m_off >> 24) & 0xFF if kflag else 0
                bit_off = (m_off & 0xFFFFFF) if kflag else m_off
                members.append((name(m_name), bit_off, bit_size))
            out[nm] = (size, members)
        if kind not in TRAIL:
            break  # trailing padding after the last type
        off = body + TRAIL[kind](vlen)
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    types = load(sys.argv[1])
    for sname, (size, members) in types.items():
        keep = WANTED[sname]
        print(f"struct {sname}  size={size}")
        for mn, bit_off, bit_size in members:
            if keep is not None and mn not in keep:
                continue
            if bit_size:
                print(f"  .{mn:<12s} bit_offset={bit_off:<4d} bit_size={bit_size}")
            else:
                print(f"  .{mn:<12s} byte_offset={bit_off // 8}")
        print()
    ts = types.get("task_struct")
    us = types.get("uclamp_se")
    if ts and us:
        by = {m: o // 8 for m, o, _ in ts[1]}
        w = us[0]  # sizeof(struct uclamp_se)
        print("kprobe fetch arguments for this kernel:")
        print(f"  tpid=+{by['pid']}($arg1):s32")
        print(f"  req_min=+{by['uclamp_req']}($arg1):x32   "
              f"req_max=+{by['uclamp_req'] + w}($arg1):x32")
        print(f"  eff_min=+{by['uclamp']}($arg1):x32   "
              f"eff_max=+{by['uclamp'] + w}($arg1):x32")
        bits = {m: (o, s) for m, o, s in us[1]}
        print("decode each x32 as struct uclamp_se:")
        for m in ("value", "bucket_id", "active", "user_defined"):
            if m in bits:
                o, s = bits[m]
                print(f"  {m:<12s} = (raw >> {o}) & {hex((1 << s) - 1)}")


if __name__ == "__main__":
    main()
