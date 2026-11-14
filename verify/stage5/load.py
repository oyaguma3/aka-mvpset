#!/usr/bin/env python3
"""150 テナントの試験（確認事項 T5-7〜T5-9）の手元の補助。drive.sh の load-* の段から呼ぶ。
  load.py tenants <状態.tsv> <数> <出力.json>                        … まだないテナントを作る要求
  load.py setup <状態.tsv> <csr.json> <エッジ> <出力の接頭辞> <束の数>  … 有効化・AP・配置の要求（テナントごとにまとめて束に分ける）
  load.py certs <証明書.tsv> <出力の接頭辞> <束の数>                  … サーバー CA と AP の証明書を取る要求
  load.py save-certs <証明書.tsv> <結果.json>... <pki のディレクトリ>  … 取った PEM を保存する
  load.py aps <証明書.tsv> <検証機の pki のディレクトリ>              … load-ap.py の aps.txt を出す
  load.py result <結果.json>...                                       … 状態の番号を数え、失敗を出す
  load.py report <samples.jsonl> <ap-status.jsonl> <始めた時刻>        … 増え方と最大を出して判定する（T5-9）
状態.tsv は psql -At の行（id|name|slug|AP の名前のカンマ区切り|配置の数）。証明書.tsv は（name|id|port|AP の名前|AP の ID|シリアル）。
"""
import json
import sys
import uuid

APS = ("ap1", "ap2", "ap3", "ap4", "ap5")


def rows(path):
    return [l.rstrip("\n").split("|") for l in open(path, encoding="utf-8") if l.strip()]


def dump(path, reqs):
    json.dump(reqs, open(path, "w", encoding="utf-8"), ensure_ascii=False)


def tenants(state, n, out):
    have = {r[1] for r in rows(state)}
    dump(out, [{"m": "POST", "p": "/tenants", "f": {"name": f"ld{i:03d}"}} for i in range(1, int(n) + 1) if f"ld{i:03d}" not in have])


def setup(state, csrs, edge, prefix, per):
    csr = json.load(open(csrs, encoding="utf-8"))
    groups = []
    for tid, name, slug, aps, placements in rows(state):
        g = []
        if not slug:
            g.append({"m": "POST", "p": f"/tenants/{tid}/radsec/enable", "f": {"slug": name, "idem": str(uuid.uuid4())}})
        have = set(filter(None, aps.split(",")))
        for a in APS:
            if a not in have:
                g.append({"m": "POST", "p": f"/tenants/{tid}/aps", "f": {"name": a, "kind": "ap", "purpose": "other", "csr": csr[f"{name}-{a}"], "idem": str(uuid.uuid4())}})
        # 配置は AP を登録した後に足す（新しい配置の最初の反映に全部の AP が入る。OB1）
        if placements == "0":
            g.append({"m": "POST", "p": f"/tenants/{tid}/radsec/placements", "f": {"slot": "primary", "edge": edge}})
        if g:
            groups.append(g)
    chunks, cur = [], []
    for g in groups:
        if cur and len(cur) + len(g) > int(per):
            chunks.append(cur)
            cur = []
        cur += g
    if cur:
        chunks.append(cur)
    for i, c in enumerate(chunks, 1):
        dump(f"{prefix}{i:03d}.json", c)
    print(f"{sum(len(g) for g in groups)} 件を {len(chunks)} 束に（テナント {len(groups)}）")


def clean(state, phase, prefix, per):
    """片付け（T5-12）の要求。state の 1 行は <テナントの ID>|<名前>|<AP の ID,...>|<外していない配置の ID,...>|<エッジから消し終えていない配置の数>。
    phase detach: 配置を外し（ループがエッジから消す）、AP を削除する（有効な証明書は画面が cessationOfOperation で失効させる）。
    phase delete: AP も配置も残っていないテナントを削除する（ポートが空き、テナントの CA が止まる）。"""
    reqs = []
    for tid, name, aps, pids, live in rows(state):
        if phase == "detach":
            reqs += [{"m": "POST", "p": f"/tenants/{tid}/radsec/placements/{p}/remove", "f": {}} for p in filter(None, pids.split(","))]
            reqs += [{"m": "POST", "p": f"/tenants/{tid}/aps/{a}/delete", "f": {}} for a in filter(None, aps.split(","))]
        elif not aps and not pids and live == "0":
            reqs.append({"m": "POST", "p": f"/tenants/{tid}/delete", "f": {}})
    per = int(per)
    for i in range(0, len(reqs), per):
        dump(f"{prefix}{i // per + 1:03d}.json", reqs[i:i + per])
    print(f"{len(reqs)} 件を {(len(reqs) + per - 1) // per} 束に")


def certs(path, prefix, per):
    reqs, seen = [], set()
    for name, tid, port, ap, apid, serial in rows(path):
        if tid not in seen:
            seen.add(tid)
            reqs.append({"m": "GET", "p": f"/tenants/{tid}/radsec/server-ca.pem", "keep": True, "k": f"{name}-ca"})
        reqs.append({"m": "GET", "p": f"/tenants/{tid}/aps/{apid}/certs/{serial}/pem", "keep": True, "k": f"{name}-{ap}"})
    per = int(per)
    for i in range(0, len(reqs), per):
        dump(f"{prefix}{i // per + 1:03d}.json", reqs[i:i + per])
    print(f"{len(reqs)} 件を {(len(reqs) + per - 1) // per} 束に")


def save_certs(args):
    *pairs, pki = args
    n = bad = 0
    for i in range(0, len(pairs), 2):
        reqs = json.load(open(pairs[i], encoding="utf-8"))
        res = json.load(open(pairs[i + 1], encoding="utf-8"))
        for q, r in zip(reqs, res):
            b = r.get("b", "")
            if r["s"] == 200 and b.startswith("-----BEGIN CERTIFICATE-----"):
                open(f"{pki}/{q['k']}.pem", "w", encoding="utf-8").write(b)
                n += 1
            else:
                bad += 1
                print("取れない", q["p"], r["s"], r.get("a", ""))
    print(f"保存 {n}、失敗 {bad}")
    sys.exit(1 if bad else 0)


def aps(path, rpki):
    for name, tid, port, ap, apid, serial in rows(path):
        print(port, f"{rpki}/{name}-{ap}.pem", f"{rpki}/{name}-{ap}.key", f"{rpki}/{name}-ca.pem", name, ap)


def result(paths):
    c, bad = {}, []
    for p in paths:
        for r in json.load(open(p, encoding="utf-8")):
            c[r["s"]] = c.get(r["s"], 0) + 1
            if r["s"] != 200:
                bad.append((p, r["s"], r.get("a", "")))
    print("状態の番号:", dict(sorted(c.items())))
    for b in bad[:20]:
        print("失敗", *b)
    sys.exit(1 if bad else 0)


def slope(pts):
    # 最小二乗の傾き（MiB/日）
    n = len(pts)
    if n < 2:
        return 0.0
    mx = sum(t for t, _ in pts) / n
    my = sum(v for _, v in pts) / n
    den = sum((t - mx) ** 2 for t, _ in pts)
    return sum((t - mx) * (v - my) for t, v in pts) / den * 86400 if den else 0.0


def report(samples, apstat, start):
    start = int(start)
    s = [json.loads(l) for l in open(samples, encoding="utf-8") if l.strip()]
    s = [d for d in s if d["t"] >= start]
    h = lambda d: (d["t"] - start) / 3600
    after6 = [d for d in s if h(d) >= 6]

    def series(f):
        return [(d["t"], f(d)) for d in after6]

    keys = {
        "使用量（MemTotal−MemAvailable）": lambda d: d["mem_used_mib"],
        "コンテナの cgroup の anon+kernel": lambda d: d["cg_containers"]["anon_mib"] + d["cg_containers"]["kernel_mib"],
        "docker.service の anon+kernel": lambda d: d["cg_docker_service"]["anon_mib"] + d["cg_docker_service"]["kernel_mib"],
        "containerd.service の anon+kernel": lambda d: d["cg_containerd_service"]["anon_mib"] + d["cg_containerd_service"]["kernel_mib"],
    }
    for p in ("dockerd", "containerd", "containerd-shim", "radsecproxy", "radsec-edge", "fluent-bit"):
        keys[f"{p} の PSS"] = (lambda p: lambda d: d["procs"].get(p, {}).get("pss_kb", 0) / 1024)(p)
    print(f"記録 {len(s)} 件（{h(s[0]):.1f}〜{h(s[-1]):.1f} 時間）、6 時間以降 {len(after6)} 件")
    for k, f in keys.items():
        vals = [f(d) for d in s]
        print(f"  {k}: 最初 {vals[0]:.1f}、最後 {vals[-1]:.1f}、最大 {max(vals):.1f} MiB、6 時間以降の増え方 {slope(series(f)):+.1f} MiB/日")
    fds = {p: (s[0]["procs"].get(p, {}).get("fds", 0), s[-1]["procs"].get(p, {}).get("fds", 0)) for p in ("dockerd", "containerd")}
    print("  FD（最初 → 最後）:", fds)
    print("  AP の接続（最小・最後）:", min(d["ap_conns"] for d in s), s[-1]["ap_conns"], " テナントのコンテナ（最小）:", min(d["containers"]["tenants_running"] for d in s))
    print("  ディスク（最後）:", s[-1]["disk_mib"], f"/ 全体 {s[-1]['disk_root_used_gib']} GiB、radsecproxy のログ {s[-1]['log_bytes'] / 2**20:.1f} MiB")
    # 想定外の再起動: 起動の時刻か再起動の数が途中で変わったコンテナ
    first, changed = s[0].get("started", {}), set()
    for d in s[1:]:
        for n, v in d.get("started", {}).items():
            if n in first and v != first[n]:
                changed.add(n)
    print("  起動の時刻が変わったコンテナ:", sorted(changed) or "なし")
    try:
        a = [json.loads(l) for l in open(apstat, encoding="utf-8") if l.strip()]
        a = [d for d in a if d["t"] >= start]
        if a:
            print("  AP の役（最後）:", {k: a[-1][k] for k in a[-1] if k != "t"})
    except FileNotFoundError:
        pass
    used = max(d["mem_used_mib"] for d in s)
    g = slope(series(keys["使用量（MemTotal−MemAvailable）"]))
    print(f"判定: 6 時間以降の使用量の増え方 {g:+.1f} MiB/日（基準 30 未満）→ {'合格' if g < 30 else '不合格'}、"
          f"最大の使用量 {used} MiB（基準 2,867 MiB = 2.8 GiB 以内）→ {'合格' if used <= 2867 else '不合格'}")


if __name__ == "__main__":
    cmd, *a = sys.argv[1:]
    {"tenants": lambda: tenants(*a), "setup": lambda: setup(*a), "certs": lambda: certs(*a), "save-certs": lambda: save_certs(a),
     "aps": lambda: aps(*a), "result": lambda: result(a), "report": lambda: report(*a),
     "clean": lambda: clean(*a)}[cmd]()
