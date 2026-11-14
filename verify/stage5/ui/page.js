// 画面を開いて本文を返す（__A1__ = パス）。フォームの送り先とボタンも並べる
async page => {
  await page.goto('__BASE__' + '__A1__');
  const forms = await page.$$eval('form', fs => fs.map(f => (f.getAttribute('action') || f.getAttribute('hx-post') || '') + ' [' + [...f.querySelectorAll('button')].map(b => b.innerText.trim()).join('|') + ']'));
  return (await page.locator('main').innerText()) + '\n--- forms\n' + forms.join('\n');
}
