// 止まったときの画面（__A1__ = 場面、__A2__ = 確かめる文、__A3__ = 開くパス、__A4__ = 内容）。
async page => {
  const U = '__BASE__', id = '__A1__', want = '__A2__', path = '__A3__', text = '__A4__';
  const r = await page.goto(U + path);
  const t = await page.locator('body').innerText();
  return [[id, t.includes(want) ? 'PASS' : 'FAIL', `${text}（${r.status()}）`]];
}
