// 画面の口（同じオリジン）から文字のファイルを取り出す（__A1__ = パス）。Access のセッションのクッキーで取る
async page => {
  if (!page.url().startsWith('__BASE__')) await page.goto('__BASE__' + '/');
  return await page.evaluate(async p => { const r = await fetch(p); return r.ok ? await r.text() : 'HTTP ' + r.status; }, '__A1__');
}
