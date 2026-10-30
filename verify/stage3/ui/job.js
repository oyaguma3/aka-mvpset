// 一括投入の登録と投入（__A1__ = 種類、__A2__ = ファイルの絶対パス）。ジョブの番号と確認の画面の件数を返す。
async page => {
  const U = '__BASE__', kind = '__A1__', file = '__A2__';
  await page.goto(U + '/jobs/new?kind=' + kind);
  const ten = page.locator('select[name=tenant]');
  if (await ten.count()) await ten.selectOption('1');
  const st = page.locator('select[name=state]');
  if (await st.count()) await st.selectOption('active');
  const cl = page.locator('input[name=clients]');
  if (await cl.count()) await cl.first().check();
  const src = page.locator('select[name=source]');
  if (await src.count()) await src.selectOption('vecgen');
  await page.setInputFiles('input[name=file]', file);
  await page.getByRole('button', { name: '確かめる' }).click();
  await page.waitForURL(/\/jobs\/\d+$/, { timeout: 120000 });
  const id = page.url().match(/\/jobs\/(\d+)$/)[1];
  const text = await page.locator('body').innerText();
  const line = (text.match(/登録する: \d+ 件[^\n]*/) || [''])[0];
  await page.locator('button[commandfor="job-confirm-dialog"]').click();
  await page.locator('#job-confirm-dialog button[type=submit]').click();
  await page.waitForTimeout(800);
  return [['JOB', 'INFO', `${id} ${kind} ${line}`]];
}
