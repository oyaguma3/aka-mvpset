// 場面 U: 画面からテナント・アカウント・個別の登録・認可ポリシー（システム管理者）。
async page => {
  const U = '__BASE__', KI = '465b5ce8b199b49faa5f0a2ee238a6bc', OPC = 'cd63cb71954a9f4e48a5994e37a02baf';
  const out = []; const ok = (id, pass, text) => out.push([id, pass ? 'PASS' : 'FAIL', text]);
  const body = async () => (await page.locator('body').innerText());
  await page.goto(U + '/');
  let t = await body();
  ok('U1', t.includes('システム管理者'), 'ダッシュボードに役割「システム管理者」が出る');
  ok('U2', t.includes('aka-vecgen') && t.includes('aka-radius'), 'ダッシュボードに aka-provisioner と下流の状態が出る');
  for (const name of ['stage3-t1', 'stage3-t2']) {
    await page.goto(U + '/tenants');
    if ((await body()).includes(name)) continue; // 台本をやり直したとき
    await page.fill('input[name=name]', name);
    await page.getByRole('button', { name: '作成する' }).click();
    await page.waitForSelector(`text=${name}`);
  }
  await page.goto(U + '/tenants/1');
  t = await body();
  ok('U3', t.includes('stage3-t1'), 'テナント 1 を作れた（ID が刻印の値）');
  await page.fill('input[name=external]', 'CUST-001');
  await page.locator('form[hx-post="/tenants/1/external"] button[type=submit]').click();
  await page.waitForTimeout(800);
  await page.goto(U + '/tenants/1');
  ok('U4', await page.inputValue('input[name=external]') === 'CUST-001', '外部の顧客番号を保存できる');
  await page.goto(U + '/accounts');
  if (!(await body()).includes('tenant-user@example.com')) {
    await page.fill('input[name=email]', 'tenant-user@example.com');
    await page.selectOption('select[name=role]', 'tenant_user');
    await page.waitForTimeout(300);
    const ten = page.locator('form[hx-post="/accounts"] select[name=tenant]');
    if (await ten.count()) await ten.selectOption('1');
    await page.locator('form[hx-post="/accounts"] button[type=submit]').click();
    await page.waitForSelector('text=tenant-user@example.com');
  }
  ok('U5', true, 'アカウントを作れる');
  for (const imsi of ['440100000000001', '440100000000002', '440100000000003']) {
    if ((await page.goto(U + '/subscribers/' + imsi)).status() !== 200) {
      await page.goto(U + '/subscribers/new?side=vecgen');
      await page.fill('input[name=imsi]', imsi);
      await page.locator('select[name=tenant]').selectOption('1');
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
  await page.goto(U + '/subscribers/440100000000001');
  t = await body();
  ok('U6', !t.includes(KI) && !t.includes(OPC), '詳細に Ki・OPc が出ない');
  await page.fill('input[name=external]', 'LINE-001');
  await page.locator('form[hx-post="/subscribers/440100000000001/external"] button[type=submit]').click();
  await page.waitForSelector('text=回線の外部の番号を保存しました');
  ok('U7', true, '回線の外部の番号を保存できる');
  await page.goto(U + '/subscribers');
  t = await body();
  ok('U8', ['440100000000001', '440100000000002', '440100000000003'].every(i => t.includes(i)), '一覧に 3 件出る');
  // 認可ポリシー: 3 番目は SSID corp だけ
  await page.goto(U + '/subscribers/440100000000003/policy');
  await page.fill('textarea[name=ssids]', 'corp');
  await page.getByRole('button', { name: '保存' }).click();
  await page.waitForSelector('[role=status]');
  ok('U9', (await page.locator('[role=status]').first().innerText()).includes('保存'), '認可ポリシーを保存できる');
  return out;
}
