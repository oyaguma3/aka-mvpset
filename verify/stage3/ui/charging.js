// 課金レコード（__A1__ = key: 公開鍵の登録 / import / close / rebuild / download、__A2__ = key は公開鍵の base64、download は保存先の接頭辞）。
async page => {
  const U = '__BASE__', op = '__A1__', path = '__A2__';
  await page.goto(U + '/charging');
  const waitIdle = async () => {
    for (let i = 0; i < 300; i++) {
      await page.goto(U + '/charging');
      if (!(await page.locator('body').innerText()).includes('どれかが動いています')) return;
      await page.waitForTimeout(1000);
    }
  };
  if (op === 'key') {
    await page.fill('textarea[name=armored]', atob(path));
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForTimeout(1000);
    await page.goto(U + '/charging');
    const t = await page.locator('body').innerText();
    return [['M1', t.includes('今の鍵のフィンガープリント') ? 'PASS' : 'FAIL', 'PGP の公開鍵（Curve25519）を登録できる']];
  }
  if (op === 'import') {
    await page.getByRole('button', { name: '今すぐ取り込む' }).click();
    await page.waitForTimeout(1500);
    await waitIdle();
    return [['IMPORT', 'INFO', 'imported']];
  }
  if (op === 'close') {
    await page.locator('button[commandfor="dialog-charging-close"]').click();
    await page.locator('#dialog-charging-close button[type=submit]').click();
    await page.waitForTimeout(1500);
    await waitIdle();
    const names = await page.locator('a[href^="/charging/files/"]').allInnerTexts();
    return [['CLOSE', 'INFO', names.join(' ')]];
  }
  if (op === 'rebuild') {
    const b = page.locator('button[commandfor^="dialog-rebuild-"]').first();
    const id = await b.getAttribute('commandfor');
    await b.click();
    await page.locator(`#${id} button[type=submit]`).click();
    await page.waitForTimeout(1500);
    await waitIdle();
    const names = await page.locator('a[href^="/charging/files/"]').allInnerTexts();
    return [['REBUILD', 'INFO', names.join(' ')]];
  }
  // download: 最新のファイルを Cloudflare 越しに取る
  const link = page.locator('a[href^="/charging/files/"]').first();
  const name = await link.innerText();
  const [dl] = await Promise.all([page.waitForEvent('download'), link.click()]);
  await dl.saveAs(path + name);
  return [['DOWNLOAD', 'INFO', name]];
}
