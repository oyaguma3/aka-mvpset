#!/usr/bin/env python3
"""長い時間の試験（概要 §16.4、S4-11）の中央の代わり。エッジの管理API を直接呼ぶ。

  long.py gen <作業ディレクトリ> <テナント数>    PKI と CRL を作る
  long.py setup <作業ディレクトリ> <テナント数>  宣言・CSR・証明書・最初の反映（1 エッジ同時 5 件）
  long.py run <作業ディレクトリ> <テナント数>    定期の呼び出しを続ける（終わらせるまで）

テナントは 15 分の 13 が AP だけ、15 分の 1 が Meraki 形の模型（PartialChain）、15 分の 1 が Mist 形の模型（CRLCheck off）。業者の CA は模型で、実物ではない。
"""
import concurrent.futures as cf
import http.client
import json
import os
import ssl
import subprocess
import sys
import threading
import time
import uuid

EDGE = "172.31.95.2"
URN = "example"
DOMAIN = "radsec.test"
UPSTREAM = "172.31.95.1"
K = 5
PORT0 = 20000
TICK_TENANTS, TICK_STATUS, TICK_APPLY, TICK_CRL = 60, 30, 60, 600


def sh(*a, stdin=None):
    return subprocess.run(a, input=stdin, check=True, capture_output=True).stdout


def key(p):
    sh("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", p)


def root(p, subj):
    key(p + ".key")
    sh("openssl", "req", "-x509", "-new", "-key", p + ".key", "-subj", subj, "-days", "365", "-out", p + ".pem",
       "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")


def sign(csr, ca, ext, out, days=90):
    """CSR の PEM に CA で署名する。ext は x509 の拡張の文字列。"""
    extf = out + ".ext"
    open(extf, "w").write(ext)
    sh("openssl", "x509", "-req", "-CA", ca + ".pem", "-CAkey", ca + ".key", "-set_serial", "0x" + uuid.uuid4().hex[:30],
       "-days", str(days), "-extfile", extf, "-out", out, stdin=csr)
    os.remove(extf)


CA_EXT = "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n"


def sub_ca(p, subj, ca):
    key(p + ".key")
    csr = sh("openssl", "req", "-new", "-key", p + ".key", "-subj", subj)
    sign(csr, ca, CA_EXT, p + ".pem", 365)


def leaf(p, subj, ca, san=""):
    key(p + ".key")
    csr = sh("openssl", "req", "-new", "-key", p + ".key", "-subj", subj)
    ext = "extendedKeyUsage=clientAuth\n"
    if san:
        ext += f"subjectAltName={san}\n"
    sign(csr, ca, ext, p + ".pem")


def crl_db(p):
    os.makedirs(p + "-db", exist_ok=True)
    open(p + "-db/index.txt", "a").close()
    if not os.path.exists(p + "-db/crlnumber"):
        open(p + "-db/crlnumber", "w").write("01\n")
    open(p + "-db/ca.cnf", "w").write(
        f"[ca]\ndefault_ca=d\n[d]\ndatabase={p}-db/index.txt\ncrlnumber={p}-db/crlnumber\ndefault_md=sha256\ndefault_crl_days=7\n")


def make_crl(p, dst):
    tmp = dst + ".tmp"
    sh("openssl", "ca", "-config", p + "-db/ca.cnf", "-gencrl", "-keyfile", p + ".key", "-cert", p + ".pem", "-out", tmp)
    os.replace(tmp, dst)


def tenants(n):
    """(番号, slug, 種類, ポート) の一覧。"""
    each = max(1, round(n / 15)) if n >= 3 else 0
    out = []
    for i in range(1, n + 1):
        kind = "ap"
        if each and i > n - each:
            kind = "mist"
        elif each and i > n - 2 * each:
            kind = "meraki"
        out.append((i, f"t{i:03d}", kind, PORT0 + i - 1))
    return out


def gen_tenant(w, t, shared):
    i, slug, kind, port = t
    d = f"{w}/pki/{slug}"
    os.makedirs(d, exist_ok=True)
    root(f"{d}/ca", f"/CN={slug} client CA")
    crl_db(f"{d}/ca")
    make_crl(f"{d}/ca", f"{w}/crl/crl/tenant.{slug}.pem")
    lines = []
    if kind == "ap":
        for a in range(1, K + 1):
            leaf(f"{d}/ap-{a}", f"/CN={slug}-ap-{a}", f"{d}/ca", f"URI:urn:{URN}:nas:{slug}:ap-{a}")
            lines.append(f"{port} {d}/ap-{a}.pem {d}/ap-{a}.key {slug}\n")
    elif kind == "meraki":
        sub_ca(f"{d}/org", f"/CN=9{i:06d}", f"{shared}/mcluster")
        sub_ca(f"{d}/feat", f"/CN=radsec-9{i:06d}", f"{d}/org")
        crl_db(f"{d}/feat")
        make_crl(f"{d}/feat", f"{w}/crl/crl/brought.{slug}.vendor.pem")
        for a in range(1, K + 1):
            leaf(f"{d}/ap-{a}", f"/CN=Q2AA-{i:04d}-{a:04d}", f"{d}/feat")
            with open(f"{d}/ap-{a}-chain.pem", "wb") as f:
                for x in (f"{d}/ap-{a}.pem", f"{d}/feat.pem", f"{d}/org.pem", f"{shared}/mcluster.pem", f"{shared}/msub.pem"):
                    f.write(open(x, "rb").read())
            lines.append(f"{port} {d}/ap-{a}-chain.pem {d}/ap-{a}.key {slug}\n")
    else:
        root(f"{d}/vendor", f"/O=Mist/OU=OrgCA/CN={uuid.uuid5(uuid.NAMESPACE_DNS, slug)}")
        for a in range(1, K + 1):
            leaf(f"{d}/ap-{a}", f"/CN=d420b0{i:03x}{a:03x}", f"{d}/vendor")
            lines.append(f"{port} {d}/ap-{a}.pem {d}/ap-{a}.key {slug}\n")
    return lines


def gen(w, n):
    os.makedirs(f"{w}/crl/crl", exist_ok=True)
    shared = f"{w}/pki/shared"
    os.makedirs(shared, exist_ok=True)
    root(f"{shared}/sca", "/CN=edge-long server CA")
    root(f"{shared}/mroot", "/CN=Long Lab Meraki Dashboard Root CA")
    sub_ca(f"{shared}/msub", "/CN=Long Lab Meraki Dashboard Cluster SubCA", f"{shared}/mroot")
    sub_ca(f"{shared}/mcluster", "/CN=Long Lab Meraki.com Cluster CA", f"{shared}/msub")
    key(f"{shared}/client.key")
    sh("openssl", "req", "-x509", "-new", "-key", f"{shared}/client.key", "-subj", "/CN=provisioner", "-days", "365", "-out", f"{shared}/client.pem")
    with cf.ThreadPoolExecutor(4) as ex:
        all_lines = list(ex.map(lambda t: gen_tenant(w, t, shared), tenants(n)))
    with open(f"{w}/aps.txt", "w") as f:
        for lines in all_lines:
            f.writelines(lines)
    print("gen:", n, "tenants", sum(map(len, all_lines)), "aps", flush=True)


class API:
    def __init__(self, w):
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE  # 本物の aka-provisioner はフィンガープリントで照合する。ここでは接続先が決まっている
        self.ctx.load_cert_chain(f"{w}/pki/shared/client.pem", f"{w}/pki/shared/client.key")

    def call(self, method, path, body=None, timeout=60):
        c = http.client.HTTPSConnection(EDGE, 9447, context=self.ctx, timeout=timeout)
        try:
            h = {"X-Operator-Id": "edge-long", "X-Trace-ID": "long-" + uuid.uuid4().hex[:12]}
            data = None
            if method != "GET":
                h["Idempotency-Key"] = uuid.uuid4().hex
            if body is not None:
                data = json.dumps(body)
                h["Content-Type"] = "application/json"
            c.request(method, path, data, h)
            r = c.getresponse()
            raw = r.read()
            try:
                return r.status, json.loads(raw) if raw else {}
            except ValueError:
                return r.status, {"raw": raw[:200].decode("utf-8", "replace")}
        finally:
            c.close()

    def retry(self, method, path, body=None):
        """503 TENANT_BUSY は同じ呼び出しをやり直す。"""
        for _ in range(30):
            s, d = self.call(method, path, body)
            if s != 503:
                return s, d
            time.sleep(2)
        return s, d


def declaration(w, t, revision, extra):
    i, slug, kind, port = t
    d = f"{w}/pki/{slug}"
    cas = [{"id": f"tenant.{slug}", "kind": "issued", "certificate": open(f"{d}/ca.pem").read(), "hasCrl": True}]
    aps = []
    doc = {"revision": revision, "slug": slug, "port": port, "authUpstream": f"{UPSTREAM}:1812", "acctUpstream": f"{UPSTREAM}:1813"}
    if kind == "ap":
        aps = [{"name": f"ap-{a}", "kind": "ap"} for a in range(1, K + 1)]
    elif kind == "meraki":
        cas.append({"id": f"brought.{slug}.vendor", "kind": "brought", "certificate": open(f"{d}/feat.pem").read(), "hasCrl": True})
    else:
        cas.append({"id": f"brought.{slug}.vendor", "kind": "brought", "certificate": open(f"{d}/vendor.pem").read(), "hasCrl": False})
        doc["sharedMatch"] = {"attr": "CN", "pattern": "^[0-9a-f]{12}$"}
    if extra:
        aps.append({"name": "extra", "kind": "ap"})
    doc.update(clientCas=cas, aps=aps)
    return doc


def wait_apply(api, i, revision, limit=240):
    start = time.monotonic()
    while time.monotonic() - start < limit:
        s, d = api.call("GET", f"/tenants/{i}")
        ap = d.get("apply", {}) if s == 200 else {}
        if s == 200 and ap.get("state") == "idle" and d.get("appliedRevision") == revision:
            return "ok", time.monotonic() - start, ""
        if s == 200 and ap.get("state") == "idle" and ap.get("lastResult") not in (None, "", "ok") and ap.get("lastRevision") == revision:
            return ap.get("lastResult"), time.monotonic() - start, ap.get("lastError", "")
        time.sleep(1)
    return "timeout", time.monotonic() - start, ""


def setup_tenant(w, api, t):
    i, slug, kind, port = t
    d = f"{w}/pki/{slug}"
    s, r = api.retry("PUT", f"/tenants/{i}", declaration(w, t, 1, False))
    assert s in (200, 201), (slug, s, r)
    for what, ca, ext in (
        ("server", f"{w}/pki/shared/sca", "subjectAltName=" + ",".join(f"DNS:{x}.{slug}.{DOMAIN}" for x in ("primary", "secondary", "tertiary")) + "\nextendedKeyUsage=serverAuth\n"),
        ("probe", f"{d}/ca", f"subjectAltName=URI:urn:{URN}:nas:{slug}:probe\nextendedKeyUsage=clientAuth\n"),
    ):
        s, r = api.retry("POST", f"/tenants/{i}/{what}-csr")
        assert s == 200, (slug, what, s, r)
        sign(r["csr"].encode(), ca, ext, f"{d}/{what}-cert.pem")
        s, r = api.retry("PUT", f"/tenants/{i}/{what}-cert", {"certificate": open(f"{d}/{what}-cert.pem").read()})
        assert s == 200, (slug, what, s, r)
    s, r = api.retry("POST", f"/tenants/{i}/apply")
    assert s == 202, (slug, s, r)
    res, sec, err = wait_apply(api, i, 1)
    print(slug, kind, res, round(sec, 1), err, flush=True)
    return res


def setup(w, n):
    api = API(w)
    t0 = time.monotonic()
    with cf.ThreadPoolExecutor(5) as ex:
        res = list(ex.map(lambda t: setup_tenant(w, api, t), tenants(n)))
    print("setup:", res.count("ok"), "/", n, "ok in", round(time.monotonic() - t0), "s", flush=True)
    sys.exit(0 if res.count("ok") == n else 1)


class Run:
    def __init__(self, w, n):
        self.w, self.n = w, n
        self.api = API(w)
        self.t = tenants(n)
        self.lock = threading.Lock()
        self.st = {"tenants_ok": 0, "tenants_err": 0, "status_ok": 0, "status_err": 0, "apply_ok": 0, "apply_ng": 0, "crl_rolled": 0, "tenants_seen_min": n}
        self.state_path = f"{w}/state.json"
        self.rev = {str(t[0]): 1 for t in self.t}
        self.extra = {}
        self.apply_i = self.crl_i = 0
        if os.path.exists(self.state_path):
            s = json.load(open(self.state_path))
            self.rev, self.extra, self.apply_i, self.crl_i = s["rev"], s["extra"], s["apply_i"], s["crl_i"]
        self.events = open(f"{w}/events.jsonl", "a", buffering=1)

    def event(self, **kw):
        self.events.write(json.dumps({"t": int(time.time()), **kw}, ensure_ascii=False) + "\n")

    def count(self, k, v=1):
        with self.lock:
            self.st[k] += v

    def every(self, sec, fn):
        while True:
            start = time.monotonic()
            try:
                fn()
            except Exception as e:  # 試験を止めず、記録する
                self.event(kind="exception", where=fn.__name__, error=repr(e)[:300])
            time.sleep(max(0, sec - (time.monotonic() - start)))

    def poll_tenants(self):
        s, d = self.api.call("GET", "/tenants")
        items = d.get("items", []) if s == 200 else []
        if s != 200 or len(items) != self.n:
            self.count("tenants_err")
            self.event(kind="tenants", status=s, n=len(items))
            return
        self.count("tenants_ok")

    def poll_status(self):
        s, d = self.api.call("GET", "/status")
        if s != 200 or not d.get("agent", {}).get("dockerOk"):
            self.count("status_err")
            self.event(kind="status", status=s, agent=d.get("agent"))
            return
        self.count("status_ok")

    def apply_one(self):
        t = self.t[self.apply_i % self.n]
        self.apply_i += 1
        i = str(t[0])
        rev = self.rev[i] + 1
        extra = not self.extra.get(i, False)
        start = time.monotonic()
        s, r = self.api.retry("PUT", f"/tenants/{i}", declaration(self.w, t, rev, extra))
        if s != 200:
            self.count("apply_ng")
            self.event(kind="put", tenant=t[1], status=s, body=str(r)[:200])
            return
        self.rev[i], self.extra[i] = rev, extra
        s, r = self.api.retry("POST", f"/tenants/{i}/apply")
        if s != 202:
            self.count("apply_ng")
            self.event(kind="apply", tenant=t[1], status=s, body=str(r)[:200])
            return
        res, sec, err = wait_apply(self.api, i, rev)
        self.count("apply_ok" if res == "ok" else "apply_ng")
        self.event(kind="applied", tenant=t[1], rev=rev, result=res, seconds=round(time.monotonic() - start, 1), error=err[:200])
        json.dump({"rev": self.rev, "extra": self.extra, "apply_i": self.apply_i, "crl_i": self.crl_i}, open(self.state_path, "w"))

    def crl_one(self):
        t = self.t[self.crl_i % self.n]
        self.crl_i += 1
        d = f"{self.w}/pki/{t[1]}"
        make_crl(f"{d}/ca", f"{self.w}/crl/crl/tenant.{t[1]}.pem")
        if t[2] == "meraki":
            make_crl(f"{d}/feat", f"{self.w}/crl/crl/brought.{t[1]}.vendor.pem")
        self.count("crl_rolled")

    def write_status(self):
        with self.lock:
            doc = {"t": int(time.time()), **self.st}
        tmp = f"{self.w}/run-status.json.tmp"
        json.dump(doc, open(tmp, "w"))
        os.replace(tmp, f"{self.w}/run-status.json")

    def main(self):
        for sec, fn in ((TICK_TENANTS, self.poll_tenants), (TICK_STATUS, self.poll_status), (TICK_APPLY, self.apply_one), (TICK_CRL, self.crl_one), (30, self.write_status)):
            threading.Thread(target=self.every, args=(sec, fn), daemon=True).start()
        while True:
            time.sleep(3600)


if __name__ == "__main__":
    cmd, work, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    {"gen": gen, "setup": setup, "run": lambda w, n: Run(w, n).main()}[cmd](work, count)
