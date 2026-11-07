/**
 * Canvas navigation test: a working prototype of the editor's viewport input
 * policy, so it can be judged by hand on the device and measured.
 *
 *  - two fingers: pan + pinch-zoom + rotate (similarity transform from the two contacts)
 *  - one finger: pan (unless a Pencil stroke is active)
 *  - Pencil: draws strokes in artwork space (they stay attached when the view moves)
 *  - palm rejection: touches with a large contact size, or that start while the
 *    Pencil is down, are ignored and counted
 *
 * Records frame times during gestures, event→frame delay, every pointercancel
 * with its context, palm classifications, and the tester's rating.
 */
import type { Ctx, Experiment } from './experiment';
import { round } from './experiment';
import { summarize } from './stats';
import { compile, paintAtlas } from './gl-util';

/** Screen = M · world, M = [a, b, c, d, e, f] → x' = a x + c y + e, y' = b x + d y + f. */
type Affine = [number, number, number, number, number, number];

const mul = (m: Affine, n: Affine): Affine => [
  m[0] * n[0] + m[2] * n[1],
  m[1] * n[0] + m[3] * n[1],
  m[0] * n[2] + m[2] * n[3],
  m[1] * n[2] + m[3] * n[3],
  m[0] * n[4] + m[2] * n[5] + m[4],
  m[1] * n[4] + m[3] * n[5] + m[5],
];
const scaleOf = (m: Affine) => Math.hypot(m[0], m[1]);

/** Similarity transform (in screen space) that maps segment p1→p2 onto q1→q2. */
export function twoPointSimilarity(
  p1: [number, number],
  p2: [number, number],
  q1: [number, number],
  q2: [number, number],
): Affine {
  const pdx = p2[0] - p1[0],
    pdy = p2[1] - p1[1];
  const qdx = q2[0] - q1[0],
    qdy = q2[1] - q1[1];
  const pl = Math.hypot(pdx, pdy) || 1e-6;
  const s = Math.hypot(qdx, qdy) / pl;
  const r = Math.atan2(qdy, qdx) - Math.atan2(pdy, pdx);
  const c = Math.cos(r) * s,
    si = Math.sin(r) * s;
  // q = R·s·(p - p1) + q1
  return [c, si, -si, c, q1[0] - (c * p1[0] - si * p1[1]), q1[1] - (si * p1[0] + c * p1[1])];
}

const VS = `#version 300 es
in vec2 a_pos; uniform mat3 u_m; uniform vec2 u_view; out vec2 v_uv;
void main(){ v_uv = a_pos; vec3 s = u_m * vec3(a_pos * 2048.0, 1.0);
  vec2 clip = s.xy / u_view * 2.0 - 1.0; gl_Position = vec4(clip.x, -clip.y, 0, 1); }`;
const FS = `#version 300 es
precision mediump float; in vec2 v_uv; uniform sampler2D u_tex; out vec4 o;
void main(){ vec4 c = texture(u_tex, v_uv);
  vec2 g = abs(fract(v_uv * 16.0 - 0.5) - 0.5) / fwidth(v_uv * 16.0);
  float line = 1.0 - min(min(g.x, g.y), 1.0);
  vec3 bg = mix(vec3(0.16,0.17,0.2), vec3(0.3,0.32,0.38), line);
  o = vec4(mix(bg, c.rgb / max(c.a, 1e-4), c.a), 1.0); }`;

const PALM_WIDTH_PX = 40;

export const navLab: Experiment = {
  id: 'canvas-navigation',
  title: 'Canvas navigation (pan, pinch, rotate, palm rejection)',
  summary:
    'Interactive prototype of the editor viewport: two fingers pan/zoom/rotate, Pencil draws, palms are ignored. Measures smoothness, cancels and palm handling.',
  interactive: true,
  run(ctx: Ctx) {
    return new Promise((resolve, reject) => {
      ctx.panel.innerHTML = '';
      const steps = document.createElement('ol');
      steps.className = 'steps';
      for (const s of [
        'Two fingers: pinch to zoom in and out, drag to pan, twist to rotate. The artwork should follow your fingers exactly.',
        'One finger: drag to pan.',
        'Pencil: draw on the artwork, then zoom and pan; your strokes must stay attached to the artwork.',
        'Palm: rest your hand on the screen while drawing with the Pencil. The view must not move.',
        'Pencil and hand together: draw with the Pencil while panning with two fingers of the other hand.',
        'Rate how it felt, then tap Finish.',
      ]) {
        const li = document.createElement('li');
        li.textContent = s;
        steps.append(li);
      }
      const stage = document.createElement('div');
      stage.className = 'nav-stage';
      const glc = document.createElement('canvas');
      const ov = document.createElement('canvas');
      stage.append(glc, ov);
      const live = document.createElement('div');
      live.className = 'live';
      const rating = document.createElement('div');
      rating.className = 'choice';
      let rated: string | null = null;
      for (const r of ['Smooth', 'Acceptable', 'Laggy or wrong']) {
        const b = document.createElement('button');
        b.textContent = r;
        b.onclick = () => {
          rated = r;
          [...rating.querySelectorAll('button')].forEach((x) => x.classList.toggle('primary', x === b));
        };
        rating.append(b);
      }
      const resetBtn = document.createElement('button');
      resetBtn.textContent = 'Reset view';
      const done = document.createElement('button');
      done.className = 'primary';
      done.textContent = 'Finish & save navigation results';
      ctx.panel.append(steps, stage, live, rating, resetBtn, done);

      const gl = glc.getContext('webgl2', { antialias: true, alpha: false });
      if (!gl) {
        reject(new Error('WebGL2 unavailable'));
        return;
      }
      const prog = compile(gl, VS, FS);
      const vao = gl.createVertexArray()!;
      gl.bindVertexArray(vao);
      const vb = gl.createBuffer()!;
      gl.bindBuffer(gl.ARRAY_BUFFER, vb);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
      const aPos = gl.getAttribLocation(prog, 'a_pos');
      gl.enableVertexAttribArray(aPos);
      gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);
      const atlas = paintAtlas(2048);
      const tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, atlas);
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
      atlas.width = atlas.height = 0;
      const uM = gl.getUniformLocation(prog, 'u_m');
      const uView = gl.getUniformLocation(prog, 'u_view');
      const g2 = ov.getContext('2d')!;

      const dpr = devicePixelRatio || 1;
      let W = 0,
        H = 0;
      const fitView = (): Affine => {
        const s = (Math.min(W, H) / 2048) * 0.9;
        return [s, 0, 0, s, (W - 2048 * s) / 2, (H - 2048 * s) / 2];
      };
      const resize = () => {
        W = stage.clientWidth * dpr;
        H = stage.clientHeight * dpr;
        glc.width = ov.width = W;
        glc.height = ov.height = H;
      };
      resize();
      let cam: Affine = fitView();
      resetBtn.onclick = () => {
        cam = fitView();
        dirty = true;
      };

      // ---- input state ----
      type P = { id: number; type: string; x: number; y: number; downAt: number; width: number; palm: boolean };
      const pointers = new Map<number, P>();
      let penId: number | null = null;
      let gestureStart: { cam: Affine; p1: [number, number]; p2: [number, number]; ids: [number, number] } | null = null;
      let panStart: { cam: Affine; x: number; y: number; id: number } | null = null;
      const strokes: number[][] = []; // world-space polylines (x,y pairs)
      let current: number[] | null = null;
      let dirty = true;
      let pendingEventTs: number | null = null;

      // ---- metrics ----
      const gestureFrames: number[] = [];
      const eventToFrame: number[] = [];
      const cancels: Record<string, unknown>[] = [];
      let palmsIgnored = 0,
        touchesDuringPen = 0,
        maxWidth = 0,
        pinchSessions = 0,
        panSessions = 0,
        penStrokes = 0,
        penWhileTwoFinger = 0,
        maxSimultaneous = 0,
        gestureEventsPrevented = 0;
      let zoomMin = 1,
        zoomMax = 1;
      let rotMax = 0;
      const baseScale = scaleOf(cam);
      let scaleMin = visualViewport?.scale ?? 1,
        scaleMax = scaleMin;

      const toLocal = (e: PointerEvent): [number, number] => {
        const r = stage.getBoundingClientRect();
        return [(e.clientX - r.left) * dpr, (e.clientY - r.top) * dpr];
      };
      const toWorld = (x: number, y: number): [number, number] => {
        const [a, b, c, d, e, f] = cam;
        const det = a * d - b * c;
        const X = x - e,
          Y = y - f;
        return [(d * X - c * Y) / det, (-b * X + a * Y) / det];
      };
      const fingers = () => [...pointers.values()].filter((p) => p.type === 'touch' && !p.palm);
      const startTwoFinger = () => {
        const f = fingers();
        if (f.length >= 2) {
          gestureStart = { cam, p1: [f[0].x, f[0].y], p2: [f[1].x, f[1].y], ids: [f[0].id, f[1].id] };
          panStart = null;
          pinchSessions++;
          if (penId !== null) penWhileTwoFinger++;
        } else if (f.length === 1 && penId === null) {
          panStart = { cam, x: f[0].x, y: f[0].y, id: f[0].id };
          gestureStart = null;
          panSessions++;
        } else {
          gestureStart = null;
          panStart = null;
        }
      };

      stage.addEventListener('pointerdown', (e) => {
        stage.setPointerCapture(e.pointerId);
        const [x, y] = toLocal(e);
        maxWidth = Math.max(maxWidth, e.width);
        const p: P = { id: e.pointerId, type: e.pointerType, x, y, downAt: e.timeStamp, width: e.width, palm: false };
        if (e.pointerType === 'touch') {
          if (penId !== null) touchesDuringPen++;
          if (e.width >= PALM_WIDTH_PX || penId !== null) {
            p.palm = true;
            palmsIgnored++;
          }
        }
        pointers.set(e.pointerId, p);
        maxSimultaneous = Math.max(maxSimultaneous, pointers.size);
        if (e.pointerType === 'pen' || e.pointerType === 'mouse') {
          penId = e.pointerId;
          gestureStart = null;
          panStart = null;
          current = [...toWorld(x, y)];
          strokes.push(current);
          penStrokes++;
        } else if (!p.palm) startTwoFinger();
        dirty = true;
      });
      stage.addEventListener('pointermove', (e) => {
        const p = pointers.get(e.pointerId);
        if (!p) return;
        const evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
        const last = evs[evs.length - 1] ?? e;
        [p.x, p.y] = toLocal(last);
        if (p.type === 'touch' && !p.palm && last.width >= PALM_WIDTH_PX) {
          // a contact that grows into a palm stops navigating
          p.palm = true;
          palmsIgnored++;
          startTwoFinger();
        }
        maxWidth = Math.max(maxWidth, e.width);
        if (e.pointerId === penId && current) {
          for (const ce of evs) current.push(...toWorld(...toLocal(ce)));
        }
        // Navigation is applied once per frame (applyNavigation) from the latest
        // contact positions, so the camera never sees one finger updated and the other not.
        pendingEventTs ??= e.timeStamp;
        dirty = true;
      });
      const up = (e: PointerEvent, cancelled: boolean) => {
        const p = pointers.get(e.pointerId);
        if (!p) return;
        if (cancelled && cancels.length < 60)
          cancels.push({
            type: p.type,
            activePointers: pointers.size,
            msSinceDown: round(e.timeStamp - p.downAt, 0),
            contactWidth: round(p.width, 1),
            classifiedPalm: p.palm,
            duringTwoFingerGesture: !!gestureStart,
            penDown: penId !== null,
          });
        pointers.delete(e.pointerId);
        if (e.pointerId === penId) {
          penId = null;
          current = null;
        }
        startTwoFinger();
        dirty = true;
      };
      stage.addEventListener('pointerup', (e) => up(e, false));
      stage.addEventListener('pointercancel', (e) => up(e, true));
      const prevent = (e: Event) => {
        gestureEventsPrevented++;
        e.preventDefault();
      };
      for (const t of ['gesturestart', 'gesturechange', 'gestureend']) stage.addEventListener(t, prevent);
      stage.addEventListener('touchstart', (e) => e.preventDefault(), { passive: false });
      stage.addEventListener('contextmenu', (e) => e.preventDefault());
      const onVV = () => {
        const sc = visualViewport?.scale ?? 1;
        scaleMin = Math.min(scaleMin, sc);
        scaleMax = Math.max(scaleMax, sc);
      };
      visualViewport?.addEventListener('resize', onVV);

      /** Applies the active two-finger or one-finger navigation to the camera. */
      const applyNavigation = () => {
        if (gestureStart) {
          const a = pointers.get(gestureStart.ids[0]),
            b = pointers.get(gestureStart.ids[1]);
          if (!a || !b) return;
          cam = mul(twoPointSimilarity(gestureStart.p1, gestureStart.p2, [a.x, a.y], [b.x, b.y]), gestureStart.cam);
        } else if (panStart) {
          const p = pointers.get(panStart.id);
          if (!p) return;
          const s = panStart.cam;
          cam = [s[0], s[1], s[2], s[3], s[4] + p.x - panStart.x, s[5] + p.y - panStart.y];
        } else return;
        const z = scaleOf(cam) / baseScale;
        zoomMin = Math.min(zoomMin, z);
        zoomMax = Math.max(zoomMax, z);
        rotMax = Math.max(rotMax, Math.abs(Math.atan2(cam[1], cam[0])));
      };

      // ---- render loop ----
      let running = true;
      let lastFrame = 0;
      const frame = (t: number) => {
        if (!running) return;
        if (lastFrame && (gestureStart || panStart || penId !== null)) gestureFrames.push(t - lastFrame);
        lastFrame = t;
        if (pendingEventTs !== null) {
          eventToFrame.push(t - pendingEventTs);
          pendingEventTs = null;
        }
        if (dirty) {
          dirty = false;
          applyNavigation();
          gl.viewport(0, 0, W, H);
          gl.clearColor(0.07, 0.08, 0.1, 1);
          gl.clear(gl.COLOR_BUFFER_BIT);
          gl.useProgram(prog);
          gl.bindVertexArray(vao);
          gl.uniformMatrix3fv(uM, false, [cam[0], cam[1], 0, cam[2], cam[3], 0, cam[4], cam[5], 1]);
          gl.uniform2f(uView, W, H);
          gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
          g2.setTransform(1, 0, 0, 1, 0, 0);
          g2.clearRect(0, 0, W, H);
          g2.setTransform(cam[0], cam[1], cam[2], cam[3], cam[4], cam[5]);
          g2.strokeStyle = '#58b6ff';
          g2.lineWidth = 4 / scaleOf(cam) * dpr;
          g2.lineCap = g2.lineJoin = 'round';
          for (const s of strokes) {
            if (s.length < 4) continue;
            g2.beginPath();
            g2.moveTo(s[0], s[1]);
            for (let i = 2; i < s.length; i += 2) g2.lineTo(s[i], s[i + 1]);
            g2.stroke();
          }
        }
        const gf = gestureFrames.length ? summarize(gestureFrames.slice(-300)) : null;
        live.textContent =
          `zoom ${round(scaleOf(cam) / baseScale, 2)}× · touches ${fingers().length} · palms ignored ${palmsIgnored} · cancels ${cancels.length}` +
          (gf ? ` · gesture frame p95 ${round(gf.p95, 1)} ms` : '');
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);

      done.onclick = () => {
        running = false;
        visualViewport?.removeEventListener('resize', onVV);
        gl.getExtension('WEBGL_lose_context')?.loseContext();
        const gf = summarize(gestureFrames);
        resolve({
          rating: rated,
          gestureFrameMs: gf,
          gestureFramesOver20ms: gestureFrames.filter((x) => x > 20).length,
          eventToNextFrameMs: summarize(eventToFrame),
          pinchSessions,
          panSessions,
          penStrokes,
          penStrokesWhileTwoFingerGestureStarted: penWhileTwoFinger,
          zoomRange: [round(zoomMin, 2), round(zoomMax, 2)],
          maxRotationDeg: round((rotMax * 180) / Math.PI, 1),
          maxSimultaneousPointers: maxSimultaneous,
          palmRejection: { widthThresholdPx: PALM_WIDTH_PX, palmsIgnored, touchesStartedWhilePenDown: touchesDuringPen, maxContactWidth: round(maxWidth, 1) },
          cancels: { count: cancels.length, samples: cancels },
          gestureEventsPrevented,
          pageZoomLeak: { min: round(scaleMin, 3), max: round(scaleMax, 3), leaked: scaleMax - scaleMin > 0.01 },
          viewport: { cssWidth: stage.clientWidth, cssHeight: stage.clientHeight },
        });
      };
    });
  },
};
