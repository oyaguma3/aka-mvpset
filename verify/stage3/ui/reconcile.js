// 突き合わせ（__A1__ = run: 実行して終わりを待つ / approve: 保留を承認する / act: 対応する。__A2__ = IMSI、__A3__ = import|delete）。
async page => {
  const U = '__BASE__', op = '__A1__', imsi = '__A2__', act = '__A3__';
  const waitDone = async () => {
    for (let i = 0; i < 300; i++) {
      await page.goto(U + '/reconcile');
      const href = await page.locator('a[href^="/reconcile/"]').first().getAttribute('href');
      await page.goto(U + href);
      const running = await page.locator('#reconcile-progress[hx-get]').count();
      if (!running) return href;
      await page.waitForTimeout(1000);
    }
    return '';
  };
  if (op === 'run') {
    await page.goto(U + '/reconcile');
    await page.getByRole('button', { name: '今すぐ実行する' }).click();
    await page.waitForTimeout(1000);
    const href = await waitDone();
    return [['RUN', 'INFO', href]];
  }
  if (op === 'approve') {
    await page.goto(U + '/reconcile');
    const href = await page.locator('a[href^="/reconcile/"]').first().getAttribute('href');
    await page.goto(U + href);
    await page.fill('form[action$="/approve"] input[name=reason]', '段階 3 の通しの確かめ');
    await page.getByRole('button', { name: 'このまま直す' }).click();
    await page.waitForTimeout(1500);
    await waitDone();
    return [['APPROVE', 'INFO', href]];
  }
  await page.goto(U + '/reconcile');
  const href = await page.locator('a[href^="/reconcile/"]').first().getAttribute('href');
  await page.goto(U + href);
  await page.locator(`input[aria-label="${imsi} を選ぶ"]`).check();
  if (act === 'import') {
    await page.locator('#reconcile-actions select[name=tenant]').selectOption('1');
    await page.getByRole('button', { name: '取り込む' }).click();
  } else {
    await page.locator('button[command="show-modal"][commandfor="dialog-reconcile-delete"]').click();
    await page.locator('#dialog-reconcile-delete button[value=delete]').click();
  }
  await page.waitForTimeout(1500);
  const t = await page.locator('body').innerText();
  return [['ACT', 'INFO', `${act} ${imsi}: ${(t.match(/[^\n]*(取り込み|削除)[^\n]*/) || [''])[0].slice(0, 80)}`]];
}
