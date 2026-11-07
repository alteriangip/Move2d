// End-to-end check of the editor in headless Chromium with touch emulation.
// Usage: node scripts/e2e.mjs <url> <screenshotDir>
import { createRequire } from 'node:module';
import fs from 'node:fs';
const { chromium } = createRequire(import.meta.url)('playwright');
const url = process.argv[2] ?? 'http://localhost:4174/';
const out = process.argv[3] ?? 'e2e-out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1180, height: 820 }, deviceScaleFactor: 2, hasTouch: true, acceptDownloads: true });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
const check = (cond, msg) => { if (!cond) throw new Error('FAILED: ' + msg); console.log('ok -', msg); };

await page.goto(url);
await page.getByRole('dialog', { name: 'Projects' }).waitFor();
check(true, 'first start shows the Projects dialog');

// Import the PSD through the real file picker.
const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.getByRole('button', { name: 'Import PSD or image…' }).click()]);
await chooser.setFiles('fixtures/character.psd');
const dlg = page.getByRole('dialog', { name: 'Import PSD' });
await dlg.waitFor();
const dlgText = await dlg.textContent();
check(dlgText.includes('overlay') && dlgText.includes('not supported'), 'import preview warns about the unsupported blend mode');
await page.screenshot({ path: `${out}/1-import-preview.png` });
await dlg.getByRole('button', { name: /Import 7 layers/ }).click();
await dlg.waitFor({ state: 'detached', timeout: 20000 });

const names = await page.locator('.tree .name').allTextContents();
check(JSON.stringify(names) === JSON.stringify(['Head', 'Body', 'Sketch (hidden)']), `top-level hierarchy preserved: ${names}`);
await page.locator('.row', { hasText: 'Head' }).getByRole('button', { name: 'Expand' }).click();
const all = await page.locator('.tree .name').allTextContents();
check(all.slice(0, 5).join('|') === 'Head|Eye L|Eye R|Blush|Face', `group contents in PSD order: ${all.slice(0, 5)}`);
check(await page.locator('.row', { hasText: 'Sketch (hidden)' }).evaluate((e) => e.classList.contains('hidden-node')), 'hidden PSD layer imported hidden');
await page.waitForFunction(() => window.__ol?.renderer?.textureCount >= 6, null, { timeout: 10000 });
check(true, 'textures uploaded to WebGL');

// Select by tapping the canvas on the face (touch tap), inspect it.
const canvas = page.locator('canvas.gl');
const box = await canvas.boundingBox();
const docToScreen = async (x, y) => page.evaluate(([x, y]) => {
  // read the camera indirectly: use the canvas and the fitted 600x800 doc (fit = 0.9 of min ratio)
  const c = document.querySelector('canvas.gl'); const r = c.getBoundingClientRect();
  const s = Math.min(r.width / 600, r.height / 800) * 0.9;
  return [r.left + (r.width - 600 * s) / 2 + x * s, r.top + (r.height - 800 * s) / 2 + y * s];
}, [x, y]);
const [fx, fy] = await docToScreen(300, 160);
await page.touchscreen.tap(fx, fy);
await page.waitForTimeout(200);
check((await page.locator('.inspector .panel-head h2').textContent()) === 'Layer', 'tapping the canvas selects a layer');
const selName = await page.locator('.inspector input[type=text]').first().inputValue();
check(selName === 'Face', `pixel-accurate pick selected "${selName}" (eyes/blush are elsewhere)`);

// Drag the selected layer with the "pen" (mouse = pen policy) and verify X changes; then undo.
const xBefore = Number(await page.locator('.inspector .row2 input').first().inputValue());
await page.mouse.move(fx, fy); await page.mouse.down();
for (let i = 1; i <= 10; i++) await page.mouse.move(fx + i * 6, fy + i * 3);
await page.mouse.up();
await page.waitForTimeout(150);
const xAfter = Number(await page.locator('.inspector .row2 input').first().inputValue());
check(xAfter > xBefore + 20, `dragging moved the layer (${xBefore} → ${xAfter})`);
await page.getByRole('button', { name: /Undo/ }).click();
const xUndo = Number(await page.locator('.inspector .row2 input').first().inputValue());
check(xUndo === xBefore, `undo restored position (${xUndo})`);
await page.getByRole('button', { name: /Redo/ }).click();
check(Number(await page.locator('.inspector .row2 input').first().inputValue()) === xAfter, 'redo re-applied the move');

// Opacity slider + rename + visibility via inspector.
await page.locator('.inspector input[type=range]').fill('40');
check((await page.locator('.inspector .field-label', { hasText: 'Opacity' }).textContent()).includes('40%'), 'opacity slider updates');
const nameInput = page.locator('.inspector input[type=text]').first();
await nameInput.fill('Face base');
await nameInput.press('Enter');
await page.waitForTimeout(100);
check((await page.locator('.tree .name').allTextContents()).includes('Face base'), 'rename from inspector shows in hierarchy');

// Long-press menu on a hierarchy row → Group.
const eyeRow = page.locator('.row', { hasText: 'Eye L' });
const eb = await eyeRow.boundingBox();
await page.mouse.click(eb.x + 80, eb.y + eb.height / 2, { button: 'right' });
await page.getByRole('menuitem', { name: 'Group', exact: true }).click();
check((await page.locator('.tree .name').allTextContents()).includes('Group'), 'context menu Group creates a group');

// Pinch-zoom with two fingers via CDP.
const cdp = await ctx.newCDPSession(page);
const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i, radiusX: 4, radiusY: 4 })) });
const zoom0 = await page.locator('.status span').first().textContent();
await touch('touchStart', [[cx - 40, cy], [cx + 40, cy]]);
for (let i = 1; i <= 10; i++) { await touch('touchMove', [[cx - 40 - i * 8, cy], [cx + 40 + i * 8, cy]]); await page.waitForTimeout(16); }
await touch('touchEnd', []);
await page.waitForTimeout(600);
const zoom1 = await page.locator('.status span').first().textContent();
check(parseInt(zoom1) > parseInt(zoom0) * 1.8, `two-finger pinch zooms (${zoom0} → ${zoom1})`);
await page.screenshot({ path: `${out}/2-editor.png` });
await page.getByRole('button', { name: /Fit/ }).click();
await page.waitForTimeout(300);
await page.screenshot({ path: `${out}/3-editor-fit.png` });

// Autosave → reload → project restored.
await page.waitForFunction(() => document.querySelector('.status')?.textContent?.includes('Saved on this iPad'), null, { timeout: 5000 });
await page.reload();
await page.waitForFunction(() => document.querySelectorAll('.tree .name').length > 0, null, { timeout: 10000 });
const afterReload = await page.locator('.tree .name').allTextContents();
check(afterReload.includes('Face base') && afterReload.includes('Group'), 'project restored after reload (autosave)');

// Export .olive and re-import it as a new project.
const [download] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: /Export/ }).click()]);
const file = `${out}/exported.olive`;
await download.saveAs(file);
check(fs.statSync(file).size > 1000, `exported ${download.suggestedFilename()} (${fs.statSync(file).size} bytes)`);
await page.getByRole('button', { name: /Projects/ }).click();
const [ch2] = await Promise.all([page.waitForEvent('filechooser'), page.getByRole('button', { name: 'Import PSD or image…' }).click()]);
await ch2.setFiles(file);
await page.waitForTimeout(800);
const reimported = await page.locator('.tree .name').allTextContents();
check(reimported.includes('Face base'), 'exported .olive re-opens with edits intact');
await page.getByRole('button', { name: /Projects/ }).click();
await page.locator('.project-list li').first().waitFor();
const nProj = await page.locator('.project-list li').count();
check(nProj === 2, `two projects listed on device (${nProj})`);
await page.screenshot({ path: `${out}/4-projects.png` });
await page.getByRole('button', { name: 'Close' }).click();

// Portrait layout.
await page.setViewportSize({ width: 820, height: 1180 });
await page.waitForTimeout(400);
await page.screenshot({ path: `${out}/5-portrait.png` });
check(errors.length === 0, `no page errors (${errors.join(' | ')})`);
await browser.close();
