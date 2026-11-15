// 一括投入のジョブを 1 本登録して確定する（verify/scale/drive.sh の jobs の段。__A1__ = ジョブの指定の JSON の base64）。
// 指定: {kind, tenant, state, sqn_type?, clients?: [ID], source?, rules?: [{nas_id, ssids, vlan_id, session_timeout}], name, csv}
// ファイルは multipart（aka-ossbss の POST /jobs）。ルールと許可クライアントは同じ名前の項目を繰り返す。返す値: {s, url, job, a, cs, ca} の JSON の文字列。
async page => {
  const U = '__BASE__';
  const j = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__A1__'), c => c.charCodeAt(0))));
  const api = page.context().request;
  const fd = new FormData();
  fd.append('kind', j.kind);
  fd.append('tenant', String(j.tenant));
  fd.append('state', j.state);
  if (j.sqn_type) fd.append('sqn_type', j.sqn_type);
  for (const c of j.clients || []) fd.append('clients', String(c));
  if (j.source) fd.append('source', j.source);
  for (const r of j.rules || []) {
    fd.append('nas_id', r.nas_id);
    fd.append('ssids', r.ssids);
    fd.append('vlan_id', r.vlan_id || '');
    fd.append('session_timeout', r.session_timeout || '');
  }
  fd.append('file', new Blob([j.csv], { type: 'text/csv' }), j.name);
  const alert = b => { const m = b.match(/role="alert"[^>]*>([\s\S]*?)<\/div>/); return m ? m[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 300) : ''; };
  const res = await api.post(U + '/jobs', { multipart: fd, maxRedirects: 5, timeout: 180000 });
  const b = await res.text();
  const m = res.url().match(/\/jobs\/(\d+)$/);
  const out = { s: res.status(), url: res.url().replace(U, ''), job: m ? m[1] : '', a: alert(b) };
  if (m) {
    const c = await api.post(U + '/jobs/' + m[1] + '/confirm', { form: {}, maxRedirects: 5, timeout: 90000 });
    out.cs = c.status();
    out.ca = alert(await c.text());
  }
  return JSON.stringify(out);
}
