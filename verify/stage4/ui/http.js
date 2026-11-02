// 画面の要求を Cloudflare 越しに順に送る（__A1__ = 要求の一覧の JSON の base64）。ブラウザーの Cookie を使う。
// フォームの POST は hx-post と同じ口に送る（Origin のない要求なので CSRF の守りを通る）。
async page => {
  const U = '__BASE__';
  const bytes = Uint8Array.from(atob('__A1__'), c => c.charCodeAt(0));
  const reqs = JSON.parse(new TextDecoder().decode(bytes));
  const api = page.context().request, out = [];
  for (const r of reqs) {
    const res = r.m === 'POST'
      ? await api.post(U + r.p, { form: r.f, maxRedirects: 5, timeout: 60000 })
      : await api.get(U + r.p, { maxRedirects: 5, timeout: 60000 });
    out.push({ s: res.status(), u: res.url(), b: await res.text() });
  }
  return out;
}
