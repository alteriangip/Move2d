/**
 * ag-psd needs a canvas factory to create ImageData. Outside a document
 * (Web Workers, Node) it has none and — in eager mode — silently drops layer
 * pixels. We install a canvas-free ImageData factory everywhere so decoding
 * behaves identically on the main thread, in workers and in tests.
 */
import { initializeCanvas } from 'ag-psd';

type PlainImageData = { width: number; height: number; data: Uint8ClampedArray };

const createImageData = (w: number, h: number): ImageData => {
  if (typeof ImageData !== 'undefined') return new ImageData(w, h);
  return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) } as PlainImageData as unknown as ImageData;
};

const createCanvas = (w: number, h: number): HTMLCanvasElement => {
  if (typeof document !== 'undefined') {
    const c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    return c;
  }
  if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(w, h) as unknown as HTMLCanvasElement;
  throw new Error('No canvas implementation available');
};

initializeCanvas(createCanvas, createImageData);
