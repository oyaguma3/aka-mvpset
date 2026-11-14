// ダッシュボードの下流の状態と、テナントの RadSec の画面の配置の状態（__A1__ = テナントの ID）。行頭に状態の語を出す
async page => {
  const U = '__BASE__', out = [];
  await page.goto(U + '/');
  for (const l of (await page.locator('main').innerText()).split('\n')) {
    const m = l.match(/^(aka-provisioner|aka-vecgen|aka-radius|radsec-ca|エッジ edge-0\d)\t(\S+)/);
    if (m) out.push(m[2] + '\t' + m[1]);
  }
  await page.goto(U + '/tenants/__A1__/radsec');
  for (const l of (await page.locator('main').innerText()).split('\n')) {
    const m = l.match(/^(primary|secondary)\t(edge-0\d)\t(\S+)/);
    if (m) out.push(m[3] + '\t' + m[1] + ' ' + m[2]);
  }
  return out.join('\n');
}
