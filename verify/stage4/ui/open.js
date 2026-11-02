// 画面をブラウザーで開いて文を確かめる（__A1__ = 確かめの一覧の JSON の base64。[{id,p,want:[..],deny:[..],status,text}]）。
async page => {
  const U = '__BASE__';
  const bytes = Uint8Array.from(atob('__A1__'), c => c.charCodeAt(0));
  const list = JSON.parse(new TextDecoder().decode(bytes));
  const out = [];
  for (const c of list) {
    const r = await page.goto(U + c.p);
    const t = await page.locator('body').innerText();
    const miss = (c.want || []).filter(w => !t.includes(w));
    const bad = (c.deny || []).filter(w => t.includes(w));
    const st = !c.status || r.status() === c.status;
    out.push([c.id, st && !miss.length && !bad.length ? 'PASS' : 'FAIL', `${c.text}（${r.status()}${miss.length ? ' ない:' + miss.join(',') : ''}${bad.length ? ' 出ている:' + bad.join(',') : ''}）`]);
  }
  return out;
}
