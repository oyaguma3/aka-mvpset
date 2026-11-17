// 加入者の所属のテナントを付け替える（__A1__ = IMSI、__A2__ = 付け替え先のテナントの名前）。AT-08
// 「付け替える」のボタンは確認の小窓の中なので、フォームを直接送る（htmx も submit の出来事で動く）
async page => {
  const U = '__BASE__';
  await page.goto(U + '/subscribers/__A1__');
  const sel = page.locator('#move-form select[name=tenant]');
  if ((await sel.count()) === 0) return '付け替えのフォームがない';
  await sel.selectOption({ label: '__A2__' });
  await page.evaluate(() => document.getElementById('move-form').requestSubmit());
  await page.waitForTimeout(3000);
  await page.goto(U + '/subscribers/__A1__');
  return (await page.locator('main').innerText()).split('\n').filter(l => /テナント|付け替え/.test(l)).slice(0, 4).join(' / ');
}
