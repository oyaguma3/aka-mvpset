// Access のログイン画面でメールアドレスを送る（__A1__ = メールアドレス）。PIN はユーザーからもらう
async page => {
  await page.fill('input[type=email], input[name=email]', '__A1__');
  await page.getByRole('button', { name: /Send login code/i }).click();
  await page.waitForTimeout(3000);
  return (await page.locator('body').innerText()).split('\n').filter(l => /code|expires/i.test(l)).join(' / ');
}
