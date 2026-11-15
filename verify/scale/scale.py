#!/usr/bin/env python3
"""段階 6 の規模の試験（確認事項 L6-3〜L6-6）の手元の補助。drive.sh の段から呼ぶ。計画（テナント・IMSI の範囲・ジョブ・配置）の正はここ。

  scale.py plan                                      … 計画を表で出す
  scale.py tenants <状態.tsv> <出力.json>             … まだないテナント（sc0001〜sc1000）を作る要求
  scale.py jobs <状態.tsv> <済み.txt> <クライアントのID> <取得先> <種> <scaleload> <出力のディレクトリ>
                                                     … まだのジョブの指定（CSV つき）を 1 本ずつ <出力>/<名前>.b64 に書く
  scale.py radsec <状態.tsv> <出力.json>              … 19 テナントの RadSec の有効化と配置（primary・secondary）の要求
  scale.py aps <AP の状態.tsv> <CSR のディレクトリ> <出力の接頭辞> <束の数>   … AP の登録の要求（束に分ける）
  scale.py certs <証明書.tsv> <出力の接頭辞> <束の数>  … サーバー CA と AP の証明書を取る要求
  scale.py save-certs <証明書.tsv> <結果.json>... <pki>  … 取った PEM を保存する
  scale.py apsjson <証明書.tsv> <配置.tsv> <一時の VPS の pki のディレクトリ>  … scaleload の aps.json
  scale.py result <結果.json>...                      … 状態の番号を数え、失敗を出す
  scale.py jobs-report <ジョブ.tsv>                    … ジョブごとの時間（① 1 万件が 30 分以内）
  scale.py timing <結果.json>                          … 画面の応答の分位（⑤ p95 が 3 秒以内）

状態.tsv は psql -At の行（id|name|slug|port|配置（edge:slot のカンマ区切り））。AP の状態.tsv は（name|id|AP の名前のカンマ区切り）。
証明書.tsv は（name|id|port|AP の名前|AP の ID|シリアル）。配置.tsv は（name|slot|edge|公開のアドレス）。ジョブ.tsv は（ID|ファイル名|状態|件数|成功|失敗|始め|終わり）。
"""
import base64
import json
import os
import statistics
import subprocess
import sys
import uuid

TENANTS = 1000  # テナント sc0001〜sc1000（S6-3）
SUBS = 19  # 加入者を置くテナント（sc0001 に 2 万、sc0002〜sc0019 に 1 万ずつ）
EXTRA = "sc0020"  # ③ で vecgen 側に 1 万件を入れる空のテナント
APS_BIG, APS = 100, 50  # AP の数（sc0001 に 100、ほかに 50）
EDGES = ("edge-01", "edge-02")
JOB_ROWS = 10000


def tname(i):
    return f"sc{i:04d}"


def imsi_range(name):
    """テナントの IMSI の番号の範囲（含む）。"""
    i = int(name[2:])
    if i == 1:
        return 1, 20000
    if 2 <= i <= SUBS:
        lo = 20000 + (i - 2) * 10000 + 1
        return lo, lo + 9999
    if name == EXTRA:
        return 200001, 210000
    return None


def ap_names(name):
    n = APS_BIG if name == tname(1) else APS
    return [f"ap{k:03d}" for k in range(1, n + 1)]


def primary(name):
    """primary のエッジ（sc0001〜0010 は edge-01、0011〜0019 は edge-02。secondary は他方）。"""
    return EDGES[0] if int(name[2:]) <= 10 else EDGES[1]


def jobs_plan():
    """40 本のジョブ（各側 20 本）。radius の半分はルール 1 件、半分は 2 件（1 件目は合わない SSID）。"""
    out = []
    k = 0
    for i in range(1, SUBS + 1):
        name = tname(i)
        lo, hi = imsi_range(name)
        for start in range(lo, hi + 1, JOB_ROWS):
            end = min(start + JOB_ROWS - 1, hi)
            part = f"{name}-{(start - lo) // JOB_ROWS + 1}"
            out.append({"kind": "vecgen.create", "tenant_name": name, "from": start, "to": end, "name": f"vecgen-{part}.csv"})
            rules = [{"nas_id": "*", "ssids": "scale"}]
            if k % 2 == 1:
                rules = [{"nas_id": "*", "ssids": "scale-x"}] + rules
            out.append({"kind": "radius.create", "tenant_name": name, "from": start, "to": end, "name": f"radius-{part}.csv", "rules": rules})
            k += 1
    return out


def extra_job():
    lo, hi = imsi_range(EXTRA)
    return {"kind": "vecgen.create", "tenant_name": EXTRA, "from": lo, "to": hi, "name": f"vecgen-{EXTRA}-1.csv"}


def rows(path):
    return [l.rstrip("\n").split("|") for l in open(path, encoding="utf-8") if l.strip()]


def dump(path, reqs):
    json.dump(reqs, open(path, "w", encoding="utf-8"), ensure_ascii=False)


def plan():
    print("テナント: sc0001〜sc%04d（%d）。加入者のいるテナント:" % (TENANTS, TENANTS))
    for i in range(1, SUBS + 1):
        n = tname(i)
        lo, hi = imsi_range(n)
        print(f"  {n} IMSI の番号 {lo}〜{hi}（{hi - lo + 1}）AP {len(ap_names(n))} primary {primary(n)}")
    lo, hi = imsi_range(EXTRA)
    print(f"  {EXTRA} ③ の vecgen 側 {lo}〜{hi}")
    js = jobs_plan()
    print(f"ジョブ {len(js)} 本（radius のルール 1 件 {sum(1 for j in js if len(j.get('rules', [])) == 1)}・2 件 {sum(1 for j in js if len(j.get('rules', [])) == 2)}）")


def tenants(state, out):
    have = {r[1] for r in rows(state)}
    dump(out, [{"m": "POST", "p": "/tenants", "f": {"name": tname(i)}} for i in range(1, TENANTS + 1) if tname(i) not in have])


def jobs(state, done, client, source, seed, bin_, outdir, extra=False):
    ids = {r[1]: r[0] for r in rows(state)}
    finished = {l.strip() for l in open(done, encoding="utf-8")} if os.path.exists(done) else set()
    os.makedirs(outdir, exist_ok=True)
    todo = [extra_job()] if extra else jobs_plan()
    n = 0
    for j in todo:
        if j["name"] in finished:
            continue
        csv = subprocess.run([bin_, "csv", "-seed", seed, "-kind", j["kind"].split(".")[0], "-from", str(j["from"]), "-to", str(j["to"])],
                             check=True, capture_output=True, text=True).stdout
        spec = {"kind": j["kind"], "tenant": ids[j["tenant_name"]], "state": "active", "name": j["name"], "csv": csv}
        if j["kind"] == "vecgen.create":
            spec.update(sqn_type="inc32", clients=[int(c) for c in client.split(",") if c])
        else:
            spec.update(source=source, rules=j["rules"])
        open(os.path.join(outdir, j["name"] + ".b64"), "w").write(base64.b64encode(json.dumps(spec).encode()).decode())
        n += 1
    print(f"{n} 本を {outdir} に書いた（済み {len(finished)}）")


def radsec(state, out):
    reqs = []
    st = {r[1]: r for r in rows(state)}
    for i in range(1, SUBS + 1):
        name = tname(i)
        r = st[name]
        tid, slug, placed = r[0], r[2], set(filter(None, r[4].split(",")))
        if not slug:
            reqs.append({"m": "POST", "p": f"/tenants/{tid}/radsec/enable", "f": {"slug": name, "idem": str(uuid.uuid4())}})
        p, s = primary(name), [e for e in EDGES if e != primary(name)][0]
        if f"{p}:primary" not in placed:
            reqs.append({"m": "POST", "p": f"/tenants/{tid}/radsec/placements", "f": {"slot": "primary", "edge": p}})
        if f"{s}:secondary" not in placed:
            reqs.append({"m": "POST", "p": f"/tenants/{tid}/radsec/placements", "f": {"slot": "secondary", "edge": s}})
    dump(out, reqs)
    print(f"{len(reqs)} 件")


def aps(state, csrdir, prefix, per):
    reqs = []
    for name, tid, have in rows(state):
        got = set(filter(None, have.split(",")))
        for a in ap_names(name):
            if a in got:
                continue
            csr = open(os.path.join(csrdir, f"{name}-{a}.csr"), encoding="utf-8").read()
            reqs.append({"m": "POST", "p": f"/tenants/{tid}/aps", "f": {"name": a, "kind": "ap", "purpose": "other", "csr": csr, "idem": str(uuid.uuid4())}})
    per = int(per)
    for k in range(0, len(reqs), per):
        dump(f"{prefix}{k // per:03d}.json", reqs[k:k + per])
    print(f"{len(reqs)} 件を {(len(reqs) + per - 1) // per} 束に")


def certs(path, prefix, per):
    reqs, seen = [], set()
    for name, tid, port, ap, apid, serial in rows(path):
        if name not in seen:
            seen.add(name)
            reqs.append({"m": "GET", "p": f"/tenants/{tid}/radsec/server-ca.pem", "keep": True, "k": f"{name}-ca"})
        reqs.append({"m": "GET", "p": f"/tenants/{tid}/aps/{apid}/certs/{serial}/pem", "keep": True, "k": f"{name}-{ap}"})
    per = int(per)
    for k in range(0, len(reqs), per):
        dump(f"{prefix}{k // per:03d}.json", reqs[k:k + per])
    print(f"{len(reqs)} 件を {(len(reqs) + per - 1) // per} 束に")


def save_certs(args):
    *results, pki = args
    os.makedirs(pki, exist_ok=True)
    n = bad = 0
    for path in results:
        reqs = json.load(open(path.replace(".out.json", ".json"), encoding="utf-8"))
        outs = json.load(open(path, encoding="utf-8"))
        for r, o in zip(reqs, outs):
            b = o.get("b", "")
            if o.get("s") != 200 or "BEGIN CERTIFICATE" not in b:
                bad += 1
                continue
            open(os.path.join(pki, r["k"] + ".pem"), "w", encoding="utf-8").write(b)
            n += 1
    print(f"保存 {n}、失敗 {bad}")
    sys.exit(1 if bad else 0)


def apsjson(path, placements, rpki):
    addr = {}
    for name, slot, edge, pub in rows(placements):
        if slot == "primary":
            addr[name] = pub
    out = []
    for name, tid, port, ap, apid, serial in rows(path):
        lo, hi = imsi_range(name)
        out.append({"tenant": name, "name": ap, "addr": f"{addr[name]}:{port}", "cert": f"{rpki}/{name}-{ap}.pem", "key": f"{rpki}/{name}-{ap}.key",
                    "ca": f"{rpki}/{name}-ca.pem", "from": lo, "to": hi})
    json.dump(out, sys.stdout, indent=1)


def result(paths):
    count, fails = {}, []
    for p in paths:
        for o in json.load(open(p, encoding="utf-8")):
            count[o["s"]] = count.get(o["s"], 0) + 1
            if o["s"] not in (200, 303):
                fails.append(f"{o['s']} {o.get('a', '')}")
    print("状態の番号:", dict(sorted(count.items())))
    for f in fails[:20]:
        print("  失敗:", f)
    sys.exit(1 if fails else 0)


def jobs_report(path):
    from datetime import datetime
    worst = 0
    print(f"{'ID':>5} {'ファイル':<28} {'状態':<10} {'件数':>6} {'成功':>6} {'失敗':>5} {'分':>6}")
    for jid, name, state, total, ok, failed, start, end in rows(path):
        mins = ""
        if start and end:
            d = (datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds() / 60
            worst = max(worst, d)
            mins = f"{d:.1f}"
        print(f"{jid:>5} {name:<28} {state:<10} {total:>6} {ok:>6} {failed:>5} {mins:>6}")
    print(f"いちばん長いジョブ {worst:.1f} 分（基準 30 分以内: {'PASS' if worst and worst <= 30 else 'FAIL'}）")


def timing(path):
    d = json.load(open(path, encoding="utf-8"))
    ok = True
    for k, v in d.items():
        ms = sorted(v["ms"])
        p95 = ms[max(0, -(-len(ms) * 95 // 100) - 1)]
        bad = [s for s in v["s"] if s != 200]
        good = p95 <= 3000 and not bad
        ok &= good
        print(f"{k:<14} 回数 {len(ms):>3} p50 {statistics.median(ms):>6.0f} ms p95 {p95:>6} ms 最大 {ms[-1]:>6} ms 200 以外 {len(bad)}  {'PASS' if good else 'FAIL'}")
    print("⑤ 画面の応答:", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    c, a = sys.argv[1], sys.argv[2:]
    {"plan": lambda: plan(), "tenants": lambda: tenants(*a), "jobs": lambda: jobs(*a[:7], extra=len(a) > 7 and a[7] == "extra"),
     "radsec": lambda: radsec(*a), "aps": lambda: aps(*a), "certs": lambda: certs(*a), "save-certs": lambda: save_certs(a),
     "apsjson": lambda: apsjson(*a), "result": lambda: result(a), "jobs-report": lambda: jobs_report(*a), "timing": lambda: timing(*a)}[c]()
