import sys, os, statistics as st
from collections import Counter, defaultdict

D=sys.argv[1]
def parse(path):
    wins={}; threads=defaultdict(list); meta=None; events=[]
    for line in open(path):
        line=line.rstrip("\n")
        if line.startswith("META|"): meta=line
        elif line.startswith("EVENT|"): events.append(line)
        elif line.startswith("WINDOW|"):
            kv=dict(p.split("=",1) for p in line.split("|")[1:] if "=" in p)
            wins[int(kv["seq"])]=kv
        elif line.startswith("THREAD|"):
            f=line.split("|")
            if len(f)<20: continue
            threads[int(f[1])].append(dict(rank=int(f[2]),tgid=f[3],tid=f[4],uid=f[5],comm=f[6],
                rt=float(f[7]),pct=float(f[8]),wait=float(f[9]),slices=int(f[10]),
                c0=f[11],c1=f[12],allowed=f[13],umin=f[14],umax=f[15],umaxe=f[16],
                mig=f[17],vol=f[18],nvol=f[19]))
    return meta,wins,threads,events

def num(x):
    try: return float(x)
    except: return None

def report(label):
    p=os.path.join(D,label+".txt")
    if not os.path.exists(p): return
    meta,wins,threads,events=parse(p)
    walls=[int(w["wall_ms"]) for w in wins.values()]
    tot=[float(w["total_runtime_ms"]) for w in wins.values()]
    busy=[int(w["busy_threads"]) for w in wins.values()]
    nthr=[int(w["threads"]) for w in wins.values()]
    print(f"\n{'='*78}\n{label.upper()}   windows={len(wins)} events={len(events)} "
          f"median_wall={st.median(walls):.0f}ms  threads_scanned~{st.median(nthr):.0f}")
    # only windows that actually did work
    act=[s for s in wins if float(wins[s]["total_runtime_ms"])>1.0]
    print(f"  windows with >1ms of top-app CPU: {len(act)}/{len(wins)}"
          f"   busy_threads/window median={st.median(busy):.0f} p90={sorted(busy)[int(.9*len(busy))]}")
    if not act: print("  (idle trace)"); return
    # concentration
    c1=[];c2=[];n5=[];n10=[]
    for s in act:
        T=sorted(threads.get(s,[]),key=lambda x:-x["rt"])
        if not T: continue
        total=float(wins[s]["total_runtime_ms"])
        if total<=0: continue
        c1.append(T[0]["rt"]/total*100)
        c2.append(sum(t["rt"] for t in T[:2])/total*100)
        n5.append(sum(1 for t in T if t["rt"]/total*100>=5))
        n10.append(sum(1 for t in T if t["rt"]/total*100>=10))
    print(f"  CONCENTRATION  rank1 share of window CPU: median={st.median(c1):.0f}%  "
          f"p25={sorted(c1)[len(c1)//4]:.0f}%  p75={sorted(c1)[3*len(c1)//4]:.0f}%")
    print(f"                 top-2 share:              median={st.median(c2):.0f}%")
    print(f"                 threads holding >=10% of the window: median={st.median(n10):.0f}  "
          f">=5%: median={st.median(n5):.0f}")
    print(f"                 windows where top-2 >= 80% of CPU: {sum(1 for v in c2 if v>=80)}/{len(c2)}"
          f" ({100*sum(1 for v in c2 if v>=80)/len(c2):.0f}%)")
    # stability of rank1
    seq=sorted(act)
    r1=[(s,sorted(threads.get(s,[]),key=lambda x:-x["rt"])[0]) for s in seq if threads.get(s)]
    tids=[t["tid"] for _,t in r1]
    same=sum(1 for i in range(1,len(tids)) if tids[i]==tids[i-1])
    print(f"  STABILITY      distinct rank1 TIDs={len(set(tids))} over {len(tids)} active windows; "
          f"consecutive-window persistence={100*same/max(1,len(tids)-1):.0f}%")
    for tid,c in Counter((t['comm'],t['tid']) for _,t in r1).most_common(4):
        print(f"                 {c:4d}x  {tid[0]:22s} tid={tid[1]}")
    # placement
    cpu=Counter(t["c1"] for _,t in r1)
    prime=sum(v for k,v in cpu.items() if k in("6","7")); mid=sum(v for k,v in cpu.items() if k in list("012345"))
    print(f"  PLACEMENT      rank1 cpu_end: mid(0-5)={mid} prime(6-7)={prime}  "
          f"prime share={100*prime/max(1,mid+prime):.0f}%   detail={dict(sorted(cpu.items()))}")
    # placement of all reported threads
    allc=Counter(t["c1"] for s in act for t in threads.get(s,[]))
    ap=sum(v for k,v in allc.items() if k in("6","7")); am=sum(v for k,v in allc.items() if k in list("012345"))
    print(f"                 all ranked rows:  mid={am} prime={ap}  prime share={100*ap/max(1,am+ap):.0f}%")
    # runq wait
    w1=[t["wait"] for _,t in r1]
    wp=[t["wait"] for _,t in r1 if t["c1"] in ("6","7")]
    wm=[t["wait"] for _,t in r1 if t["c1"] in list("012345")]
    print(f"  RUNQ WAIT      rank1 median={st.median(w1):.3f}ms p90={sorted(w1)[int(.9*len(w1))]:.3f}ms "
          f"max={max(w1):.3f}ms")
    if wp and wm:
        print(f"                 by placement: mid median={st.median(wm):.3f}ms (n={len(wm)})  "
              f"prime median={st.median(wp):.3f}ms (n={len(wp)})")
    # uclamp
    umax=Counter(t["umax"] for _,t in r1); umaxe=Counter(t["umaxe"] for _,t in r1)
    clamped=sum(v for k,v in umax.items() if k not in ("1024","NA"))
    clampede=sum(v for k,v in umaxe.items() if k not in ("1024","NA"))
    print(f"  UCLAMP         rank1 uclamp_max != 1024 in {clamped}/{len(r1)} windows  "
          f"effective != 1024 in {clampede}/{len(r1)}")
    if clamped: print(f"                 requested values: {dict(umax)}")
    if clampede: print(f"                 effective values: {dict(umaxe)}")
    umin=Counter(t["umin"] for _,t in r1)
    print(f"                 uclamp_min values on rank1: {dict(umin)}")
    # migration proxy: cpu_start != cpu_end within a window
    mv=sum(1 for _,t in r1 if t["c0"]!=t["c1"])
    print(f"  MOVEMENT       rank1 cpu_start != cpu_end in {mv}/{len(r1)} windows ({100*mv/len(r1):.0f}%)")

for lab in ["launch","scroll","scroll-off","switch","wake","wake-off","compute","compute-off","uclamp-attribution"]:
    report(lab)
