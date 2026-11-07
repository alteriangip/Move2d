/**
 * WebGL2 experiments: capabilities, transform feedback (the GPU-deformation
 * escalation path), context loss/restore, and the texture pipeline
 * (PNG encode → decode → upload) that import and context-restore depend on.
 */
import type { Ctx, Experiment } from './experiment';
import { round, sleep, MB } from './experiment';
import { compile, sync, paintAtlas } from './gl-util';

function ctx2(canvas: HTMLCanvasElement | OffscreenCanvas): WebGL2RenderingContext | null {
  return canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: true, powerPreference: 'high-performance' }) as WebGL2RenderingContext | null;
}

/** Verifies transform feedback works by running a doubling shader and reading back. */
function transformFeedbackProbe(gl: WebGL2RenderingContext): Record<string, unknown> {
  const N = 100_000;
  const vs = `#version 300 es
  in vec2 a; out vec2 o;
  void main(){ o = a * 2.0 + vec2(1.0, -1.0); }`;
  const fs = `#version 300 es
  precision mediump float; out vec4 c; void main(){ c = vec4(1); }`;
  const prog = compile(gl, vs, fs, ['o']);
  const src = new Float32Array(N * 2);
  for (let i = 0; i < src.length; i++) src[i] = i % 997;
  const inBuf = gl.createBuffer()!;
  gl.bindBuffer(gl.ARRAY_BUFFER, inBuf);
  gl.bufferData(gl.ARRAY_BUFFER, src, gl.STATIC_DRAW);
  const outBuf = gl.createBuffer()!;
  gl.bindBuffer(gl.ARRAY_BUFFER, outBuf);
  gl.bufferData(gl.ARRAY_BUFFER, src.byteLength, gl.DYNAMIC_READ);
  const vao = gl.createVertexArray()!;
  gl.bindVertexArray(vao);
  gl.bindBuffer(gl.ARRAY_BUFFER, inBuf);
  const loc = gl.getAttribLocation(prog, 'a');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  gl.useProgram(prog);
  const tf = gl.createTransformFeedback()!;
  gl.bindTransformFeedback(gl.TRANSFORM_FEEDBACK, tf);
  gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, outBuf);
  gl.enable(gl.RASTERIZER_DISCARD);
  const t0 = performance.now();
  gl.beginTransformFeedback(gl.POINTS);
  gl.drawArrays(gl.POINTS, 0, N);
  gl.endTransformFeedback();
  gl.disable(gl.RASTERIZER_DISCARD);
  gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, null);
  const out = new Float32Array(N * 2);
  gl.bindBuffer(gl.ARRAY_BUFFER, outBuf);
  gl.getBufferSubData(gl.ARRAY_BUFFER, 0, out);
  const ms = performance.now() - t0;
  let bad = 0;
  for (let i = 0; i < N * 2; i++) if (Math.abs(out[i] - (src[i] * 2 + (i % 2 === 0 ? 1 : -1))) > 1e-3) bad++;
  gl.deleteBuffer(inBuf);
  gl.deleteBuffer(outBuf);
  gl.deleteTransformFeedback(tf);
  gl.deleteVertexArray(vao);
  gl.deleteProgram(prog);
  return { works: bad === 0, mismatches: bad, vertices: N, roundTripMsIncludingReadback: round(ms) };
}

export const webglCaps: Experiment = {
  id: 'webgl-caps',
  title: 'WebGL2 capabilities',
  summary: 'Limits, extensions, compressed formats, and a working transform-feedback test (the GPU-deformation path).',
  async run() {
    const canvas = document.createElement('canvas');
    const gl = ctx2(canvas);
    if (!gl) return { webgl2: false };
    const p = (n: number) => {
      const v = gl.getParameter(n);
      return v instanceof Int32Array || v instanceof Float32Array ? Array.from(v) : v;
    };
    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    const astc = gl.getExtension('WEBGL_compressed_texture_astc') as { getSupportedProfiles?: () => string[] } | null;
    const exts = gl.getSupportedExtensions() ?? [];
    const attrs = gl.getContextAttributes();
    return {
      webgl2: true,
      vendor: p(gl.VENDOR),
      renderer: p(gl.RENDERER),
      unmaskedVendor: dbg ? p(dbg.UNMASKED_VENDOR_WEBGL) : null,
      unmaskedRenderer: dbg ? p(dbg.UNMASKED_RENDERER_WEBGL) : null,
      version: p(gl.VERSION),
      glsl: p(gl.SHADING_LANGUAGE_VERSION),
      limits: {
        MAX_TEXTURE_SIZE: p(gl.MAX_TEXTURE_SIZE),
        MAX_RENDERBUFFER_SIZE: p(gl.MAX_RENDERBUFFER_SIZE),
        MAX_VIEWPORT_DIMS: p(gl.MAX_VIEWPORT_DIMS),
        MAX_SAMPLES: p(gl.MAX_SAMPLES),
        MAX_TEXTURE_IMAGE_UNITS: p(gl.MAX_TEXTURE_IMAGE_UNITS),
        MAX_VERTEX_TEXTURE_IMAGE_UNITS: p(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS),
        MAX_VERTEX_ATTRIBS: p(gl.MAX_VERTEX_ATTRIBS),
        MAX_VARYING_VECTORS: p(gl.MAX_VARYING_VECTORS),
        MAX_VERTEX_UNIFORM_VECTORS: p(gl.MAX_VERTEX_UNIFORM_VECTORS),
        MAX_UNIFORM_BLOCK_SIZE: p(gl.MAX_UNIFORM_BLOCK_SIZE),
        MAX_DRAW_BUFFERS: p(gl.MAX_DRAW_BUFFERS),
        MAX_ARRAY_TEXTURE_LAYERS: p(gl.MAX_ARRAY_TEXTURE_LAYERS),
        MAX_3D_TEXTURE_SIZE: p(gl.MAX_3D_TEXTURE_SIZE),
        MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: p(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS),
        MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: p(gl.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS),
        MAX_ELEMENT_INDEX: p(gl.MAX_ELEMENT_INDEX),
        ALIASED_LINE_WIDTH_RANGE: p(gl.ALIASED_LINE_WIDTH_RANGE),
      },
      contextAttributes: attrs,
      extensions: exts,
      compressed: {
        astc: !!astc,
        astcProfiles: astc?.getSupportedProfiles?.() ?? null,
        etc: exts.includes('WEBGL_compressed_texture_etc'),
        etc1: exts.includes('WEBGL_compressed_texture_etc1'),
        s3tc: exts.includes('WEBGL_compressed_texture_s3tc'),
        pvrtc: exts.includes('WEBGL_compressed_texture_pvrtc'),
        bptc: exts.includes('EXT_texture_compression_bptc'),
      },
      colorBufferFloat: exts.includes('EXT_color_buffer_float'),
      colorBufferHalfFloat: exts.includes('EXT_color_buffer_half_float'),
      floatLinear: exts.includes('OES_texture_float_linear'),
      gpuTimerQuery: exts.includes('EXT_disjoint_timer_query_webgl2'),
      transformFeedback: transformFeedbackProbe(gl),
    };
  },
};

export const contextLoss: Experiment = {
  id: 'webgl-context-loss',
  title: 'WebGL context loss & restore',
  summary: 'Simulates context loss, measures restore latency and the cost of rebuilding a 2048² texture.',
  async run() {
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 64;
    const gl = ctx2(canvas);
    if (!gl) return { webgl2: false };
    const ext = gl.getExtension('WEBGL_lose_context');
    if (!ext) return { loseContextExtension: false };
    const events: string[] = [];
    let lostAt = 0,
      restoredAt = 0;
    canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault(); // required to allow restore
      lostAt = performance.now();
      events.push('lost');
    });
    canvas.addEventListener('webglcontextrestored', () => {
      restoredAt = performance.now();
      events.push('restored');
    });
    const t0 = performance.now();
    ext.loseContext();
    await sleep(50);
    const isLost = gl.isContextLost();
    const t1 = performance.now();
    ext.restoreContext();
    for (let i = 0; i < 100 && !restoredAt; i++) await sleep(20);
    const data = new Uint8Array(2048 * 2048 * 4).fill(128);
    const t2 = performance.now();
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 2048, 2048, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
    sync(gl);
    const rebuildMs = performance.now() - t2;
    gl.deleteTexture(tex);
    return {
      loseContextExtension: true,
      events,
      lostEventLatencyMs: lostAt ? round(lostAt - t0) : null,
      isContextLostAfterLose: isLost,
      restoreLatencyMs: restoredAt ? round(restoredAt - t1) : null,
      contextUsableAfterRestore: !gl.isContextLost(),
      rebuild2048TextureMs: round(rebuildMs),
    };
  },
};

async function timeIt<T>(f: () => Promise<T> | T): Promise<[T, number]> {
  const t = performance.now();
  const v = await f();
  return [v, performance.now() - t];
}

export const texturePipeline: Experiment = {
  id: 'texture-pipeline',
  title: 'Texture pipeline (PNG encode / decode / upload)',
  summary: 'Times the import and restore path at 2048² and 4096²: PNG encode, createImageBitmap decode, GPU upload.',
  async run(ctx: Ctx) {
    const out: Record<string, unknown> = {};
    const glCanvas = document.createElement('canvas');
    glCanvas.width = glCanvas.height = 4;
    const gl = ctx2(glCanvas);
    for (const size of [2048, 4096]) {
      ctx.log(`texture pipeline ${size}²`);
      const [atlas, paintMs] = await timeIt(() => paintAtlas(size));
      const [blob, encMs] = await timeIt(
        () => new Promise<Blob>((res, rej) => atlas.toBlob((b) => (b ? res(b) : rej(new Error('toBlob failed'))), 'image/png')),
      );
      let offEncMs: number | null = null;
      if (typeof OffscreenCanvas !== 'undefined') {
        const oc = new OffscreenCanvas(size, size);
        oc.getContext('2d')!.drawImage(atlas, 0, 0);
        [, offEncMs] = await timeIt(() => oc.convertToBlob({ type: 'image/png' }));
      }
      const [bmp, decMs] = await timeIt(() => createImageBitmap(blob, { premultiplyAlpha: 'premultiply', colorSpaceConversion: 'none' }));
      let uploadBitmapMs: number | null = null,
        uploadArrayMs: number | null = null,
        getImageDataMs: number | null = null;
      if (gl) {
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
        [, uploadBitmapMs] = await timeIt(() => {
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, bmp);
          sync(gl);
        });
        const [id, gidMs] = await timeIt(() => atlas.getContext('2d')!.getImageData(0, 0, size, size));
        getImageDataMs = gidMs;
        [, uploadArrayMs] = await timeIt(() => {
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, size, size, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(id.data.buffer));
          sync(gl);
        });
        gl.deleteTexture(tex);
      }
      bmp.close();
      atlas.width = atlas.height = 0; // release backing store
      out[`s${size}`] = {
        paintMs: round(paintMs),
        pngEncodeCanvasMs: round(encMs),
        pngEncodeOffscreenMs: offEncMs === null ? null : round(offEncMs),
        pngBytes: blob.size,
        pngMB: round(blob.size / MB),
        decodeCreateImageBitmapMs: round(decMs),
        uploadFromImageBitmapMs: uploadBitmapMs === null ? null : round(uploadBitmapMs),
        getImageDataMs: getImageDataMs === null ? null : round(getImageDataMs),
        uploadFromTypedArrayMs: uploadArrayMs === null ? null : round(uploadArrayMs),
      };
      ctx.partial(out);
      await sleep(50);
    }
    return out;
  },
};
