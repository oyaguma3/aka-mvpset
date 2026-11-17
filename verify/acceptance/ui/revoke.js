// グループの証明書を 1 枚失効させる（__A1__ = テナントの ID、__A2__ = グループの ID、__A3__ = シリアル、__A4__ = superseded|keyCompromise）。AT-11
async page => {
  const U = '__BASE__';
  page.on('dialog', async d => { try { await d.accept(); } catch (e) { /* playwright-cli が先に応答していれば何もしない */ } });
  await page.goto(U + '/tenants/__A1__/aps/__A2__');
  const ok = await page.evaluate(([s, r]) => {
    const f = [...document.querySelectorAll('form')].find(f => (f.getAttribute('hx-post') || '').endsWith('/certs/' + s + '/revoke') && f.querySelector('input[name=reason]')?.value === r);
    if (!f) return false;
    f.querySelector('button').click();
    return true;
  }, ['__A3__', '__A4__']);
  if (!ok) return '失効のフォームがない';
  await page.waitForTimeout(3000);
  await page.goto(U + '/tenants/__A1__/aps/__A2__');
  return (await page.locator('main').innerText()).split('\n').filter(l => /有効|失効|[0-9a-f]{16}/.test(l)).slice(0, 10).join('\n');
}
