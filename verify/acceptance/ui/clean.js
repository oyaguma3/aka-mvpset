// 予行の片付け（確認事項 A6-10）。__A1__ = 段（subs|group|detach|tenants）、__A2__ = 予行のテナントの ID、__A3__ = 付け替え先のテナントの ID、
// __A4__ = グループの ID、__A5__ = SIM の IMSI のカンマ区切り。確認の小窓の中のボタンはフォームを直接送る（htmx も submit の出来事で動く）
async page => {
  const U = '__BASE__', out = [];
  page.on('dialog', async d => { try { await d.accept(); } catch (e) { /* playwright-cli が先に応答していれば何もしない */ } });
  const send = async id => page.evaluate(id => { const f = document.getElementById(id); if (!f) return false; f.requestSubmit(); return true; }, id);
  const phase = '__A1__';
  if (phase === 'subs') {
    for (const imsi of '__A5__'.split(',')) {
      for (const id of ['state-both-inactive', 'delete-radius', 'delete-vecgen']) {
        await page.goto(U + '/subscribers/' + imsi);
        out.push(imsi.slice(0, 6) + '… ' + id + ' ' + ((await send(id)) ? '送った' : 'フォームなし'));
        await page.waitForTimeout(3000);
      }
      await page.goto(U + '/subscribers/' + imsi);
      out.push((await page.locator('main').innerText()).split('\n').filter(l => /削除|登録されていません/.test(l)).slice(0, 3).join(' / '));
    }
  } else if (phase === 'group') {
    await page.goto(U + '/tenants/__A2__/aps/__A4__');
    out.push('グループの削除 ' + ((await send('ap-delete')) ? '送った' : 'フォームなし'));
    await page.waitForTimeout(3000);
    await page.goto(U + '/tenants/__A2__/aps');
    out.push((await page.locator('main').innerText()).slice(0, 400));
  } else if (phase === 'detach') {
    for (let i = 0; i < 4; i++) {
      await page.goto(U + '/tenants/__A2__/radsec');
      const b = page.getByRole('button', { name: '外す' });
      if ((await b.count()) === 0) break;
      await b.first().click();
      await page.waitForTimeout(3000);
      out.push('配置を 1 つ外した');
    }
  } else if (phase === 'tenants') {
    for (const id of ['__A2__', '__A3__']) {
      await page.goto(U + '/tenants/' + id);
      out.push('テナント ' + id + ' の削除 ' + ((await send('tenant-delete')) ? '送った' : 'フォームなし'));
      await page.waitForTimeout(3000);
      out.push((await page.locator('main').innerText()).split('\n').filter(l => /削除|できません|残って/.test(l)).slice(0, 3).join(' / '));
    }
  }
  return out.join('\n');
}
