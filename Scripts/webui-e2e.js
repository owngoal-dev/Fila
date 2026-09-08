// End-to-end pass over the Fila web UI with the local Chrome, headless.
// usage: node run.js <port> <share root on disk>
const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const [port, root] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
const shots = path.join(__dirname, 'shots');
fs.mkdirSync(shots, { recursive: true });
const exists = (p) => fs.existsSync(path.join(root, p));
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let page;
(async () => {
  const browser = await puppeteer.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
    args: ['--lang=en-US'],
  });
  page = await browser.newPage();
  await page.setViewport({ width: 1200, height: 760 });
  await page.authenticate({ username: 'fila', password: 's3cret' });
  // Chrome ignores --lang on a zh system; the UI picks its strings from navigator.language.
  await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'language', { get: () => 'en-US' }));
  const problems = [];
  // The test deliberately triggers a duplicate upload (412), a fake HEIC and a
  // missing file (404); those are the feature working, not problems.
  const expectedFail = (url) =>
    /\/hello\.txt$|\/hello2\.txt$|\/renamed\.txt$|\/Sub\/$|missing\.png|IMG_0001\.HEIC|\/_fila\/mark-/.test(url);
  page.on('console', (m) => {
    if (m.type() === 'error' && !/40[04]|412/.test(m.text())) problems.push('console: ' + m.text());
  });
  page.on('pageerror', (e) => problems.push('pageerror: ' + e.message));
  page.on('requestfailed', (r) => { if (!expectedFail(r.url())) problems.push('requestfailed: ' + r.url()); });

  const rows = () => page.$$eval('tbody tr .name', (els) => els.map((e) => e.textContent.trim()));
  const button = (label) => page.waitForSelector(`button::-p-text(${label})`, { visible: true });
  const click = async (label) => (await button(label)).click();
  // Notices repeat ("1 completed.") so a stale one must go before an action whose notice we wait for.
  const clearNotice = async () => {
    const dismiss = await page.$('.notice button');
    if (!dismiss) return; // busy: the notice is live progress, not stale
    await dismiss.click();
    await page.waitForFunction(() => !document.querySelector('.notice'));
  };
  // A modal dialog makes the page behind it inert, so stale notices are cleared before one opens.
  const dialogSubmit = async () => (await page.waitForSelector('dialog[open] button[type=submit]')).click();
  const typeIn = async (selector, text) => {
    const el = await page.waitForSelector(selector, { visible: true });
    await el.evaluate((e) => { e.focus(); e.select(); });
    await el.type(text);
  };
  const waitNotice = async (substr) => {
    await page.waitForFunction(
      (s) => document.querySelector('.notice span')?.textContent.includes(s),
      { timeout: 10000 },
      substr
    );
    return page.$eval('.notice span', (e) => e.textContent);
  };
  const idle = () => page.waitForFunction(
    () => !document.querySelector('.progress') && !document.querySelector('dialog[open]'),
    { timeout: 10000 }
  );
  const step = (name) => console.log('✓', name);

  // 1. Root listing
  await page.goto(base + '/', { waitUntil: 'networkidle0' });
  await page.waitForSelector('tbody tr');
  const includesAll = (list, wanted) => wanted.every((w) => list.includes(w));
  const rootRows = await rows();
  assert(includesAll(rootRows, ['Documents', 'Photos', 'README.md']), rootRows.join());
  assert.strictEqual(await page.$eval('.footer', (e) => e.textContent), `${rootRows.length} items`);
  await page.screenshot({ path: path.join(shots, '1-root-light.png') });
  step('root lists ' + rootRows.length + ' items');

  // 2. Navigate into a folder; crumbs and URL follow
  await click('Documents');
  await page.waitForFunction(() => location.pathname === '/Documents/');
  await idle();
  assert(includesAll(await rows(), ['config.plist', 'notes.txt']));
  assert.deepStrictEqual(
    await page.$$eval('.crumbs button', (b) => b.map((x) => x.textContent)),
    ['Root', 'Documents']
  );
  step('navigate into Documents');

  // 3. New folder
  await clearNotice();
  await click('New Folder');
  await typeIn('dialog[open] input', 'Sub');
  await dialogSubmit();
  await waitNotice('1 completed.');
  await idle();
  assert(exists('Documents/Sub'), 'Sub created on disk');
  assert.strictEqual((await rows())[0], 'Sub', 'folders sort first');
  step('new folder');

  // 4. Upload
  const local = path.join(__dirname, 'hello.txt');
  fs.writeFileSync(local, 'hello from e2e\n');
  const input = await page.$('input[type=file]');
  await clearNotice();
  await input.uploadFile(local);
  await waitNotice('1 completed.');
  await idle();
  assert.strictEqual(read('Documents/hello.txt'), 'hello from e2e\n');
  step('upload');

  // 5. Upload a duplicate → server 412 → rename prompt (the field arrives selected, so typing replaces)
  await clearNotice();
  await input.uploadFile(local);
  await page.waitForSelector('dialog[open] input');
  const selected = await page.$eval(
    'dialog[open] input',
    (i) => document.activeElement === i && i.selectionEnd - i.selectionStart === i.value.length
  );
  assert(selected, 'prefilled name is selected on open');
  await page.waitForSelector('dialog[open]');
  assert((await page.$eval('dialog[open] h2', (e) => e.textContent)).includes('Choose Another Name'));
  await typeIn('dialog[open] input', 'hello2.txt');
  await dialogSubmit();
  await waitNotice('1 completed.');
  await idle();
  assert(exists('Documents/hello2.txt'));
  step('duplicate upload asks for a new name');

  // 6. Rename via row menu
  await clearNotice();
  await (await page.waitForSelector('button[aria-label="Actions for hello2.txt"]')).click();
  await click('Rename');
  await typeIn('dialog[open] input', 'renamed.txt');
  await dialogSubmit();
  await waitNotice('1 completed.');
  await idle();
  assert(exists('Documents/renamed.txt') && !exists('Documents/hello2.txt'));
  step('rename');

  // 7. Select two, bulk copy into Sub
  await clearNotice();
  await (await page.$('input[aria-label="Select hello.txt"]')).click();
  await (await page.$('input[aria-label="Select renamed.txt"]')).click();
  assert((await page.$eval('.bulk .count', (e) => e.textContent)) === '2 selected');
  await page.screenshot({ path: path.join(shots, '2-selection.png') });
  // Bulk download: one download per selected file.
  const client = await page.createCDPSession();
  const downloadDir = path.join(__dirname, 'downloads');
  fs.rmSync(downloadDir, { recursive: true, force: true });
  fs.mkdirSync(downloadDir);
  await client.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloadDir });
  await (await page.waitForSelector('.bulk button::-p-text(Download)')).click();
  await page.waitForFunction(() => true);
  for (let i = 0; i < 40 && fs.readdirSync(downloadDir).filter((f) => !f.endsWith('.crdownload')).length < 2; i++) await sleep(250);
  assert.deepStrictEqual(fs.readdirSync(downloadDir).sort(), ['hello.txt', 'renamed.txt']);
  assert.strictEqual(fs.readFileSync(path.join(downloadDir, 'hello.txt'), 'utf8'), 'hello from e2e\n');
  step('bulk download');
  await click('Copy');
  await page.waitForSelector('dialog[open] .picker-list button');
  await (await page.waitForSelector('dialog[open] .picker-list button::-p-text(Sub)')).click();
  await page.waitForFunction(
    () => document.querySelector('dialog[open] .picker-path .mono')?.textContent === '/Documents/Sub/'
  );
  await page.screenshot({ path: path.join(shots, '3-picker.png') });
  await dialogSubmit();
  await waitNotice('2 completed.');
  await idle();
  assert(exists('Documents/Sub/hello.txt') && exists('Documents/Sub/renamed.txt'));
  assert(exists('Documents/hello.txt'), 'copy keeps the source');
  step('bulk copy');

  // 8. Move onto an existing name is refused, and reported
  await clearNotice();
  await (await page.$('input[aria-label="Select renamed.txt"]')).click();
  await click('Move');
  await (await page.waitForSelector('dialog[open] .picker-list button::-p-text(Sub)')).click();
  await page.waitForFunction(
    () => document.querySelector('dialog[open] .picker-path .mono')?.textContent === '/Documents/Sub/'
  );
  await dialogSubmit();
  const refused = await waitNotice('0 completed');
  assert(refused.includes('name is in use'), refused);
  assert(exists('Documents/renamed.txt'), 'refused move leaves the source');
  await idle();
  assert((await page.$eval('.notice', (e) => e.className)).includes('error'));
  step('move onto existing name refused: ' + refused);

  // 9. Move to a sibling folder via the picker's parent button. The refused
  // move kept its selection (by design), so only select if it is not already.
  await clearNotice();
  assert(
    await page.$eval('input[aria-label="Select renamed.txt"]', (c) => c.checked),
    'failed batch keeps its selection'
  );
  await click('Move');
  await page.waitForSelector('dialog[open] .picker-list button');
  await (await page.$('dialog[open] .picker-path button')).click(); // up to /
  await (await page.waitForSelector('dialog[open] .picker-list button::-p-text(Photos)')).click();
  await page.waitForFunction(
    () => document.querySelector('dialog[open] .picker-path .mono')?.textContent === '/Photos/'
  );
  await dialogSubmit();
  await waitNotice('1 completed.');
  await idle();
  assert(exists('Photos/renamed.txt') && !exists('Documents/renamed.txt'));
  step('move to sibling folder');

  // 10. Delete with confirmation
  await clearNotice();
  await (await page.$('input[aria-label="Select hello.txt"]')).click();
  await click('Delete');
  await page.waitForSelector('dialog[open]');
  assert((await page.$eval('dialog[open] .namelist', (e) => e.textContent)).includes('hello.txt'));
  await page.screenshot({ path: path.join(shots, '4-delete.png') });
  await dialogSubmit();
  await waitNotice('1 completed.');
  await idle();
  assert(!exists('Documents/hello.txt'));
  step('delete');

  // 11. Cancel a dialog does nothing
  await clearNotice();
  await click('New Folder');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('dialog[open]'));
  step('escape closes a dialog');

  // 12. Filter
  await typeIn('input.filter', 'sub');
  assert.deepStrictEqual(await rows(), ['Sub']);
  await typeIn('input.filter', 'zzz');
  assert((await page.$eval('.empty', (e) => e.textContent)).includes('No names match'));
  await (await page.$('input.filter')).evaluate((e) => { e.focus(); e.select(); });
  await page.keyboard.press('Backspace');
  await page.waitForFunction(() => document.querySelectorAll('tbody tr').length > 1);
  step('filter');

  // 13. Download links carry the download attribute; folders do not
  const links = await page.$$eval(
    'tbody a[download]',
    (a) => a.map((x) => [x.getAttribute('href'), x.getAttribute('download')])
  );
  assert(links.some(([h, d]) => h === '/Documents/notes.txt' && d === 'notes.txt'), JSON.stringify(links));
  assert.strictEqual(
    await page.$eval('tbody tr:first-child .name a', () => 1).catch(() => 0),
    0,
    'folder rows are buttons, not download links'
  );
  const download = await page.evaluate(async () => {
    const r = await fetch('/Documents/notes.txt');
    return [r.status, r.headers.get('content-disposition'), await r.text()];
  });
  assert.deepStrictEqual(download, [200, 'attachment', 'hello from fila\n']);
  step('download');

  // 14. Browser back returns to root
  await page.goBack();
  await page.waitForFunction(() => location.pathname === '/');
  await idle();
  assert(includesAll(await rows(), ['Documents', 'Photos', 'README.md']));
  step('history back');

  // 14b. Every toolbar control is exactly the same height
  const heights = await page.$$eval('.toolbar .btn, .toolbar input.filter', (els) => els.map((e) => e.offsetHeight));
  assert(new Set(heights).size === 1, 'toolbar control heights differ: ' + JSON.stringify(heights));
  step('toolbar controls share one height (' + heights[0] + 'px)');

  // 15. Breadcrumb has room (regression: filter input crushed it)
  const crumbBox = await page.$eval('.crumbs', (e) => ({ w: e.clientWidth, sw: e.scrollWidth }));
  assert(crumbBox.sw <= crumbBox.w, `crumbs overflow ${JSON.stringify(crumbBox)}`);
  step('breadcrumb fits');

  // 16. Artwork, favicon and brand mark load from /_fila/; QuickLook thumbnails render for media
  const loaded = await page.$$eval(
    'img.fileicon, img.brand-mark',
    (i) => i.map((x) => [x.getAttribute('src'), x.complete && x.naturalWidth > 0])
  );
  assert(loaded.length > 0 && loaded.every(([, ok]) => ok), 'artwork failed to load: ' + JSON.stringify(loaded));
  assert(
    loaded.some(([s]) => s === '/_fila/folder.png') && loaded.some(([s]) => s === '/_fila/mark-light-2x.png'),
    JSON.stringify(loaded)
  );
  const favicons = await page.$$eval(
    'link[rel=icon], link[rel=apple-touch-icon]',
    (l) => l.map((x) => [x.rel, x.getAttribute('href'), x.media])
  );
  assert.strictEqual(favicons.length, 3, JSON.stringify(favicons));
  for (const [, href] of favicons) {
    const status = await page.evaluate(async (u) => (await fetch(u)).status, href);
    assert.strictEqual(status, 200, href);
  }
  await page.goto(base + '/Photos/', { waitUntil: 'networkidle0' });
  await page.waitForSelector('tbody tr');
  await page.waitForFunction(
    () => [...document.querySelectorAll('img.thumb')].some((i) => i.complete && i.naturalWidth > 0),
    { timeout: 10000 }
  );
  const thumbs = await page.$$eval('img.thumb', (i) => i.map((x) => [x.getAttribute('src'), x.naturalWidth > 0]));
  assert(thumbs.some(([s, ok]) => s.includes('.png?thumbnail=') && ok), JSON.stringify(thumbs));
  const heic = await page.evaluate(async () => {
    const r = await fetch('/Photos/IMG_0001.HEIC?thumbnail=64');
    return r.status;
  });
  assert.strictEqual(heic, 404, 'a fake HEIC has no thumbnail, and the row keeps its icon');
  assert(
    (await page.$$eval('tbody tr', (rows) => rows.map((r) => r.querySelector('img').className))).includes('fileicon')
  );
  const lastMenu = (await page.$$('button[aria-label^="Actions for"]')).pop();
  await lastMenu.click();
  const menuBox = await page.$eval('.menu', (m) => {
    const r = m.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return { visible: r.height > 0, hitInside: !!hit && m.contains(hit) };
  });
  assert(menuBox.visible && menuBox.hitInside, 'row menu is clipped: ' + JSON.stringify(menuBox));
  await page.screenshot({ path: path.join(shots, '5-photos-menu.png') });
  await page.keyboard.press('Escape');
  step('thumbnails and unclipped row menu');

  // 17. Dark theme screenshot
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
  await page.goto(base + '/Documents/', { waitUntil: 'networkidle0' });
  await page.waitForSelector('tbody tr');
  await (await page.waitForSelector('button[aria-label="Actions for notes.txt"]')).click();
  await page.waitForSelector('.menu');
  await page.screenshot({ path: path.join(shots, '6-documents-dark-menu.png') });
  step('dark theme');

  await browser.close();
  if (problems.length) {
    console.log('PROBLEMS:\n' + problems.join('\n'));
    process.exit(1);
  }
  console.log('ALL PASSED');
})().catch(async (e) => {
  console.error('FAILED:', e.message);
  if (page) {
    await page.screenshot({ path: path.join(shots, 'failure.png') }).catch(() => {});
    console.error(await page.evaluate(() => ({
      url: location.href,
      notice: document.querySelector('.notice span')?.textContent,
      dialog: !!document.querySelector('dialog[open]'),
      busy: !!document.querySelector('.progress'),
      rows: [...document.querySelectorAll('tbody tr .name')].map((e) => e.textContent.trim()),
    })).catch(() => 'no page'));
  }
  process.exit(1);
});
