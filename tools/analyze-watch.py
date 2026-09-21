#!/usr/bin/env python3
"""Summarise a gb7-watch.sh trace: per-cluster residency at ceiling, thermal, step-downs."""
import sys, statistics as st

path = sys.argv[1]
rows, head = [], []
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("#") or line.startswith("###"):
            head.append(line); continue
        if line.startswith("ts|"): continue
        p = line.split("|")
        if len(p) < 15: continue
        try:
            rows.append(dict(
                ts=int(p[0]), c=[int(x) for x in p[1:9]],
                p0max=int(p[9]), p6max=int(p[10]),
                junc=int(p[11]), shell=int(p[12]),
                cfb=p[13], cool=p[14]))
        except ValueError:
            continue

if not rows:
    print("no samples"); sys.exit(1)

for h in head:
    if not h.startswith("###"): print(h)

t0, t1 = rows[0]["ts"], rows[-1]["ts"]
print(f"samples={len(rows)}  span={t1-t0}s")

# busy = any core above its cluster idle floor
MID_IDLE, PRIME_IDLE = 1152000, 1017600
busy = [r for r in rows if max(r["c"][6:8]) > PRIME_IDLE or max(r["c"][0:6]) > MID_IDLE]
print(f"busy samples={len(busy)} ({100*len(busy)/len(rows):.1f}%)")

def summarise(name, rs):
    if not rs: print(f"{name}: none"); return
    p6 = [max(r["c"][6:8]) for r in rs]
    p0 = [max(r["c"][0:6]) for r in rs]
    j  = [r["junc"]/1000 for r in rs]
    sh = [r["shell"]/1000 for r in rs]
    at6 = sum(1 for r in rs if max(r["c"][6:8]) >= r["p6max"])
    at0 = sum(1 for r in rs if max(r["c"][0:6]) >= r["p0max"])
    cool = sum(1 for r in rs if r["cool"] == "yes")
    cfb1 = sum(1 for r in rs if r["cfb"] == "1")
    print(f"{name}: n={len(rs)}")
    print(f"  prime max-of-pair  mean {st.mean(p6)/1e6:.3f} GHz   at-ceiling {100*at6/len(rs):.1f}%")
    print(f"  mid   max-of-six   mean {st.mean(p0)/1e6:.3f} GHz   at-ceiling {100*at0/len(rs):.1f}%")
    print(f"  junction  med {st.median(j):.1f}  p95 {sorted(j)[int(.95*len(j))-1]:.1f}  max {max(j):.1f} C")
    print(f"  shell     max {max(sh):.1f} C")
    print(f"  stepped-down {100*cool/len(rs):.1f}% of samples   cfb=1 in {100*cfb1/len(rs):.1f}%")

summarise("ALL", rows)
summarise("BUSY", busy)

# phase split: multi-core = >=4 mid cores above idle
multi = [r for r in busy if sum(1 for x in r["c"][0:6] if x > MID_IDLE) >= 4]
single = [r for r in busy if r not in multi]
summarise("SINGLE-ish (<4 mid cores busy)", single)
summarise("MULTI-ish  (>=4 mid cores busy)", multi)

# ceiling changes
prev = None
for r in rows:
    key = (r["p0max"], r["p6max"])
    if key != prev:
        print(f"  t+{r['ts']-t0:5d}s  ceilings -> p0={r['p0max']} p6={r['p6max']}  junc={r['junc']/1000:.1f}C")
        prev = key

for h in head:
    if h.startswith("###"): print(h)
