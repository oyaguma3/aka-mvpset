// ボタンの文字でフォームを送る（__A1__ = パス、__A2__ = ボタンの文字）。理由の欄があれば埋める
async page => {
  page.on('dialog', d => d.accept().catch(() => {}));
  await page.goto('__BASE__' + '__A1__');
  const b = page.getByRole('button', { name: '__A2__' }).first();
  const f = b.locator('xpath=ancestor::form[1]');
  if (await f.count()) {
    for (const r of await f.locator('textarea[name=reason], input[name=reason]').all()) await r.fill('段階 5 の戻す練習');
  }
  await b.click();
  await page.waitForTimeout(4000);
  return page.url().replace('__BASE__', '') + '\n' + (await page.locator('main').innerText()).slice(0, 1500);
}
