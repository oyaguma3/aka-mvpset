// 画面の応答の時間（確認事項 L6-6 の ⑤）。__A1__ = [{k: 名前, p: パス}] の JSON の base64、__A2__ = 回数。
// ブラウザーの Cookie で Cloudflare 越しに HTML を GET し、送ってから本文を受け終わるまでの時間（ミリ秒）を測る（画面の描画は含まない）。
// 返す値: {名前: {s: [状態の番号], ms: [時間]}} の JSON の文字列。
async page => {
  const U = '__BASE__';
  const list = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__A1__'), c => c.charCodeAt(0))));
  const n = Number('__A2__');
  const api = page.context().request;
  const out = {};
  for (let i = 0; i < n; i++) {
    for (const x of list) {
      const t0 = Date.now();
      let s = 0;
      try {
        const res = await api.get(U + x.p, { maxRedirects: 5, timeout: 60000 });
        await res.body();
        s = res.status();
      } catch (e) {
        s = 0;
      }
      const ms = Date.now() - t0;
      (out[x.k] = out[x.k] || { s: [], ms: [] }).s.push(s);
      out[x.k].ms.push(ms);
    }
  }
  return JSON.stringify(out);
}
