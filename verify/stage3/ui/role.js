// 役割の確かめ（SQL で役割を変えた後）。__A1__ = tenant_user|operator。
async page => {
  const U = '__BASE__', role = '__A1__', out = [];
  const ok = (id, pass, text) => out.push([id, pass ? 'PASS' : 'FAIL', text]);
  if (role === 'tenant_user') {
    const r = await page.goto(U + '/charging');
    ok('C6', r.status() === 403, `Access 越しでも A は課金レコードを開けない（${r.status()}）`);
    const r2 = await page.goto(U + '/subscribers/440100000000001');
    const t = await page.locator('body').innerText();
    ok('C7', r2.status() === 200 && !t.includes('LINE-001'), 'A は自分のテナントの加入者を開け、外部の番号が出ない');
    const r3 = await page.goto(U + '/subscribers/new');
    ok('C8', r3.status() === 403, `A は登録の画面を開けない（${r3.status()}）`);
  } else {
    const r = await page.goto(U + '/charging');
    const t = await page.locator('body').innerText();
    ok('C9', r.status() === 200 && !t.includes('今すぐ締める'), 'C は課金レコードを見られるが締められない');
  }
  return out;
}
