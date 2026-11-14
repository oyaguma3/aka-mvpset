// テナントの「反映する」を押す（__A1__ = テナントの ID）
async page => {
  const U = '__BASE__';
  await page.goto(U + '/tenants/__A1__/radsec');
  const b = page.getByRole('button', { name: '反映する' });
  if ((await b.count()) === 0) return 'ボタンがない';
  await b.first().click();
  await page.waitForTimeout(3000);
  return (await page.locator('main').innerText()).split('\n').filter(l => /反映/.test(l)).slice(0, 4).join(' / ');
}
