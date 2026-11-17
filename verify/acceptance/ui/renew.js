// グループの証明書を新しい CSR で更新する（__A1__ = テナントの ID、__A2__ = グループの名前、__A3__ = CSR（JSON の文字列））。AT-11
async page => {
  const U = '__BASE__';
  await page.goto(U + '/tenants/__A1__/aps');
  const href = await page.locator('main a', { hasText: '__A2__' }).first().getAttribute('href');
  await page.goto(U + href);
  const f = page.locator('form[hx-post$="/renew"]');
  await f.locator('textarea[name=csr]').fill(__A3__);
  await f.getByRole('button', { name: '発行する' }).click();
  await page.waitForTimeout(3000);
  return href + '\n' + (await page.locator('main').innerText()).split('\n').filter(l => /有効|失効|[0-9a-f]{16}|誤り|できません/.test(l)).slice(0, 10).join('\n');
}
