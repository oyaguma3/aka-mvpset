#!/usr/bin/env python3
"""長い時間の試験の結果をまとめる（samples.jsonl [判定に使う始めの時間（既定 6）]）。合格の基準は README。"""
import json
import sys

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    if "cg_current_mib" in r:
        rows.append(r)
begin_h = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
t0 = rows[0]["t"]
hours = lambda r: (r["t"] - t0) / 3600


def proc(r, comm, k="pss_kb"):
    return r["procs"].get(comm, {}).get(k, 0) / (1024 if k.endswith("_kb") else 1)


def series():
    s = {
        "合計 anon + kernel（MiB）": lambda r: r["cg_anon_mib"] + r["cg_kernel_mib"],
        "memory.current（MiB）": lambda r: r["cg_current_mib"],
        "file（MiB）": lambda r: r["cg_file_mib"],
    }
    for c in ("dockerd", "containerd", "containerd-shim", "radsecproxy", "radsec-edge", "radsec-edge-age", "fluent-bit"):
        s[f"{c} PSS（MiB）"] = lambda r, c=c: proc(r, c)
    for c in ("dockerd", "containerd"):
        s[f"{c} FD"] = lambda r, c=c: proc(r, c, "fds")
        s[f"{c} スレッド"] = lambda r, c=c: proc(r, c, "threads")
    s["ディスク containers（MiB）"] = lambda r: r["disk_containers_mib"]
    s["ディスク logs（MiB）"] = lambda r: r["disk_logs_mib"]
    s["ディスク data（MiB）"] = lambda r: r["disk_data_mib"]
    return s


def slope(xs, ys):
    n = len(xs)
    if n < 2:
        return 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    d = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / d if d else 0.0


use = [r for r in rows if hours(r) >= begin_h] or rows
print(f"標本 {len(rows)} 件、{hours(rows[-1]):.1f} 時間。増え方は {begin_h:g} 時間以降の直線の傾き（1 日あたり）")
print(f"{'項目':<28} {'始め':>9} {begin_h:>5g}h {'終わり':>9} {'/日':>9}")
for name, f in series().items():
    first = f(rows[0])
    at = f(use[0])
    last = f(rows[-1])
    sl = slope([hours(r) for r in use], [f(r) for r in use]) * 24
    print(f"{name:<28} {first:>9.1f} {at:>7.1f} {last:>9.1f} {sl:>9.1f}")

g = slope([hours(r) for r in use], [r["cg_anon_mib"] + r["cg_kernel_mib"] for r in use]) * 24
print()
print(f"判定: 合計の増え方 {g:.1f} MiB/日 → " + ("30 MiB/日未満（24 時間で終える）" if g < 30 else "30 MiB/日以上（72 時間に延ばす）" if hours(rows[-1]) < 48 else ("37 MiB/日以下" if g <= 37 else "37 MiB/日を超える（確認事項にする）")))
print(f"memory.current の最大 {max(r['cg_current_mib'] for r in rows):.0f} MiB（目安 2355 MiB = 2.3 GiB）")
last = rows[-1]
ap, run, up = last.get("ap", {}), last.get("run", {}), last.get("upstream", {})
print("AP:", ap)
print("中央の代わり:", run)
print("上流:", up)
cpu = (rows[-1]["cpu_usec"] - rows[0]["cpu_usec"]) / 1e6 / max(1, rows[-1]["t"] - rows[0]["t"])
print(f"dind の CPU の平均 {cpu * 100:.1f} %（1 コア = 100 %）")
print(f"コンテナ: {min(r['running'] for r in rows)}〜{max(r['running'] for r in rows)}")
print(f"接続の最小（10 分目以降）: {min(r['ap'].get('connected', 0) for r in rows[1:]) if len(rows) > 1 else '-'}")
days = max(0.01, (rows[-1]["t"] - rows[0]["t"]) / 86400)
logs = (rows[-1]["disk_logs_mib"] - rows[0]["disk_logs_mib"]) / days
print(f"Fluent Bit のファイル: {logs:.0f} MiB/日 → 2 週間で {logs * 14 / 1024:.1f} GiB（圧縮の前）。dual logging のキャッシュは 150 × 20 MiB = 最大 2.9 GiB")
print(f"ログの行: {last['log_lines']}、接続の行: {last['log_up_lines']}、AP の接続の数: {ap.get('connects')}")
