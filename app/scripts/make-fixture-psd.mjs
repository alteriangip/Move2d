// Generates fixtures/character.psd: a small layered "character" with groups,
// hidden layer, opacity, multiply blend, a clipped layer and an unsupported blend mode.
import fs from 'node:fs';
import { writePsd } from 'ag-psd';

const W = 600, H = 800;
function blob(w, h, rgb, shape = 'ellipse') {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const u = (x + 0.5) / w * 2 - 1, v = (y + 0.5) / h * 2 - 1;
    const inside = shape === 'rect' ? 1 : Math.max(0, Math.min(1, (1 - Math.hypot(u, v)) * Math.min(w, h) / 3));
    if (!inside) continue;
    const o = (y * w + x) * 4;
    data[o] = rgb[0]; data[o + 1] = rgb[1]; data[o + 2] = rgb[2]; data[o + 3] = Math.round(inside * 255);
  }
  return { width: w, height: h, data };
}
const layer = (name, left, top, w, h, rgb, extra = {}) => ({ name, left, top, right: left + w, bottom: top + h, imageData: blob(w, h, rgb, extra.shape), ...extra });
const psd = {
  width: W, height: H, channels: 3, bitsPerChannel: 8, colorMode: 3,
  children: [
    { name: 'Head', opened: true, children: [
      layer('Eye L', 220, 200, 50, 40, [30, 60, 120]),
      layer('Eye R', 330, 200, 50, 40, [30, 60, 120]),
      layer('Blush', 200, 250, 200, 40, [230, 120, 140], { opacity: 0.5, blendMode: 'multiply' }),
      layer('Face', 170, 110, 260, 260, [250, 220, 200]),
    ] },
    { name: 'Body', opened: true, children: [
      layer('Shading', 200, 380, 200, 300, [80, 80, 160], { clipping: true, blendMode: 'overlay' }),
      layer('Shirt', 180, 360, 240, 340, [70, 140, 200], { shape: 'rect' }),
    ] },
    layer('Sketch (hidden)', 0, 0, 600, 800, [200, 200, 200], { hidden: true, shape: 'rect' }),
  ],
};
const buf = writePsd(psd, { noBackground: true, generateThumbnail: false });
fs.writeFileSync('fixtures/character.psd', Buffer.from(buf));
console.log('fixtures/character.psd', buf.byteLength, 'bytes');
