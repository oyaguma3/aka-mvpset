// テナントの「反映する」を押す（__A1__ = テナントの ID）。証明書の更新・失効で宣言の版が上がったとき（新しい配置のほかは手動の反映。OB1）
async page => {
  const U = '__BASE__';
  await page.goto(U + '/tenants/__A1__/radsec');
  const b = page.getByRole('button', { name: '反映する' });
  if ((await b.count()) === 0) return '「反映する」がない（反映を求めるものがない）';
  await b.first().click();
  await page.waitForTimeout(3000);
  return '反映を求めた';
}
