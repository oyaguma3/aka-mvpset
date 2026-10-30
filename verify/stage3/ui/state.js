// 状態の変更（__A1__ = 側、__A2__ = inactive|active、__A3__ = IMSI）。止めるのは確認ダイアログを通す。
async page => {
  const U = '__BASE__', side = '__A1__', state = '__A2__', imsi = '__A3__';
  await page.goto(U + '/subscribers/' + imsi);
  if (state === 'inactive') {
    await page.locator(`button[commandfor="dialog-state-${side}-inactive"]`).click();
    await page.locator(`#dialog-state-${side}-inactive button[type=submit]`).click();
  } else {
    await page.locator(`form#state-${side}-active button[type=submit]`).click();
  }
  await page.waitForSelector('[role=status], [role=alert]');
  const t = await page.locator('[role=status], [role=alert]').first().innerText();
  const want = state === 'inactive' ? '停止中' : '利用中';
  return [['S-' + side + '-' + state, t.includes(want) ? 'PASS' : 'FAIL', `画面で ${side} 側を ${state} にする（${t.slice(0, 60)}）`]];
}
