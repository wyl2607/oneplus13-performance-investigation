#!/usr/bin/env python3
"""Redact third-party thread names out of a raw ftrace capture before committing.

The tracer filters events by pid, but an ftrace line is still stamped with
whoever was running when it fired, and sched_switch names the task on the other
side of the switch. On a real phone that turns a trace of one synthetic worker
into a list of the owner's installed applications -- this repository's first S2a
capture carried Outlook, ChatGPT, TikTok and an authenticator app in the context
column alone.

Kernel threads and the workers under study are kept, because they are what the
analysis talks about. Every other userspace comm becomes app-<pid>, so wake
relationships and pid identity survive and the name does not.

usage:
    redact-trace.py FILE [FILE ...]        rewrites in place
    redact-trace.py --check FILE [...]     lists what would be redacted
"""

import re
import sys

KEEP = re.compile(
    r"^(<idle>|swapper/\d+|kworker/\S*|migration/\d+|ksoftirqd/\d+|rcu_\S*|"
    r"irq/\S*|kthreadd|kcompactd\d*|khugepaged|kswapd\d*|watchdog/\d+|"
    r"w-wake|w-continuous|uclampset|sh|sleep|su)$"
)
CTX = re.compile(r"^(\s*)(\S.*?)-(\d+)(\s+\[\d+\])")
FIELDS = [
    re.compile(r"(?<= )(prev_comm)=(.*?)(?= prev_pid=)"),
    re.compile(r"(?<= )(next_comm)=(.*?)(?= next_pid=)"),
    re.compile(r"(?<= )(comm)=(\S*)(?= pid=)"),
]


def sub_name(name, pid):
    return name if KEEP.match(name.strip()) else f"app-{pid}"


def redact(text, found):
    out = []
    for ln in text.splitlines(True):
        if ln.startswith("#"):
            out.append(ln)
            continue
        m = CTX.match(ln)
        pid = "0"
        if m:
            name, pid = m.group(2).strip(), m.group(3)
            new = sub_name(name, pid)
            if new != name:
                found.add(name)
                ln = f"{m.group(1)}{new:>15s}-{pid}{m.group(4)}" + ln[m.end(4):]
        for rx in FIELDS:
            def rep(mm, _pid=pid):
                nm = mm.group(2)
                # pair the comm with the pid that follows it on the same line
                tail = mm.string[mm.end():]
                pm = re.match(r"\s*(?:prev_pid|next_pid|pid)=(\d+)", tail)
                p = pm.group(1) if pm else _pid
                new = sub_name(nm, p)
                if new != nm:
                    found.add(nm)
                return f"{mm.group(1)}={new}"
            ln = rx.sub(rep, ln)
        out.append(ln)
    return "".join(out)


def main():
    args = sys.argv[1:]
    check = "--check" in args
    files = [a for a in args if a != "--check"]
    if not files:
        sys.exit(__doc__)
    for path in files:
        text = open(path, encoding="utf-8", errors="replace").read()
        found = set()
        new = redact(text, found)
        if check:
            print(f"{path}: {len(found)} distinct names would be redacted")
            for n in sorted(found)[:20]:
                print(f"    {n}")
        else:
            open(path, "w", encoding="utf-8").write(new)
            print(f"{path}: redacted {len(found)} distinct names")


if __name__ == "__main__":
    main()
