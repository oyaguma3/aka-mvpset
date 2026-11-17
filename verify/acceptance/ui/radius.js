// SIM の radius 側を登録する（確認事項 A6-5。vecgen 側はユーザーが鍵を入れて登録済み）。__A1__ = IMSI のカンマ区切り、
// __A2__ = SSID、__A3__ = Session-Timeout（秒）。テナントは台帳の所属で決まる。ルールは NAS-Identifier * の 1 件
async page => {
  const U = '__BASE__', out = [];
  for (const imsi of '__A1__'.split(',')) {
    await page.goto(U + '/subscribers/' + imsi);
    if (!/vecgen 側/.test(await page.locator('main').innerText())) { out.push(imsi + ': 加入者の画面が開けない'); continue; }
    if ((await page.locator('a[href^="/subscribers/new?side=radius"]').count()) === 0) { out.push(imsi + ': radius 側はある'); continue; }
    await page.goto(U + '/subscribers/new?side=radius&imsi=' + imsi);
    await page.selectOption('select[name=state]', 'active');
    await page.selectOption('select[name=source]', 'vecgen');
    await page.fill('input[name=nas_id]', '*');
    await page.fill('textarea[name=ssids]', '__A2__');
    await page.fill('input[name=session_timeout]', '__A3__');
    await page.getByRole('button', { name: '登録する' }).click();
    await page.waitForTimeout(2500);
    out.push(imsi + ': ' + (page.url().includes('/subscribers/' + imsi) ? 'radius 側を登録した'
      : '登録できない: ' + (await page.locator('main').innerText()).split('\n').filter(l => /ません|確かめ|です/.test(l)).join(' / ')));
  }
  return out.join('\n');
}
