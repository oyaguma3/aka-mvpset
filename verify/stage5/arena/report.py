#!/usr/bin/env python3
"""radsecproxy のメモリーの実験（確認事項 T5-20）のまとめ。  report.py <samples.jsonl> [ap-status.json]
変種（既定・MALLOC_ARENA_MAX=2・=1）ごとに 2 個の平均を、15 分ごとと最後に出し、時間あたりの増え方を比べる。
実験のつなぎ直しはテナントあたり毎秒 1 本で、150 テナントの試験（毎秒 1 本を 740 本に。テナントあたり約 1/148 本/秒）の約 148 倍。
"""
import json
import sys
from collections import defaultdict

ACCEL = 148
s = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
s = [d for d in s if d["procs"]]
t0 = s[0]["t"]


def by_variant(d):
    v = defaultdict(list)
    for p in d["procs"].values():
        v[p["variant"]].append(p)
    return {k: {f: sum(p[f] for p in ps) / len(ps) for f in ("pss_kb", "anon_kb", "heap_kb", "arenas", "threads", "conns")} | {"n": len(ps)} for k, ps in v.items()}


variants = sorted({p["variant"] for d in s for p in d["procs"].values()}, key=lambda x: (x != "既定", x))
print("経過(分)  " + "  ".join(f"{v:>4}: PSS KiB / anon / arena / thr" for v in variants))
for d in s:
    m = (d["t"] - t0) // 60
    if m % 15 and d is not s[-1]:
        continue
    b = by_variant(d)
    print(f"{m:8d}  " + "  ".join(f"{b[v]['pss_kb']:8.0f} / {b[v]['anon_kb']:5.0f} / {b[v]['arenas']:4.1f} / {b[v]['threads']:4.1f}" if v in b else " " * 30 for v in variants))


def slope(pts):
    n = len(pts)
    mx = sum(x for x, _ in pts) / n
    my = sum(y for _, y in pts) / n
    den = sum((x - mx) ** 2 for x, _ in pts)
    return sum((x - mx) * (y - my) for x, y in pts) / den if den else 0.0


hours = (s[-1]["t"] - t0) / 3600
print(f"\n記録 {len(s)} 件、{hours:.1f} 時間（150 テナントの試験の約 {hours * ACCEL / 24:.0f} 日分のつなぎ直し）")
for v in variants:
    pts = [((d["t"] - t0) / 3600, by_variant(d)[v]["pss_kb"] / 1024) for d in s if v in by_variant(d)]
    half = [p for p in pts if p[0] >= hours / 2]
    first, last = by_variant(s[0]).get(v, {}), by_variant(s[-1]).get(v, {})
    print(f"  {v}: PSS {first.get('pss_kb', 0) / 1024:.2f} → {last.get('pss_kb', 0) / 1024:.2f} MiB、arena {first.get('arenas', 0):.1f} → {last.get('arenas', 0):.1f}、"
          f"増え方 全体 {slope(pts):+.3f} MiB/時・後半 {slope(half) if len(half) > 1 else 0:+.3f} MiB/時")
if len(sys.argv) > 2:
    try:
        print("AP の役:", json.load(open(sys.argv[2], encoding="utf-8")))
    except FileNotFoundError:
        pass
