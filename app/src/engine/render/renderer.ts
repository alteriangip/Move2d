/**
 * WebGL2 renderer.
 *
 * Independent of React and of the editor: it draws a list of textured quads
 * (layers) with opacity and blend modes inside a document rectangle, given a
 * camera transform. Textures are uploaded from PNG/JPEG bytes and can be
 * rebuilt after a WebGL context loss (iPadOS drops contexts under memory
 * pressure).
 */
import type { Affine } from '../math/affine';
import type { BlendMode, Id } from '../model/types';

export interface DrawItem {
  imageId: Id;
  x: number;
  y: number;
  width: number;
  height: number;
  opacity: number;
  blendMode: BlendMode;
}

export interface Frame {
  /** document → screen (device pixels) */
  camera: Affine;
  docWidth: number;
  docHeight: number;
  items: DrawItem[];
  showGrid: boolean;
}

/** Supplies encoded image bytes for a texture (used on first use and after context loss). */
export type ImageSource = (imageId: Id) => { bytes: ArrayBuffer; mime: string } | undefined;

const VS = `#version 300 es
in vec2 a_unit;
uniform mat3 u_cam;      // doc -> device px
uniform vec2 u_view;     // device px size
uniform vec4 u_rect;     // x, y, w, h in doc px
out vec2 v_uv;
out vec2 v_doc;
void main() {
  v_uv = a_unit;
  vec2 doc = u_rect.xy + a_unit * u_rect.zw;
  v_doc = doc;
  vec3 s = u_cam * vec3(doc, 1.0);
  vec2 clip = s.xy / u_view * 2.0 - 1.0;
  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);
}`;

const FS_IMAGE = `#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform float u_opacity;
out vec4 o;
void main() { o = texture(u_tex, v_uv) * u_opacity; }`;

// Canvas background: checkerboard (transparency) plus an optional 64 px grid.
const FS_BG = `#version 300 es
precision mediump float;
in vec2 v_doc;
uniform float u_grid;
uniform float u_pxPerDoc;
out vec4 o;
void main() {
  vec2 c = floor(v_doc / 16.0);
  float k = mod(c.x + c.y, 2.0);
  vec3 col = mix(vec3(0.80), vec3(0.70), k);
  if (u_grid > 0.5) {
    vec2 g = abs(fract(v_doc / 64.0 + 0.5) - 0.5) * 64.0 * u_pxPerDoc;
    float line = 1.0 - smoothstep(0.0, 1.0, min(g.x, g.y));
    col = mix(col, vec3(0.35, 0.55, 0.8), line * 0.5);
  }
  o = vec4(col, 1.0);
}`;

interface Tex {
  tex: WebGLTexture;
  bytes: number;
}

export class Renderer {
  private gl: WebGL2RenderingContext;
  private imgProg!: WebGLProgram;
  private bgProg!: WebGLProgram;
  private vao!: WebGLVertexArrayObject;
  private textures = new Map<Id, Tex>();
  private pending = new Set<Id>();
  private lost = false;
  /** called when an async texture load finishes, so the host can redraw */
  onTextureReady: () => void = () => {};
  onContextChange: (lost: boolean) => void = () => {};

  constructor(
    private canvas: HTMLCanvasElement,
    private source: ImageSource,
  ) {
    const gl = canvas.getContext('webgl2', { antialias: true, premultipliedAlpha: true, alpha: false, powerPreference: 'high-performance' });
    if (!gl) throw new Error('This device does not support WebGL2, which OpenLive requires.');
    this.gl = gl;
    canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      this.lost = true;
      this.textures.clear();
      this.pending.clear();
      this.onContextChange(true);
    });
    canvas.addEventListener('webglcontextrestored', () => {
      this.lost = false;
      this.init();
      this.onContextChange(false);
      this.onTextureReady();
    });
    this.init();
  }

  private init() {
    const gl = this.gl;
    this.imgProg = this.program(VS, FS_IMAGE);
    this.bgProg = this.program(VS, FS_BG);
    this.vao = gl.createVertexArray()!;
    gl.bindVertexArray(this.vao);
    const vb = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vb);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
    for (const p of [this.imgProg, this.bgProg]) {
      const loc = gl.getAttribLocation(p, 'a_unit');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    }
  }

  private program(vs: string, fs: string): WebGLProgram {
    const gl = this.gl;
    const sh = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) ?? 'shader error');
      return s;
    };
    const p = gl.createProgram()!;
    gl.attachShader(p, sh(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs));
    gl.bindAttribLocation(p, 0, 'a_unit');
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p) ?? 'link error');
    return p;
  }

  /** Estimated GPU memory used by textures (bytes, incl. mipmaps). */
  get textureBytes(): number {
    let n = 0;
    for (const t of this.textures.values()) n += t.bytes;
    return n;
  }

  get textureCount(): number {
    return this.textures.size;
  }

  get isLost(): boolean {
    return this.lost;
  }

  /** Frees textures whose image is no longer used. */
  retain(used: Set<Id>) {
    for (const [id, t] of this.textures)
      if (!used.has(id)) {
        this.gl.deleteTexture(t.tex);
        this.textures.delete(id);
      }
  }

  private load(id: Id) {
    if (this.pending.has(id) || this.lost) return;
    const src = this.source(id);
    if (!src) return;
    this.pending.add(id);
    createImageBitmap(new Blob([src.bytes], { type: src.mime }), { premultiplyAlpha: 'none', colorSpaceConversion: 'none' })
      .then((bmp) => {
        this.pending.delete(id);
        if (this.lost) return bmp.close();
        const gl = this.gl;
        const tex = gl.createTexture()!;
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, bmp);
        gl.generateMipmap(gl.TEXTURE_2D);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        this.textures.set(id, { tex, bytes: Math.round(bmp.width * bmp.height * 4 * 1.34) });
        bmp.close();
        this.onTextureReady();
      })
      .catch(() => this.pending.delete(id));
  }

  /** Resizes the drawing buffer to the canvas's CSS size × dpr × scale. */
  resize(scale = 1): { width: number; height: number } {
    const dpr = (window.devicePixelRatio || 1) * scale;
    const w = Math.max(1, Math.round(this.canvas.clientWidth * dpr));
    const h = Math.max(1, Math.round(this.canvas.clientHeight * dpr));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    return { width: w, height: h };
  }

  render(f: Frame): void {
    if (this.lost) return;
    const gl = this.gl;
    const W = this.canvas.width,
      H = this.canvas.height;
    gl.viewport(0, 0, W, H);
    gl.clearColor(0.105, 0.11, 0.13, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.bindVertexArray(this.vao);
    const cam = [f.camera[0], f.camera[1], 0, f.camera[2], f.camera[3], 0, f.camera[4], f.camera[5], 1];

    // background
    gl.disable(gl.BLEND);
    gl.useProgram(this.bgProg);
    gl.uniformMatrix3fv(gl.getUniformLocation(this.bgProg, 'u_cam'), false, cam);
    gl.uniform2f(gl.getUniformLocation(this.bgProg, 'u_view'), W, H);
    gl.uniform4f(gl.getUniformLocation(this.bgProg, 'u_rect'), 0, 0, f.docWidth, f.docHeight);
    gl.uniform1f(gl.getUniformLocation(this.bgProg, 'u_grid'), f.showGrid ? 1 : 0);
    gl.uniform1f(gl.getUniformLocation(this.bgProg, 'u_pxPerDoc'), Math.hypot(f.camera[0], f.camera[1]));
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

    // layers, bottom to top
    gl.enable(gl.BLEND);
    gl.useProgram(this.imgProg);
    const uCam = gl.getUniformLocation(this.imgProg, 'u_cam');
    const uView = gl.getUniformLocation(this.imgProg, 'u_view');
    const uRect = gl.getUniformLocation(this.imgProg, 'u_rect');
    const uOp = gl.getUniformLocation(this.imgProg, 'u_opacity');
    gl.uniformMatrix3fv(uCam, false, cam);
    gl.uniform2f(uView, W, H);
    gl.activeTexture(gl.TEXTURE0);
    for (const it of f.items) {
      const t = this.textures.get(it.imageId);
      if (!t) {
        this.load(it.imageId);
        continue;
      }
      // Premultiplied-alpha blending. Multiply is exact over an opaque backdrop.
      if (it.blendMode === 'additive') gl.blendFunc(gl.ONE, gl.ONE);
      else if (it.blendMode === 'multiply') gl.blendFunc(gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA);
      else gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.bindTexture(gl.TEXTURE_2D, t.tex);
      gl.uniform4f(uRect, it.x, it.y, it.width, it.height);
      gl.uniform1f(uOp, it.opacity);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }
  }

  /** True when every item's texture is resident. */
  allLoaded(items: DrawItem[]): boolean {
    return items.every((i) => this.textures.has(i.imageId));
  }

  dispose() {
    for (const t of this.textures.values()) this.gl.deleteTexture(t.tex);
    this.textures.clear();
  }
}
