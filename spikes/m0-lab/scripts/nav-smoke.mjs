// Verifies the navigation prototype with real CDP multi-touch: pinch-zoom, two-finger pan, palm, pen.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
const url = process.argv[2] ?? 'http://localhost:4173/';
const shot = process.argv[3];
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1180, height: 820 }, hasTouch: true, isMobile: false });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
await page.goto(url);
await page.locator('section.card', { hasText: 'Canvas navigation' }).getByRole('button', { name: /Run/ }).click();
const stage = page.locator('.nav-stage');
await stage.scrollIntoViewIfNeeded();
await page.waitForTimeout(1200);
const b = await stage.boundingBox();
const cdp = await ctx.newCDPSession(page);
const cx = b.x + b.width / 2, cy = b.y + b.height / 2;
const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i, radiusX: 5, radiusY: 5 })) });
// pinch out from 100px apart to 300px apart while rotating slightly
await touch('touchStart', [[cx - 50, cy], [cx + 50, cy]]);
for (let i = 1; i <= 20; i++) {
  const d = 50 + i * 5, a = i * 0.01;
  await touch('touchMove', [[cx - d * Math.cos(a), cy - d * Math.sin(a)], [cx + d * Math.cos(a), cy + d * Math.sin(a)]]);
  await page.waitForTimeout(16);
}
console.log('after pinch+rotate:', await page.locator('.live').textContent());
await touch('touchEnd', []);
await page.waitForTimeout(50);
console.log('after lift:', await page.locator('.live').textContent());
// two-finger pan
await touch('touchStart', [[cx - 50, cy], [cx + 50, cy]]);
for (let i = 1; i <= 10; i++) { await touch('touchMove', [[cx - 50 + i * 10, cy + i * 5], [cx + 50 + i * 10, cy + i * 5]]); await page.waitForTimeout(16); }
console.log('after 2-finger pan:', await page.locator('.live').textContent());
await touch('touchEnd', []);
// palm: large contact must be ignored
await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: cx, y: cy + 100, id: 0, radiusX: 60, radiusY: 60 }] });
await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: cx + 80, y: cy + 100, id: 0, radiusX: 60, radiusY: 60 }] });
await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
// "pen" stroke via mouse
await page.mouse.move(cx - 100, cy - 100); await page.mouse.down();
for (let i = 0; i < 20; i++) await page.mouse.move(cx - 100 + i * 10, cy - 100 + Math.sin(i / 3) * 30);
await page.mouse.up();
await page.waitForTimeout(300);
if (shot) await stage.screenshot({ path: shot });
await page.getByRole('button', { name: 'Smooth' }).click();
await page.getByRole('button', { name: /Finish & save navigation/ }).click();
await page.waitForFunction(() => JSON.parse(localStorage.getItem('openlive.m0.report')).results['canvas-navigation']?.status === 'ok');
const r = await page.evaluate(() => JSON.parse(localStorage.getItem('openlive.m0.report')).results['canvas-navigation'].data);
console.log(JSON.stringify({ zoomRange: r.zoomRange, rot: r.maxRotationDeg, pinch: r.pinchSessions, pans: r.panSessions, palms: r.palmRejection, pen: r.penStrokes, cancels: r.cancels.count, leak: r.pageZoomLeak.leaked, errors }));
await browser.close();
