/**
 * Environment and feature detection. Every check is a real probe where one
 * is possible (e.g. actually spawning a worker), not just `typeof` tests.
 */
import { storageWorks } from './report';

type Probe = boolean | string | number | null | Record<string, unknown>;

function has(path: string): boolean {
  // Walk globalThis by property path (no eval, so it works under strict CSPs).
  let o: unknown = globalThis;
  for (const k of path.split('.')) {
    if (o == null || !(k in (o as object))) return false;
    o = (o as Record<string, unknown>)[k];
  }
  return typeof o !== 'undefined';
}

/** Minimal SIMD module (v128.const + drop) used to probe WebAssembly SIMD. */
const SIMD_WASM = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 22, 1, 20, 0, 253, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 26, 11,
]);

function workerProbe(src: string, timeoutMs = 3000): Promise<Probe> {
  return new Promise((resolve) => {
    let url = '';
    try {
      url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
      const w = new Worker(url, { type: 'module' });
      const t = setTimeout(() => {
        w.terminate();
        resolve('timeout');
      }, timeoutMs);
      w.onmessage = (e) => {
        clearTimeout(t);
        w.terminate();
        resolve(e.data as Probe);
      };
      w.onerror = (e) => {
        clearTimeout(t);
        w.terminate();
        resolve(`error: ${(e as ErrorEvent).message || 'worker failed to start'}`);
      };
    } catch (e) {
      resolve(`blocked: ${(e as Error).message}`);
    } finally {
      if (url) setTimeout(() => URL.revokeObjectURL(url), 5000);
    }
  });
}

/** Collects the environment section of the report. */
export async function collectEnv(): Promise<Record<string, unknown>> {
  const nav = navigator as Navigator & { standalone?: boolean; deviceMemory?: number; userAgentData?: unknown };
  let embedded = false;
  try {
    embedded = window.top !== window.self;
  } catch {
    embedded = true;
  }
  const mm = (q: string) => (typeof matchMedia !== 'undefined' ? matchMedia(q).matches : null);

  const features: Record<string, Probe> = {
    pointerEvents: has('PointerEvent'),
    getCoalescedEvents: has('PointerEvent') && 'getCoalescedEvents' in PointerEvent.prototype,
    getPredictedEvents: has('PointerEvent') && 'getPredictedEvents' in PointerEvent.prototype,
    touchEvents: has('TouchEvent'),
    gestureEvents: 'ongesturestart' in window,
    offscreenCanvas: has('OffscreenCanvas'),
    createImageBitmap: has('createImageBitmap'),
    imageDecoder: has('ImageDecoder'),
    webCodecsVideoEncoder: has('VideoEncoder'),
    videoFrame: has('VideoFrame'),
    mediaRecorder: has('MediaRecorder'),
    canvasCaptureStream: 'captureStream' in HTMLCanvasElement.prototype,
    compressionStream: has('CompressionStream'),
    webShare: 'share' in navigator,
    webShareFiles: (() => {
      try {
        return !!navigator.canShare?.({ files: [new File(['x'], 'x.txt', { type: 'text/plain' })] });
      } catch {
        return false;
      }
    })(),
    showOpenFilePicker: has('showOpenFilePicker'),
    showSaveFilePicker: has('showSaveFilePicker'),
    opfs: !!navigator.storage?.getDirectory,
    storagePersist: !!navigator.storage?.persist,
    storageEstimate: !!navigator.storage?.estimate,
    indexedDB: has('indexedDB'),
    localStorageWorks: storageWorks(),
    serviceWorker: 'serviceWorker' in navigator,
    webAssembly: has('WebAssembly'),
    wasmSimd: (() => {
      try {
        return WebAssembly.validate(SIMD_WASM);
      } catch {
        return false;
      }
    })(),
    wasmInstantiate: await (async () => {
      try {
        await WebAssembly.instantiate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
        return true;
      } catch (e) {
        return `blocked: ${(e as Error).message}`;
      }
    })(),
    sharedArrayBuffer: has('SharedArrayBuffer'),
    crossOriginIsolated: (self as unknown as { crossOriginIsolated?: boolean }).crossOriginIsolated ?? false,
    performanceMemory: 'memory' in performance,
    measureUserAgentSpecificMemory: 'measureUserAgentSpecificMemory' in performance,
    requestIdleCallback: has('requestIdleCallback'),
    schedulerYield: has('scheduler') && 'yield' in (globalThis as unknown as { scheduler: object }).scheduler,
    visualViewport: has('visualViewport'),
    screenOrientation: !!screen.orientation,
    vibrate: 'vibrate' in navigator,
    getUserMedia: !!navigator.mediaDevices?.getUserMedia,
    audioWorklet: has('AudioWorkletNode'),
  };

  const workers = {
    moduleWorker: await workerProbe(`postMessage('ok')`),
    offscreenWebgl2InWorker: await workerProbe(
      `try{const c=new OffscreenCanvas(4,4);const g=c.getContext('webgl2');postMessage(g?'ok':'null-context')}catch(e){postMessage('error: '+e.message)}`,
    ),
    offscreen2dInWorker: await workerProbe(
      `try{const c=new OffscreenCanvas(4,4);const g=c.getContext('2d');postMessage(g?'ok':'null-context')}catch(e){postMessage('error: '+e.message)}`,
    ),
    indexedDBInWorker: await workerProbe(`postMessage(typeof indexedDB!=='undefined'?'ok':'missing')`),
    createImageBitmapInWorker: await workerProbe(`postMessage(typeof createImageBitmap!=='undefined'?'ok':'missing')`),
    videoEncoderInWorker: await workerProbe(`postMessage(typeof VideoEncoder!=='undefined'?'ok':'missing')`),
  };

  return {
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    maxTouchPoints: navigator.maxTouchPoints,
    hardwareConcurrency: navigator.hardwareConcurrency,
    deviceMemory: nav.deviceMemory ?? null,
    language: navigator.language,
    screen: { width: screen.width, height: screen.height, availWidth: screen.availWidth, availHeight: screen.availHeight },
    devicePixelRatio: devicePixelRatio,
    viewport: { innerWidth, innerHeight },
    orientation: screen.orientation?.type ?? null,
    displayMode: {
      standalone: nav.standalone ?? null,
      mediaStandalone: mm('(display-mode: standalone)'),
      pointerCoarse: mm('(pointer: coarse)'),
      anyPointerFine: mm('(any-pointer: fine)'),
      hoverNone: mm('(hover: none)'),
      prefersDark: mm('(prefers-color-scheme: dark)'),
    },
    hosting: {
      embeddedInFrame: embedded,
      origin: location.origin,
      secureContext: isSecureContext,
    },
    features,
    workers,
  };
}
