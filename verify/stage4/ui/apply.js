// RadSec の画面の「反映する」をブラウザーで押す（__A1__ = テナント）。htmx のフォームが Cloudflare 越しに動くことも確かめる。
async page => {
  const U = '__BASE__', id = '__A1__';
  await page.goto(U + '/tenants/' + id + '/radsec');
  await page.getByRole('button', { name: '反映する' }).click();
  await page.waitForSelector('text=反映を求めました', { timeout: 15000 }).catch(() => {});
  const t = await page.locator('#tenant-radsec').innerText();
  return [['APPLY', 'INFO', t.slice(0, 120).replace(/\n/g, ' ')]];
}
