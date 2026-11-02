// テナント・加入者を画面から登録する（システム管理者）。__A1__ = テナントの名前の並び、__A2__ = 「IMSI:テナントの ID」の並び（カンマ区切り）。
async page => {
  const U = '__BASE__', KI = '465b5ce8b199b49faa5f0a2ee238a6bc', OPC = 'cd63cb71954a9f4e48a5994e37a02baf';
  const out = []; const ok = (id, pass, text) => out.push([id, pass ? 'PASS' : 'FAIL', text]);
  const body = async () => (await page.locator('body').innerText());
  for (const name of '__A1__'.split(',')) {
    await page.goto(U + '/tenants');
    if ((await body()).includes(name)) continue;
    await page.fill('input[name=name]', name);
    await page.getByRole('button', { name: '作成する' }).click();
    await page.waitForSelector(`text=${name}`);
  }
  for (const pair of '__A2__'.split(',')) {
    const [imsi, tenant] = pair.split(':');
    if ((await page.goto(U + '/subscribers/' + imsi)).status() !== 200) {
      await page.goto(U + '/subscribers/new?side=vecgen');
      await page.fill('input[name=imsi]', imsi);
      await page.locator('select[name=tenant]').selectOption(tenant);
      await page.selectOption('select[name=state]', 'active');
      await page.fill('input[name=ki]', KI);
      await page.fill('input[name=opc]', OPC);
      await page.locator('input[name=clients]').first().check();
      await page.getByRole('button', { name: '登録する' }).click();
      await page.waitForURL('**/subscribers/' + imsi + '*');
    }
    await page.goto(U + '/subscribers/new?side=radius&imsi=' + imsi);
    await page.selectOption('select[name=state]', 'active');
    await page.selectOption('select[name=source]', 'vecgen');
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForURL('**/subscribers/' + imsi + '*');
  }
  await page.goto(U + '/subscribers');
  const t = await body();
  ok('U1', '__A2__'.split(',').every(p => t.includes(p.split(':')[0])), '画面から加入者を登録できる');
  return out;
}
