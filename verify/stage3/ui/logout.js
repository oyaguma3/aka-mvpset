// ログアウト（Access のログアウト）。この後は PIN がないとログインできないので、いちばん最後に動かす。
async page => {
  const U = '__BASE__';
  await page.goto(U + '/');
  await page.getByRole('link', { name: 'ログアウト' }).click();
  await page.waitForTimeout(2000);
  const r = await page.goto(U + '/');
  return [['C10', !page.url().startsWith(U) ? 'PASS' : 'FAIL', `ログアウトの後は Access のログインに戻る（${new URL(page.url()).hostname.endsWith('cloudflareaccess.com') ? 'Access' : '別の画面'}）`]];
}
