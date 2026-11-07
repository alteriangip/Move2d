/**
 * Rig evaluation + rendering benchmark.
 *
 * Answers: "At what model size does CPU deformation stop fitting the frame
 * budget on this device, i.e. when does GPU deformation become necessary?"
 *
 * For each preset it measures, over a fixed duration:
 *  - eval:   CPU keyform blending + deformer chain (all objects dirty — worst case)
 *  - upload: bufferSubData of all world positions
 *  - submit: CPU time issuing one draw call per ArtMesh
 *  - frame:  rAF-to-rAF interval (what the user feels)
 * plus a render-only pass (static geometry) to isolate GPU/fill cost, at
 * render scales 1.0 and 0.5 of devicePixelRatio.
 */
import type { Ctx, Experiment } from './experiment';
import { round, sleep, raf } from './experiment';
import { buildRig, evaluateRig, animateParams, PRESETS, type Rig } from './rig-kernel';
import { summarize, linearFit } from './stats';
import { compile, paintAtlas } from './gl-util';

const VS = `#version 300 es
in vec2 a_pos; in vec2 a_uv;
uniform vec2 u_scale; uniform vec2 u_offset;
out vec2 v_uv;
void main(){ v_uv = a_uv; vec2 p = a_pos * u_scale + u_offset; gl_Position = vec4(p.x, -p.y, 0, 1); }`;
const FS = `#version 300 es
precision mediump float;
in vec2 v_uv; uniform sampler2D u_tex; uniform float u_opacity; out vec4 o;
void main(){ o = texture(u_tex, v_uv) * u_opacity; }`;

interface Pass {
  preset: string;
  mode: 'full' | 'render-only';
  renderScale: number;
  vertices: number;
  triangles: number;
  drawCalls: number;
  backbuffer: string;
  frames: number;
  fps: number;
  longFrames20ms: number;
  frameMs: ReturnType<typeof summarize>;
  evalMs?: ReturnType<typeof summarize>;
  uploadMs?: ReturnType<typeof summarize>;
  submitMs: ReturnType<typeof summarize>;
}

class Bench {
  gl: WebGL2RenderingContext;
  prog: WebGLProgram;
  tex: WebGLTexture;
  uScale: WebGLUniformLocation;
  uOffset: WebGLUniformLocation;
  uOpacity: WebGLUniformLocation;
  constructor(readonly canvas: HTMLCanvasElement) {
    const gl = canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: true, alpha: false, powerPreference: 'high-performance' });
    if (!gl) throw new Error('WebGL2 unavailable');
    this.gl = gl;
    this.prog = compile(gl, VS, FS);
    this.uScale = gl.getUniformLocation(this.prog, 'u_scale')!;
    this.uOffset = gl.getUniformLocation(this.prog, 'u_offset')!;
    this.uOpacity = gl.getUniformLocation(this.prog, 'u_opacity')!;
    const atlas = paintAtlas(4096);
    this.tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, atlas);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    atlas.width = atlas.height = 0;
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  }

  setup(rig: Rig) {
    const gl = this.gl;
    const vao = gl.createVertexArray()!;
    gl.bindVertexArray(vao);
    const pos = gl.createBuffer()!;
    gl.bindBuffer(gl.ARRAY_BUFFER, pos);
    gl.bufferData(gl.ARRAY_BUFFER, rig.world.byteLength, gl.DYNAMIC_DRAW);
    const lp = gl.getAttribLocation(this.prog, 'a_pos');
    gl.enableVertexAttribArray(lp);
    gl.vertexAttribPointer(lp, 2, gl.FLOAT, false, 0, 0);
    const uv = gl.createBuffer()!;
    gl.bindBuffer(gl.ARRAY_BUFFER, uv);
    gl.bufferData(gl.ARRAY_BUFFER, rig.uvs, gl.STATIC_DRAW);
    const lu = gl.getAttribLocation(this.prog, 'a_uv');
    gl.enableVertexAttribArray(lu);
    gl.vertexAttribPointer(lu, 2, gl.FLOAT, false, 0, 0);
    const ib = gl.createBuffer()!;
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, rig.indices, gl.STATIC_DRAW);
    return {
      pos,
      dispose: () => {
        gl.deleteBuffer(pos);
        gl.deleteBuffer(uv);
        gl.deleteBuffer(ib);
        gl.deleteVertexArray(vao);
      },
    };
  }

  resize(scale: number) {
    const dpr = devicePixelRatio || 1;
    const w = Math.round(this.canvas.clientWidth * dpr * scale);
    const h = Math.round(this.canvas.clientHeight * dpr * scale);
    this.canvas.width = w;
    this.canvas.height = h;
    this.gl.viewport(0, 0, w, h);
    return `${w}×${h}`;
  }

  draw(rig: Rig) {
    const gl = this.gl;
    // Fit the rig canvas into the viewport (aspect-correct).
    const cw = this.canvas.width,
      ch = this.canvas.height;
    const s = Math.min(cw / rig.canvasW, ch / rig.canvasH) * 0.95;
    const sx = (2 * s) / cw,
      sy = (2 * s) / ch;
    gl.clearColor(0.1, 0.1, 0.12, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(this.prog);
    gl.uniform2f(this.uScale, sx, sy);
    gl.uniform2f(this.uOffset, -rig.canvasW * 0.5 * sx, -rig.canvasH * 0.5 * sy);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    for (let m = 0; m < rig.meshForms.length; m++) {
      gl.uniform1f(this.uOpacity, 0.6 + 0.4 * ((m * 7) % 5) / 4);
      gl.drawElements(gl.TRIANGLES, rig.meshIndexCount[m], gl.UNSIGNED_INT, rig.meshIndexOffset[m] * 4);
    }
  }
}

async function runPass(
  bench: Bench,
  rig: Rig,
  name: string,
  mode: Pass['mode'],
  renderScale: number,
  seconds: number,
  label: HTMLElement,
  signal: AbortSignal,
): Promise<Pass> {
  const backbuffer = bench.resize(renderScale);
  const gl = bench.gl;
  const buffers = bench.setup(rig);
  animateParams(rig, 0);
  evaluateRig(rig);
  gl.bindBuffer(gl.ARRAY_BUFFER, buffers.pos);
  gl.bufferSubData(gl.ARRAY_BUFFER, 0, rig.world);
  const frame: number[] = [],
    ev: number[] = [],
    up: number[] = [],
    sub: number[] = [];
  let last = await raf();
  const warmUntil = last + 500;
  const endAt = warmUntil + seconds * 1000;
  let long = 0;
  label.textContent = `${name} · ${mode} · scale ${renderScale} · ${rig.totalVertices.toLocaleString()} vertices`;
  for (;;) {
    if (signal.aborted) break;
    const now = await raf();
    const warm = now < warmUntil;
    if (!warm) {
      const dt = now - last;
      frame.push(dt);
      if (dt > 20) long++;
    }
    last = now;
    if (now > endAt) break;
    if (mode === 'full') {
      const t0 = performance.now();
      animateParams(rig, now / 1000);
      evaluateRig(rig);
      const t1 = performance.now();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffers.pos);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, rig.world);
      const t2 = performance.now();
      if (!warm) {
        ev.push(t1 - t0);
        up.push(t2 - t1);
      }
    }
    const t3 = performance.now();
    bench.draw(rig);
    if (!warm) sub.push(performance.now() - t3);
  }
  buffers.dispose();
  const durS = frame.reduce((a, b) => a + b, 0) / 1000;
  return {
    preset: name,
    mode,
    renderScale,
    vertices: rig.totalVertices,
    triangles: rig.totalTriangles,
    drawCalls: rig.meshForms.length,
    backbuffer,
    frames: frame.length,
    fps: round(frame.length / durS, 1),
    longFrames20ms: long,
    frameMs: summarize(frame),
    evalMs: mode === 'full' ? summarize(ev) : undefined,
    uploadMs: mode === 'full' ? summarize(up) : undefined,
    submitMs: summarize(sub),
  };
}

/** Pure CPU throughput: evaluates the rig back-to-back (no rendering). */
async function evalOnly(rig: Rig, ms: number): Promise<ReturnType<typeof summarize>> {
  const s: number[] = [];
  let t = 0;
  // Warm-up (discarded) so JIT tier-up does not pollute the first preset's numbers.
  const warmEnd = performance.now() + 400;
  while (performance.now() < warmEnd) {
    animateParams(rig, (t += 0.016));
    evaluateRig(rig);
    await sleep(0);
  }
  // Each sample times a batch of 10 evaluations and divides, so a 1 ms timer
  // resolution (Safari in cross-origin frames) still yields sub-millisecond precision.
  const end = performance.now() + ms;
  while (performance.now() < end) {
    const t0 = performance.now();
    for (let k = 0; k < 10; k++) {
      animateParams(rig, (t += 0.016));
      evaluateRig(rig);
    }
    s.push((performance.now() - t0) / 10);
    await sleep(0);
  }
  return summarize(s);
}

export const rigBench: Experiment = {
  id: 'rig-bench',
  title: 'Rig deformation + rendering benchmark',
  summary:
    'CPU keyform/deformer evaluation and WebGL2 rendering at 30k → 240k vertices. Decides when GPU deformation becomes necessary. ~60 s.',
  async run(ctx: Ctx) {
    const overlay = document.createElement('div');
    overlay.className = 'bench-overlay';
    const canvas = document.createElement('canvas');
    const label = document.createElement('div');
    label.className = 'bench-label';
    const stop = document.createElement('button');
    stop.textContent = 'Stop';
    const ac = new AbortController();
    stop.onclick = () => ac.abort();
    ctx.signal.addEventListener('abort', () => ac.abort());
    overlay.append(canvas, label, stop);
    document.body.append(overlay);
    const passes: Pass[] = [];
    const evalOnlyRes: Record<string, unknown> = {};
    try {
      const bench = new Bench(canvas);
      const plan: [string, Pass['mode'], number, number][] = [
        ['target', 'full', 1, 5],
        ['target', 'full', 0.5, 4],
        ['target', 'render-only', 1, 4],
        ['x2', 'full', 1, 4],
        ['x4', 'full', 1, 4],
        ['x4', 'render-only', 1, 3],
        ['x8', 'full', 1, 4],
        ['x8', 'full', 0.5, 3],
      ];
      for (const [name, mode, scale, secs] of plan) {
        if (ac.signal.aborted) break;
        ctx.crumb(passes.length, { pass: `${name}/${mode}/${scale}` });
        const rig = buildRig(PRESETS[name]);
        if (!evalOnlyRes[name]) {
          label.textContent = `${name} · CPU eval only`;
          evalOnlyRes[name] = { vertices: rig.totalVertices, evalMs: await evalOnly(rig, 1500) };
        }
        passes.push(await runPass(bench, rig, name, mode, scale, secs, label, ac.signal));
        ctx.partial({ passes, evalOnly: evalOnlyRes });
        ctx.log(`${name} ${mode} @${scale}: ${passes[passes.length - 1].fps} fps`);
      }
      bench.gl.getExtension('WEBGL_lose_context')?.loseContext();
    } finally {
      overlay.remove();
    }

    // Decision support: fit eval p95 vs vertices and find the 4 ms budget crossing.
    const eo = Object.values(evalOnlyRes) as { vertices: number; evalMs: { p95: number; p50: number } }[];
    // Fit on batched means (robust to timer clamping); p95 of batches is reported per preset.
    const fit = eo.length >= 2 ? linearFit(eo.map((e) => e.vertices), eo.map((e) => e.evalMs.p95)) : null;
    const BUDGET = 4;
    const verticesAtBudget = fit && fit.b > 0 ? Math.round((BUDGET - fit.a) / fit.b) : null;
    const target = passes.find((p) => p.preset === 'target' && p.mode === 'full' && p.renderScale === 1);
    return {
      passes,
      evalOnly: evalOnlyRes,
      decision: {
        evalBudgetMs: BUDGET,
        evalP95PerVertexUs: fit ? round(fit.b * 1000, 4) : null,
        evalFixedOverheadMs: fit ? round(fit.a, 3) : null,
        verticesAt4msEvalP95: verticesAtBudget,
        targetModelFps: target?.fps ?? null,
        targetModelEvalP95Ms: target?.evalMs?.p95 ?? null,
        gpuDeformationNeededForTargetModel: target?.evalMs ? target.evalMs.p95 > BUDGET : null,
      },
    };
  },
};
