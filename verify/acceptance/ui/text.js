// 画面を開いて本文を返す（__A1__ = パス）
async page => {
  await page.goto('__BASE__' + '__A1__');
  return await page.locator('main').innerText();
}
