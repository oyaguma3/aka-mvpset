// セッションの画面（__A1__ = IMSI）。
async page => {
  const U = '__BASE__', imsi = '__A1__';
  await page.goto(U + '/sessions?imsi=' + imsi);
  const t = await page.locator('body').innerText();
  await page.goto(U + '/sessions?tenant=1');
  const t2 = await page.locator('body').innerText();
  return [['A3', t.includes('ap-01') && t2.includes(imsi) ? 'PASS' : 'FAIL', 'セッションの画面に IMSI とテナントの絞り込みで出る']];
}
