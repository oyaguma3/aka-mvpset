// Access のワンタイム PIN を入れてログインする（__A1__ = PIN）。入力欄は枠（iframe）の中にあることがある
async page => {
  let scope = page;
  if (!(await page.getByRole('textbox', { name: 'Code' }).count())) scope = page.frameLocator('iframe').first();
  await scope.getByRole('textbox', { name: 'Code' }).fill('__A1__');
  await scope.getByRole('button', { name: /Verify/i }).click();
  await page.waitForTimeout(5000);
  return page.url().replace(/\?.*$/, '') + ' ' + (await page.title());
}
