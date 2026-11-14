// 画面の要求をまとめて Cloudflare 越しに順に送る（__A1__ = 要求の一覧の JSON の base64。[{m, p, f, keep}]）。
// 150 テナントの試験（T5-7）の準備に使う。ブラウザーの Cookie を使い、フォームの POST は hx-post と同じ口に送る（段階 4 の ui/http.js と同じ）。
// 返す値: [{s: 状態の番号, a: 誤りの文（role=alert）, b: 本文（keep のときだけ）}] の JSON の文字列。
async page => {
  const U = '__BASE__';
  const bytes = Uint8Array.from(atob('__A1__'), c => c.charCodeAt(0));
  const reqs = JSON.parse(new TextDecoder().decode(bytes));
  const api = page.context().request, out = [];
  for (const r of reqs) {
    let res;
    try {
      res = r.m === 'POST'
        ? await api.post(U + r.p, { form: r.f, maxRedirects: 5, timeout: 90000 })
        : await api.get(U + r.p, { maxRedirects: 5, timeout: 90000 });
    } catch (e) {
      out.push({ s: 0, a: String(e).slice(0, 200) });
      continue;
    }
    const b = await res.text();
    const m = b.match(/role="alert"[^>]*>([\s\S]*?)<\/div>/);
    out.push({ s: res.status(), a: m ? m[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200) : '', ...(r.keep ? { b } : {}) });
  }
  return JSON.stringify(out);
}
