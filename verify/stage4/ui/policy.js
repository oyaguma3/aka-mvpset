// 認可ポリシーの最初のルールを書き換える（__A1__ = IMSI、__A2__ = NAS-Identifier、__A3__ = SSID）。候補に登録した AP が出ることも確かめる（__A4__ = 候補の AP）。
async page => {
  const U = '__BASE__', imsi = '__A1__', nas = '__A2__', ssids = '__A3__', cand = '__A4__';
  await page.goto(U + '/subscribers/' + imsi + '/policy');
  const opts = await page.locator('#nas-candidates option').evaluateAll(l => l.map(o => o.value));
  await page.locator('input[name=nas_id]').first().fill(nas);
  await page.locator('textarea[name=ssids]').first().fill(ssids);
  await page.getByRole('button', { name: '保存' }).click();
  await page.waitForSelector('[role=status], [role=alert]');
  const t = await page.locator('[role=status], [role=alert]').first().innerText();
  const out = [['POLICY', 'INFO', t.slice(0, 60)]];
  if (cand !== '-') out.push(['E20', opts.includes(cand) ? 'PASS' : 'FAIL', `認可ポリシーの NAS-Identifier の候補に登録した AP が出る（${opts.join(' ')}）`]);
  out.push(['E21', t.includes('保存') ? 'PASS' : 'FAIL', `認可ポリシーを画面で保存できる（${imsi} ${nas} ${ssids}）`]);
  return out;
}
