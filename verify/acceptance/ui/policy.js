// 認可ポリシーの最初のルールの NAS-Identifier を書き換える（__A1__ = IMSI、__A2__ = NAS-Identifier）。AT-05
async page => {
  await page.goto('__BASE__' + '/subscribers/__A1__/policy');
  await page.locator('input[name=nas_id]').first().fill('__A2__');
  await page.getByRole('button', { name: '保存' }).click();
  await page.waitForSelector('[role=status], [role=alert]');
  return (await page.locator('[role=status], [role=alert]').first().innerText()).slice(0, 200);
}
