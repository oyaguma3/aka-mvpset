// テナントの送信元の範囲を変える（__A1__ = テナントの ID、__A2__ = 範囲（空なら制限なし））
async page => {
  const U = '__BASE__';
  await page.goto(U + '/tenants/__A1__/radsec');
  const f = page.locator('form', { has: page.locator('textarea') }).filter({ hasText: '許す送信元' });
  const ta = f.locator('textarea').first();
  await ta.fill('__A2__');
  await f.getByRole('button', { name: '変更する' }).click();
  await page.waitForTimeout(3000);
  return (await page.locator('main').innerText()).split('\n').filter(l => /送信元|変更|反映/.test(l)).slice(0, 6).join('\n');
}
