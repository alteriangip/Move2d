// Converts the single-file Vite build into the artifact page format: the
// claude.ai publisher adds its own doctype/html/head/body skeleton, so the
// page is emitted as <title> + metas + <style> + body content + inline script.
import fs from 'node:fs';

const src = process.argv[2] ?? 'dist/index.html';
const dst = process.argv[3] ?? 'dist/artifact.html';
const html = fs.readFileSync(src, 'utf8');
const pick = (re) => [...html.matchAll(re)].map((m) => m[0]);
const title = pick(/<title>[\s\S]*?<\/title>/g)[0] ?? '<title>OpenLive Platform Lab</title>';
const fonts = pick(/<link rel="(?:preconnect|stylesheet)" href="https:\/\/fonts\.[^"]+"[^>]*>/g);
const styles = pick(/<style[^>]*>[\s\S]*?<\/style>/g);
const scripts = pick(/<script type="module"[^>]*>[\s\S]*?<\/script>/g);
const body = html.match(/<body>([\s\S]*?)<\/body>/)?.[1] ?? '';
const bodyNoScripts = body.replace(/<script[\s\S]*?<\/script>/g, '').trim();
const out = [
  title,
  '<meta name="claude:viewport-fit-sides" content="cover">',
  ...fonts,
  ...styles,
  bodyNoScripts,
  ...scripts,
].join('\n');
fs.writeFileSync(dst, out);
console.log(`${dst}: ${(out.length / 1024).toFixed(1)} KB (scripts: ${scripts.length}, styles: ${styles.length})`);
