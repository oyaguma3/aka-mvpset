// 予行のテナント（確認事項 A6-4）。__A1__ = 予行のテナントの名前（RadSec の slug も同じ）、__A2__ = 付け替え先のテナントの名前、
// __A3__ = グループの名前、__A4__ = グループの CSR（JSON の文字列）。済んだものは飛ばす
async page => {
  const U = '__BASE__', T = '__A1__', T2 = '__A2__', G = '__A3__', CSR = __A4__, out = [];
  const main = async () => (await page.locator('main').innerText());
  const tenantId = async name => {
    await page.goto(U + '/tenants');
    const a = page.locator('main a:text-is("' + name + '")');
    if ((await a.count()) === 0) return '';
    return ((await a.first().getAttribute('href')).match(/\/tenants\/(\d+)/) || [])[1];
  };
  for (const name of [T, T2]) {
    if (await tenantId(name)) continue;
    await page.goto(U + '/tenants');
    await page.fill('input[name=name]', name);
    await page.getByRole('button', { name: '作成する' }).click();
    await page.waitForSelector('main a:text-is("' + name + '")');
    out.push('テナント ' + name + ' を作った');
  }
  const tid = await tenantId(T);
  out.push('tenant ' + tid + ' ' + T + ' / ' + T2 + ' ' + (await tenantId(T2)));
  await page.goto(U + '/tenants/' + tid + '/radsec');
  if ((await page.locator('input[name=slug]').count()) > 0) {
    await page.fill('input[name=slug]', T);
    await page.getByRole('button', { name: '有効にする' }).click();
    await page.waitForTimeout(3000);
    out.push('RadSec を有効にした');
  }
  for (const [slot, edge] of [['primary', 'edge-01'], ['secondary', 'edge-02']]) {
    await page.goto(U + '/tenants/' + tid + '/radsec');
    if (new RegExp('^' + slot + '\\s+' + edge, 'm').test(await main())) continue;
    const f = page.locator('form', { has: page.getByRole('button', { name: '配置を足す' }) });
    await f.locator('select[name=slot]').selectOption(slot);
    await f.locator('select[name=edge]').selectOption(edge);
    await f.getByRole('button', { name: '配置を足す' }).click();
    await page.waitForTimeout(3000);
    out.push(slot + ' → ' + edge);
  }
  await page.goto(U + '/tenants/' + tid + '/aps');
  if (!(await main()).split('\n').some(l => l.trim().startsWith(G))) {
    await page.fill('input[name=name]', G);
    await page.selectOption('select[name=kind]', 'group');
    await page.selectOption('select[name=purpose]', 'unifi');
    await page.fill('textarea[name=csr]', CSR);
    await page.getByRole('button', { name: '登録して発行する' }).click();
    await page.waitForTimeout(3000);
    out.push('グループ ' + G + ' を登録して発行した');
  }
  // グループを足した後の反映を求める（新しい配置のほかは手動の反映。OB1）
  await page.goto(U + '/tenants/' + tid + '/radsec');
  const b = page.getByRole('button', { name: '反映する' });
  if (await b.count()) { await b.first().click(); await page.waitForTimeout(3000); out.push('反映を求めた'); }
  await page.goto(U + '/tenants/' + tid + '/radsec');
  out.push(await main());
  return out.join('\n');
}
