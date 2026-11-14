// AP の一番新しい証明書を「鍵の漏えい」で失効させる（__A1__ = テナントの ID、__A2__ = AP の名前）
async page => {
  const U = '__BASE__';
  page.on('dialog', d => d.accept());
  await page.goto(U + '/tenants/__A1__/aps');
  const href = await page.locator('main a', { hasText: '__A2__' }).first().getAttribute('href');
  await page.goto(U + href);
  const btn = page.getByRole('button', { name: '鍵の漏えい' });
  if ((await btn.count()) === 0) return 'ボタンがない\n' + (await page.locator('main').innerText()).slice(0, 800);
  await btn.first().click();
  await page.waitForTimeout(3000);
  return (await page.locator('main').innerText()).split('\n').filter(l => /失効|有効|シリアル/.test(l)).slice(0, 8).join('\n');
}
