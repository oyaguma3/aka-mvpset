// 配置のテナントのコンテナを再起動する（__A1__ = テナントの ID、__A2__ = スロット）。AP の接続を張り直させるのに使う
async page => {
  const U = '__BASE__';
  page.on('dialog', async d => { try { await d.accept(); } catch (e) { /* playwright-cli が先に応答していれば何もしない */ } });
  await page.goto(U + '/tenants/__A1__/radsec');
  const row = page.locator('tr', { hasText: '__A2__' }).filter({ has: page.getByRole('button', { name: '再起動' }) }).first();
  if ((await row.count()) === 0) return '行がない';
  await row.getByRole('button', { name: '再起動' }).click();
  await page.waitForTimeout(1500);
  const dlg = page.locator('dialog[open]');
  if (await dlg.count()) await dlg.getByRole('button', { name: /再起動/ }).last().click();
  await page.waitForTimeout(4000);
  return (await page.locator('main').innerText()).split('\n').filter(l => /再起動|primary|secondary/.test(l)).slice(0, 6).join(' / ');
}
