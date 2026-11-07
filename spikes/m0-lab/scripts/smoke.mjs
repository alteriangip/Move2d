// End-to-end smoke run of the lab in headless Chromium (container baseline).
// Usage: node scripts/smoke.mjs <url> <outDir>
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import fs from 'node:fs';

const url = process.argv[2] ?? 'http://localhost:4173/';
const out = process.argv[3] ?? 'smoke-out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--ignore-gpu-blocklist'] });
const ctx = await browser.newContext({ viewport: { width: 1180, height: 820 }, deviceScaleFactor: 1, hasTouch: true });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
await page.goto(url);
await page.waitForFunction(() => JSON.parse(localStorage.getItem('openlive.m0.report') || '{}').env?.features, null, { timeout: 30000 });

const report = () => page.evaluate(() => JSON.parse(localStorage.getItem('openlive.m0.report')));
const waitResult = async (id, timeout) =>
  page.waitForFunction((id) => { const r = JSON.parse(localStorage.getItem('openlive.m0.report')).results[id]; return r && r.status !== 'partial'; }, id, { timeout });
const clickRun = (title) => page.locator('section.card', { hasText: title }).getByRole('button', { name: /Run/ }).click();

await page.getByRole('button', { name: /Run all automatic tests/ }).click();
await waitResult('rig-bench', 600000);
console.log('automatic done');

// Pointer lab: simulate a few mouse and touch strokes to exercise the code path.
await clickRun('Apple Pencil & touch input');
await page.locator('canvas.pointer-box').scrollIntoViewIfNeeded();
await page.waitForTimeout(1200); // let smooth scrolling settle
const box = await page.locator('canvas.pointer-box').boundingBox();
await page.mouse.move(box.x + 20, box.y + 20);
await page.mouse.down();
for (let i = 0; i < 40; i++) await page.mouse.move(box.x + 20 + i * 8, box.y + 20 + Math.sin(i / 4) * 40);
await page.mouse.up();
// a touch tap via CDP-backed touchscreen
await page.touchscreen.tap(box.x + 200, box.y + 150);
await page.screenshot({ path: `${out}/pointer-lab.png` });
await page.getByRole('button', { name: /Finish & save input/ }).click();
await waitResult('pointer-lab', 10000);

// PSD presets.
await clickRun('PSD import');
await page.getByRole('button', { name: /Run synthetic presets/ }).click();
await page.getByRole('button', { name: /Synthetic presets done/ }).waitFor({ timeout: 600000 });
await page.getByRole('button', { name: 'Finish' }).click();
await waitResult('psd-import', 10000);

// GPU stress, 1 GB cap (container GPU is software; this exercises the code path only).
await clickRun('GPU texture memory ceiling');
await page.getByRole('button', { name: 'Up to 1 GB' }).click();
await waitResult('stress-gpu', 300000);

await page.evaluate(() => window.scrollTo(0, 0));
await page.screenshot({ path: `${out}/lab-overview.png`, fullPage: true });
fs.writeFileSync(`${out}/report.json`, JSON.stringify(await report(), null, 2));
fs.writeFileSync(`${out}/errors.json`, JSON.stringify(errors, null, 2));
console.log('errors:', errors.length);
await browser.close();
