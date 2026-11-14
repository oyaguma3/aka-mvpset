// 加入者の片側の状態を変える（__A1__ = IMSI、__A2__ = vecgen|radius|both、__A3__ = active|inactive）。
// ボタンは form="state-<側>-<状態>" でフォームを指す（画面の作り）
async page => {
  const U = '__BASE__';
  page.on('dialog', d => d.accept());
  await page.goto(U + '/subscribers/__A1__');
  // ボタンは確認の小窓の中にあって見えないので、フォームを直接送る（htmx も submit の出来事で動く）
  const ok = await page.evaluate(id => { const f = document.getElementById(id); if (!f) return false; f.requestSubmit(); return true; }, 'state-__A2__-__A3__');
  if (!ok) return 'フォームがない: state-__A2__-__A3__';
  await page.waitForTimeout(3000);
  await page.goto(U + '/subscribers/__A1__');
  const t = (await page.locator('main').innerText()).split('\n');
  const i = t.findIndex(l => l.startsWith('__A2__' === 'vecgen' ? 'vecgen 側' : 'radius 側'));
  return 'clicked state-__A2__-__A3__ → ' + (i >= 0 ? t[i + 1] : '?');
}
