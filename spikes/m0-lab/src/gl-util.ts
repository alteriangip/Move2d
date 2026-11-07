/** Small WebGL2 helpers for the lab. */

export function compile(gl: WebGL2RenderingContext, vs: string, fs: string, tfVaryings?: string[]): WebGLProgram {
  const mk = (type: number, src: string) => {
    const s = gl.createShader(type)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(`shader: ${gl.getShaderInfoLog(s)}`);
    return s;
  };
  const p = gl.createProgram()!;
  gl.attachShader(p, mk(gl.VERTEX_SHADER, vs));
  gl.attachShader(p, mk(gl.FRAGMENT_SHADER, fs));
  if (tfVaryings) gl.transformFeedbackVaryings(p, tfVaryings, gl.INTERLEAVED_ATTRIBS);
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`link: ${gl.getProgramInfoLog(p)}`);
  return p;
}

/** Forces the GPU to finish pending work by reading back one pixel. */
export function sync(gl: WebGL2RenderingContext): void {
  const px = new Uint8Array(4);
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
}

/** Paints a procedural 8×8-cell "artwork atlas" (soft blobs with alpha). */
export function paintAtlas(size: number): HTMLCanvasElement {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d')!;
  const cell = size / 8;
  for (let j = 0; j < 8; j++)
    for (let i = 0; i < 8; i++) {
      const hue = ((j * 8 + i) * 47) % 360;
      const cx = i * cell + cell / 2,
        cy = j * cell + cell / 2;
      const grad = g.createRadialGradient(cx, cy - cell * 0.1, cell * 0.05, cx, cy, cell * 0.45);
      grad.addColorStop(0, `hsla(${hue},80%,70%,1)`);
      grad.addColorStop(0.85, `hsla(${hue},70%,45%,1)`);
      grad.addColorStop(1, `hsla(${hue},70%,30%,0)`);
      g.fillStyle = grad;
      g.beginPath();
      g.ellipse(cx, cy, cell * 0.45, cell * 0.45, 0, 0, Math.PI * 2);
      g.fill();
      g.strokeStyle = 'rgba(20,10,30,0.9)';
      g.lineWidth = Math.max(2, cell * 0.02);
      g.stroke();
    }
  return c;
}

export const GL_ERRORS: Record<number, string> = {
  0x0500: 'INVALID_ENUM',
  0x0501: 'INVALID_VALUE',
  0x0502: 'INVALID_OPERATION',
  0x0505: 'OUT_OF_MEMORY',
  0x0506: 'INVALID_FRAMEBUFFER_OPERATION',
  0x9242: 'CONTEXT_LOST_WEBGL',
};
