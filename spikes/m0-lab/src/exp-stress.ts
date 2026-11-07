/**
 * Memory ceiling probes. These are designed to push until something fails:
 * a WebGL OUT_OF_MEMORY / context loss, a RangeError — or the OS killing the
 * tab. Each step writes a breadcrumb first, so a kill is still recorded.
 */
import type { Ctx, Experiment } from './experiment';
import { round, sleep, MB } from './experiment';
import { compile, GL_ERRORS } from './gl-util';

const TEX = 2048; // 16 MB per RGBA8 texture

function capFromPanel(ctx: Ctx, def: number, label: string): Promise<number> {
  return new Promise((resolve) => {
    ctx.panel.innerHTML = '';
    const wrap = document.createElement('div');
    wrap.className = 'choice';
    const p = document.createElement('p');
    p.textContent = `${label} The page may be reloaded by iPadOS; if so, simply reopen the lab — the result is recovered automatically.`;
    wrap.append(p);
    for (const cap of [1024, 2048, 3072, 4096]) {
      const b = document.createElement('button');
      b.textContent = `Up to ${cap / 1024} GB`;
      if (cap === def) b.className = 'primary';
      b.onclick = () => resolve(cap);
      wrap.append(b);
    }
    ctx.panel.append(wrap);
  });
}

export const gpuStress: Experiment = {
  id: 'stress-gpu',
  title: 'GPU texture memory ceiling',
  summary: 'Allocates 16 MB textures (and draws with each, so they are really resident) until failure or the chosen cap.',
  risky: true,
  async run(ctx) {
    const cap = await capFromPanel(ctx, 4096, 'Allocates GPU textures until failure.');
    ctx.panel.innerHTML = '';
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 1;
    const gl = canvas.getContext('webgl2', { antialias: false });
    if (!gl) return { webgl2: false };
    let lost = false;
    canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      lost = true;
    });
    const prog = compile(
      gl,
      `#version 300 es
      void main(){ gl_Position = vec4(0,0,0,1); gl_PointSize = 1.0; }`,
      `#version 300 es
      precision mediump float; uniform sampler2D t; out vec4 c;
      void main(){ c = texture(t, vec2(0.5)); }`,
    );
    gl.useProgram(prog);
    const data = new Uint8Array(TEX * TEX * 4);
    const textures: WebGLTexture[] = [];
    const stepMs: number[] = [];
    let failure: string | null = null;
    const px = new Uint8Array(4);
    const maxSteps = Math.floor(cap / 16);
    for (let i = 0; i < maxSteps; i++) {
      const mb = (i + 1) * 16;
      ctx.crumb(i, { phase: 'allocating', attemptedMB: mb, reachedMB: i * 16, capMB: cap });
      if (i % 8 === 0) ctx.log(`GPU textures: ${i * 16} MB resident`);
      const t0 = performance.now();
      data.fill(i & 255, 0, 4096); // vary content cheaply
      const tex = gl.createTexture();
      if (!tex) {
        failure = 'createTexture returned null';
        break;
      }
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, TEX, TEX, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
      gl.drawArrays(gl.POINTS, 0, 1);
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); // forces residency
      const err = gl.getError();
      stepMs.push(performance.now() - t0);
      textures.push(tex);
      if (err !== gl.NO_ERROR) {
        failure = `glError ${GL_ERRORS[err] ?? err} at ${mb} MB`;
        break;
      }
      if (lost || gl.isContextLost()) {
        failure = `context lost at ${mb} MB`;
        break;
      }
      await sleep(5);
    }
    const reachedMB = textures.length * 16;
    ctx.crumb(-1, { phase: 'releasing', reachedMB });
    for (const t of textures) gl.deleteTexture(t);
    gl.getExtension('WEBGL_lose_context')?.loseContext();
    return {
      textureSize: TEX,
      bytesPerTexture: TEX * TEX * 4,
      capMB: cap,
      reachedMB,
      stoppedBy: failure ?? 'cap reached (no failure)',
      firstStepMs: round(stepMs[0] ?? 0),
      medianStepMs: round(stepMs.slice().sort((a, b) => a - b)[Math.floor(stepMs.length / 2)] ?? 0),
      lastStepMs: round(stepMs[stepMs.length - 1] ?? 0),
    };
  },
};

export const heapStress: Experiment = {
  id: 'stress-heap',
  title: 'JS memory ceiling (ArrayBuffers)',
  summary: 'Allocates and touches 64 MB ArrayBuffers until RangeError, an OS kill, or the chosen cap.',
  risky: true,
  async run(ctx) {
    const cap = await capFromPanel(ctx, 4096, 'Allocates JavaScript memory until failure.');
    ctx.panel.innerHTML = '';
    const CHUNK = 64 * MB;
    const kept: ArrayBuffer[] = [];
    let failure: string | null = null;
    const stepMs: number[] = [];
    for (let i = 0; i < cap / 64; i++) {
      ctx.crumb(i, { phase: 'allocating', attemptedMB: (i + 1) * 64, reachedMB: i * 64, capMB: cap });
      if (i % 4 === 0) ctx.log(`JS heap: ${i * 64} MB held`);
      const t0 = performance.now();
      try {
        const b = new ArrayBuffer(CHUNK);
        const v = new Uint8Array(b);
        for (let o = 0; o < CHUNK; o += 4096) v[o] = 1; // commit every page
        kept.push(b);
      } catch (e) {
        failure = `${(e as Error).name}: ${(e as Error).message} at ${(i + 1) * 64} MB`;
        break;
      }
      stepMs.push(performance.now() - t0);
      await sleep(10);
    }
    const reachedMB = kept.length * 64;
    kept.length = 0;
    return {
      chunkMB: 64,
      capMB: cap,
      reachedMB,
      stoppedBy: failure ?? 'cap reached (no failure)',
      medianStepMs: round(stepMs.slice().sort((a, b) => a - b)[Math.floor(stepMs.length / 2)] ?? 0),
    };
  },
};
