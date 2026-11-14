// テナント s5a に加入者を両側に登録する（__A1__ = IMSI のカンマ区切り）。setup.js の加入者の部分
async page => {
  const U = '__BASE__', KI = '465b5ce8b199b49faa5f0a2ee238a6bc', OPC = 'cd63cb71954a9f4e48a5994e37a02baf';
  const out = [];
  // 登録する。台帳で削除済みの IMSI は「登録し直すことを承認する」と理由が要る（W4）。誤りの画面では鍵の欄が空に戻るので入れ直す
  const submit = async (imsi, fill) => {
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForTimeout(2500);
    if (page.url().includes('/subscribers/' + imsi)) return '';
    if ((await page.locator('input[name=approve]').count()) === 0) return '登録できない: ' + (await page.locator('main').innerText()).split('\n').filter(l => /ません|確かめ|です/.test(l)).join(' / ');
    await fill();
    await page.locator('input[name=approve]').check();
    await page.fill('input[name=approve_reason]', '段階 5 の戻す練習の後に登録し直す');
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForURL('**/subscribers/' + imsi + '*');
    return '（承認して登録し直した）';
  };
  await page.goto(U + '/tenants');
  const tid = ((await page.locator('main a:text-is("s5a")').first().getAttribute('href')).match(/\/tenants\/(\d+)/) || [])[1];
  for (const imsi of '__A1__'.split(',')) {
    const st = (await page.goto(U + '/subscribers/' + imsi)).status();
    if (st === 200 && !(await page.locator('main').innerText()).includes('削除済み')) { out.push(imsi + ' はある'); continue; }
    await page.goto(U + '/subscribers/new?side=vecgen');
    const fillV = async () => {
      await page.fill('input[name=imsi]', imsi);
      if (await page.locator('select[name=tenant]').count()) await page.locator('select[name=tenant]').selectOption(tid);
      await page.selectOption('select[name=state]', 'active');
      await page.fill('input[name=ki]', KI);
      await page.fill('input[name=opc]', OPC);
      await page.locator('input[name=clients]').first().check();
    };
    await fillV();
    out.push('vecgen ' + (await submit(imsi, fillV)));
    await page.goto(U + '/subscribers/new?side=radius&imsi=' + imsi);
    await page.selectOption('select[name=state]', 'active');
    await page.selectOption('select[name=source]', 'vecgen');
    await page.fill('input[name=nas_id]', '*');
    await page.fill('textarea[name=ssids]', 's5a');
    out.push('radius ' + (await submit(imsi, async () => {
      await page.selectOption('select[name=state]', 'active');
      await page.selectOption('select[name=source]', 'vecgen');
      await page.fill('input[name=nas_id]', '*');
      await page.fill('textarea[name=ssids]', 's5a');
    })));
    out.push(imsi + ' を両側に登録');
  }
  return out.join('\n');
}
