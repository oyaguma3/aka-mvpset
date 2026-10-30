#!/usr/bin/env python3
"""課金レコードの月次のまとめ（*.zip.pgp）を、一般的な道具だけで読んで確かめる（docs/charging-records.md §7・§12）。

  verify-file.py <ファイル> [-o 展開先]

gpg で復号し（秘密鍵は gpg の鍵束に入れておく。GNUPGHOME で切り替えられる）、unzip で展開して、次を確かめる。
- ファイルの名前（charging_<YYYYMM>_<通し番号 6 桁>_v<版>.zip.pgp）と manifest の period・sequence・version が合う。
- PGP の完全性の検査を通る。圧縮のパケットがない（ZIP は圧縮済みなので PGP では圧縮しない）。
- ZIP の中が events・lines・tenants・lines_adj・manifest の 5 つで、manifest の件数と SHA-256（sha256sum）が合う。
- CSV が RFC 4180 の形（改行は CRLF、BOM なし）で、すべての行が同じ列を持つ。列の名前が §7 のとおり。
- record_id の形と重複、period、時刻の形（RFC 3339 の +09:00）、真偽値。
すべて通れば終了コード 0。平文を残さないよう、-o を付けなければ展開先は終わりに消す。
"""
import argparse
import csv
import io
import os
import re
import subprocess
import sys
import tempfile

EVENTS = "record_id event_time event side tenant_id tenant_external_id imsi line_external_id from to operator job_id trace_id reason".split()
LINES = ("record_id period imsi tenant_id tenant_external_id line_external_id registered_days radius_active_days vecgen_active_days "
         "radius_state_start radius_state_end vecgen_state_start vecgen_state_end first_registered_at deleted_at "
         "auth_success_count session_count session_seconds input_octets output_octets usage_complete").split()
ADJ = LINES + ["adjusts_record_id", "adjust_reason"]
TENANTS = ("record_id period tenant_id tenant_external_id tenant_name created_at deleted_at existed_days lines_end lines_max "
           "radius_active_lines_end radius_active_lines_max aps_end groups_end brought_cas_end placements_end").split()
MANIFEST = "file_name kind period sequence version record_count sha256 created_at format_version".split()
HEADERS = {"events.csv": EVENTS, "lines.csv": LINES, "tenants.csv": TENANTS, "lines_adj.csv": ADJ}
TIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00$")
STATES = {"", "active", "inactive", "terminated"}

errors = []


def check(ok, msg):
    if not ok:
        errors.append(msg)


def read_csv(path):
    with open(path, "rb") as f:
        raw = f.read()
    check(not raw.startswith(b"\xef\xbb\xbf"), f"{path}: BOM がある")
    check(raw.endswith(b"\r\n"), f"{path}: 最後の改行が CRLF でない")
    check(b"\n" not in raw.replace(b"\r\n", b""), f"{path}: CRLF でない改行がある（値の中の改行を除く）")
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8"), newline="")))
    widths = {len(r) for r in rows}
    check(len(widths) == 1, f"{path}: 行によって列の数が違う {widths}")
    return rows


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("-o", dest="out", help="展開先（平文の CSV が残る）")
    args = ap.parse_args()

    name = os.path.basename(args.file)
    m = re.fullmatch(r"charging_(\d{6})_(\d{6})_v(\d+)\.zip\.pgp", name)
    if not m:
        sys.exit(f"ファイルの名前の形が違います: {name}")
    yyyymm, seq, ver = m.group(1), int(m.group(2)), m.group(3)
    period = f"{yyyymm[:4]}-{yyyymm[4:]}"

    tmp = tempfile.TemporaryDirectory()
    out = args.out or tmp.name
    os.makedirs(out, exist_ok=True)
    z = os.path.join(out, "plain.zip")

    # 復号（gpg は改ざんを検出すると失敗する）。パケットの一覧で圧縮がないことと完全性の保護を確かめる。
    run("gpg", "--batch", "--yes", "--output", z, "--decrypt", args.file)
    packets = run("gpg", "--batch", "--list-packets", args.file).stdout.decode("utf-8", "replace")
    check(":compressed packet:" not in packets, "PGP の圧縮のパケットがある")
    check(":encrypted data packet:" in packets or ":aead encrypted packet:" in packets, "暗号化のパケットがない")
    check("mdc_method: 2" in packets or ":aead encrypted packet:" in packets or "aead" in packets.lower(), "完全性の保護（MDC / AEAD）がない")

    names = run("unzip", "-Z1", z).stdout.decode().split()
    check(sorted(names) == sorted(list(HEADERS) + ["manifest.csv"]), f"ZIP の中のファイルが違う: {names}")
    run("unzip", "-tq", z)
    run("unzip", "-oq", z, "-d", out)
    os.remove(z)

    manifest = read_csv(os.path.join(out, "manifest.csv"))
    check(manifest[0] == MANIFEST, f"manifest の列が違う: {manifest[0]}")
    seen = {}
    for row in manifest[1:]:
        r = dict(zip(manifest[0], row))
        seen[r["file_name"]] = r
        check(r["kind"] == r["file_name"].removesuffix(".csv"), f"manifest の kind: {r}")
        check(r["period"] == period and int(r["sequence"]) == seq and r["version"] == ver, f"manifest の period・sequence・version が名前と違う: {r}")
        check(TIME.match(r["created_at"]) is not None, f"manifest の created_at: {r['created_at']}")
        sha = run("sha256sum", os.path.join(out, r["file_name"])).stdout.decode().split()[0]
        check(sha == r["sha256"], f"{r['file_name']}: SHA-256 が manifest と違う")
    check(set(seen) == set(HEADERS), f"manifest の行が違う: {sorted(seen)}")

    counts = {}
    for fname, header in HEADERS.items():
        rows = read_csv(os.path.join(out, fname))
        check(rows[0] == header, f"{fname}: 列が違う: {rows[0]}")
        data = [dict(zip(rows[0], r)) for r in rows[1:]]
        counts[fname] = len(data)
        check(fname in seen and int(seen[fname]["record_count"]) == len(data), f"{fname}: 件数が manifest と違う（{len(data)}）")
        ids = [d["record_id"] for d in data]
        check(len(ids) == len(set(ids)), f"{fname}: record_id が重複している")
        for d in data:
            check_row(fname, d, period, yyyymm)

    print(f"{name}: 対象月 {period}、通し番号 {seq}、版 {ver}")
    print("  件数: " + "、".join(f"{k} {v}" for k, v in counts.items()))
    if errors:
        for e in errors:
            print("NG: " + e)
        sys.exit(1)
    print("すべて合っています。")


def check_row(fname, d, period, yyyymm):
    rid = d["record_id"]
    for col in ("event_time", "first_registered_at", "deleted_at", "created_at"):
        if d.get(col):
            check(TIME.match(d[col]) is not None, f"{fname} {rid}: {col} の形: {d[col]}")
    if fname == "events.csv":
        check(re.fullmatch(r"E-\d+", rid) is not None, f"events: record_id の形: {rid}")
        check(d["event_time"].startswith(period), f"events {rid}: 対象月の外の時刻 {d['event_time']}")
    elif fname == "lines.csv":
        check(rid == f"L-{yyyymm}-{d['imsi']}-{d['tenant_id']}", f"lines: record_id の形: {rid}")
        check(d["period"] == period, f"lines {rid}: period {d['period']}")
    elif fname == "tenants.csv":
        check(rid == f"T-{yyyymm}-{d['tenant_id']}", f"tenants: record_id の形: {rid}")
        check(d["period"] == period, f"tenants {rid}: period {d['period']}")
    elif fname == "lines_adj.csv":
        check(rid == f"A-{yyyymm}-{d['imsi']}-{d['tenant_id']}", f"lines_adj: record_id の形: {rid}")
        check(d["adjusts_record_id"] == f"L-{d['period'].replace('-', '')}-{d['imsi']}-{d['tenant_id']}", f"lines_adj {rid}: adjusts_record_id {d['adjusts_record_id']}")
        check(d["adjust_reason"] == "late_usage", f"lines_adj {rid}: adjust_reason {d['adjust_reason']}")
    if fname in ("lines.csv", "lines_adj.csv"):
        check(d["usage_complete"] in ("true", "false"), f"{fname} {rid}: usage_complete {d['usage_complete']}")
        for col in ("radius_state_start", "radius_state_end", "vecgen_state_start", "vecgen_state_end"):
            check(d[col] in STATES, f"{fname} {rid}: {col} {d[col]}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        sys.exit(f"NG: {e.cmd[0]} が失敗しました（鍵がない、または壊れている・改ざんされている）: {e.stderr.decode('utf-8', 'replace').strip()}")
