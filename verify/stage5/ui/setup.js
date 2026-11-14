// 通しのテナント s5a（__A1__ = 加入者の IMSI のカンマ区切り、__A2__ = AP の名前から CSR の JSON）
async page => {
  const U = '__BASE__', KI = '465b5ce8b199b49faa5f0a2ee238a6bc', OPC = 'cd63cb71954a9f4e48a5994e37a02baf';
  const CSR = __A2__, out = [];
  const main = async () => (await page.locator('main').innerText());
  await page.goto(U + '/tenants');
  if (!(await main()).split('\n').some(l => l.trim().startsWith('s5a'))) {
    await page.fill('input[name=name]', 's5a');
    await page.getByRole('button', { name: '作成する' }).click();
    await page.waitForSelector('main a:text-is("s5a")');
  }
  const tid = ((await page.locator('main a:text-is("s5a")').first().getAttribute('href')).match(/\/tenants\/(\d+)/) || [])[1];
  out.push('tenant ' + tid);
  for (const imsi of '__A1__'.split(',')) {
    if ((await page.goto(U + '/subscribers/' + imsi)).status() === 200) { out.push(imsi + ' はある'); continue; }
    await page.goto(U + '/subscribers/new?side=vecgen');
    await page.fill('input[name=imsi]', imsi);
    await page.locator('select[name=tenant]').selectOption(tid);
    await page.selectOption('select[name=state]', 'active');
    await page.fill('input[name=ki]', KI);
    await page.fill('input[name=opc]', OPC);
    await page.locator('input[name=clients]').first().check();
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForURL('**/subscribers/' + imsi + '*');
    await page.goto(U + '/subscribers/new?side=radius&imsi=' + imsi);
    await page.selectOption('select[name=state]', 'active');
    await page.selectOption('select[name=source]', 'vecgen');
    await page.fill('input[name=nas_id]', '*');
    await page.fill('textarea[name=ssids]', 's5a');
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForURL('**/subscribers/' + imsi + '*');
    out.push(imsi + ' を両側に登録');
  }
  await page.goto(U + '/tenants/' + tid + '/radsec');
  if ((await page.locator('input[name=slug]').count()) > 0) {
    await page.fill('input[name=slug]', 's5a');
    await page.getByRole('button', { name: '有効にする' }).click();
    await page.waitForTimeout(3000);
    out.push('RadSec を有効に');
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
  for (const name of Object.keys(CSR)) {
    await page.goto(U + '/tenants/' + tid + '/aps');
    if ((await main()).split('\n').some(l => l.trim().startsWith(name))) continue;
    await page.fill('input[name=name]', name);
    await page.selectOption('select[name=kind]', 'ap');
    await page.selectOption('select[name=purpose]', 'other');
    await page.fill('textarea[name=csr]', CSR[name]);
    await page.getByRole('button', { name: '登録して発行する' }).click();
    await page.waitForTimeout(3000);
    out.push('AP ' + name);
  }
  // AP を足した後の反映を求める（新しい配置のほかは手動の反映。OB1）
  await page.goto(U + '/tenants/' + tid + '/radsec');
  const b = page.getByRole('button', { name: '反映する' });
  if (await b.count()) { await b.first().click(); await page.waitForTimeout(3000); out.push('反映を求めた'); }
  await page.goto(U + '/tenants/' + tid + '/radsec');
  out.push(await main());
  return out.join('\n');
}
