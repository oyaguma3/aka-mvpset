// 下流に届かないときの操作（__A1__ = 場面、__A2__ = IMSI、__A3__ = 側）。止める操作の結果の文を返す。
async page => {
  const U = '__BASE__', id = '__A1__', imsi = '__A2__', side = '__A3__';
  await page.goto(U + '/subscribers/' + imsi);
  await page.locator(`button[commandfor="dialog-state-${side}-inactive"]`).click();
  await page.locator(`#dialog-state-${side}-inactive button[type=submit]`).click();
  // 操作の前から読み出せなかったことの文が出ているので、操作の文が出るまで待つ
  await page.waitForFunction(() => document.body.innerText.includes('結果が分かりませんでした'), null, { timeout: 60000 }).catch(() => {});
  const t = (await page.locator('[role=alert]').allInnerTexts()).join(' | ');
  const m = t.split(' | ').find(x => x.includes('結果が分かりませんでした')) || t;
  return [[id, m.includes('結果が分かりませんでした') && m.includes('確かめています') ? 'PASS' : 'FAIL', `下流に届かない操作の文: ${m.slice(0, 90)}`]];
}
