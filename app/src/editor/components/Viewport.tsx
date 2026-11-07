/**
 * Main canvas. Input policy (doc 01 §1.7.3, validated in M0):
 *  - Apple Pencil (and mouse): uses the active tool — Select taps pick a layer,
 *    dragging moves the selection; Hand pans.
 *  - One finger: tap selects, drag pans.  Two fingers: pan + pinch-zoom + rotate.
 *  - Palms (large contacts, or touches starting while the Pencil is down) are ignored.
 *  - Navigation is applied once per frame from the latest contact positions.
 */
import { useEffect, useRef } from 'react';
import { useEditor, ops } from '../store';
import { Renderer, type DrawItem } from '../../engine/render/renderer';
import { apply as applyM, invert, mul, scaleOf, twoPointSimilarity, zoomAt, type Affine } from '../../engine/math/affine';
import { boundsOf, ensureMask, isLocked, layersUnder, pickLayer } from '../hit-test';
import type { Doc, Id } from '../../engine/model/types';

const PALM_WIDTH = 40;
const TAP_SLOP = 10; // css px
const TAP_MS = 350;

interface Ptr {
  id: number;
  type: string;
  x: number; // device px
  y: number;
  sx: number;
  sy: number;
  t0: number;
  palm: boolean;
}

export function Viewport() {
  const wrap = useRef<HTMLDivElement>(null);
  const glRef = useRef<HTMLCanvasElement>(null);
  const ovRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const glc = glRef.current!,
      ov = ovRef.current!,
      host = wrap.current!;
    const store = useEditor;
    let renderer: Renderer;
    try {
      renderer = new Renderer(glc, (id) => {
        const a = store.getState().assets.get(id);
        return a && { bytes: a.bytes, mime: a.mime };
      });
    } catch (e) {
      store.getState().toast((e as Error).message, 'error');
      return;
    }
    const g2 = ov.getContext('2d')!;
    let cam: Affine = [1, 0, 0, 1, 0, 0];
    let dirty = true;
    const markDirty = () => (dirty = true);
    renderer.onTextureReady = markDirty;
    renderer.onContextChange = (lost) => {
      if (lost) store.getState().toast('Graphics were reset by iPadOS; reloading textures…');
      markDirty();
    };
    (window as unknown as { __ol?: object }).__ol = { renderer };

    const dpr = () => window.devicePixelRatio || 1;
    const fit = () => {
      const doc = store.getState().doc;
      const { width, height } = renderer.resize();
      if (!doc) return;
      const s = Math.min(width / doc.width, height / doc.height) * 0.9;
      cam = [s, 0, 0, s, (width - doc.width * s) / 2, (height - doc.height * s) / 2];
      dirty = true;
    };

    const ro = new ResizeObserver(() => {
      const before = { w: glc.width, h: glc.height };
      renderer.resize();
      ov.width = glc.width;
      ov.height = glc.height;
      // keep the view centred on resize/rotation
      cam = [cam[0], cam[1], cam[2], cam[3], cam[4] + (glc.width - before.w) / 2, cam[5] + (glc.height - before.h) / 2];
      dirty = true;
    });
    ro.observe(host);
    renderer.resize();
    ov.width = glc.width;
    ov.height = glc.height;
    fit();

    let lastFit = store.getState().fitRequest;
    const unsub = store.subscribe((s, prev) => {
      if (s.fitRequest !== lastFit) {
        lastFit = s.fitRequest;
        fit();
      }
      if (s.doc !== prev.doc || s.selection !== prev.selection || s.showGrid !== prev.showGrid || s.assets !== prev.assets) dirty = true;
      if (s.assets !== prev.assets) for (const a of s.assets.values()) ensureMask(a, () => {});
      if (s.doc && prev.doc && s.doc.id !== prev.doc.id) renderer.retain(new Set());
    });
    for (const a of store.getState().assets.values()) ensureMask(a, () => {});

    /* ---------------- input ---------------- */
    const ptrs = new Map<number, Ptr>();
    let penId: number | null = null;
    let nav: { cam: Affine; ids: [number, number]; p1: [number, number]; p2: [number, number] } | null = null;
    let pan: { cam: Affine; id: number; x: number; y: number } | null = null;
    let drag: { id: number; startDoc: [number, number]; orig: Map<Id, [number, number]> } | null = null;
    let tapCandidate: number | null = null;

    const local = (e: PointerEvent): [number, number] => {
      const r = glc.getBoundingClientRect();
      return [(e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr()];
    };
    const toDoc = (x: number, y: number) => applyM(invert(cam), x, y);
    const fingers = () => [...ptrs.values()].filter((p) => p.type === 'touch' && !p.palm);

    const resetNav = () => {
      const f = fingers();
      nav = null;
      pan = null;
      if (f.length >= 2) {
        nav = { cam, ids: [f[0].id, f[1].id], p1: [f[0].x, f[0].y], p2: [f[1].x, f[1].y] };
        tapCandidate = null;
      } else if (f.length === 1 && penId === null && !drag) {
        pan = { cam, id: f[0].id, x: f[0].x, y: f[0].y };
      }
    };

    const selectAt = (x: number, y: number) => {
      const s = store.getState();
      if (!s.doc) return null;
      const [dx, dy] = toDoc(x, y);
      const hit = pickLayer(s.doc, dx, dy);
      s.select(hit ? [hit.id] : []);
      return hit;
    };

    const startDrag = (pid: number, x: number, y: number) => {
      const s = store.getState();
      const doc = s.doc;
      if (!doc) return;
      let sel = s.selection;
      const [dx, dy] = toDoc(x, y);
      const hit = pickLayer(doc, dx, dy);
      const insideSel = hit && layersUnder(doc, sel).some((l) => l.id === hit.id);
      if (!insideSel) {
        sel = hit ? [hit.id] : [];
        s.select(sel);
      }
      const layers = layersUnder(doc, sel).filter((l) => !isLocked(doc, l.id));
      if (!layers.length) return;
      s.begin();
      drag = { id: pid, startDoc: [dx, dy], orig: new Map(layers.map((l) => [l.id, [l.x, l.y]])) };
    };

    const onDown = (e: PointerEvent) => {
      glc.setPointerCapture(e.pointerId);
      const [x, y] = local(e);
      const p: Ptr = { id: e.pointerId, type: e.pointerType, x, y, sx: x, sy: y, t0: e.timeStamp, palm: false };
      if (e.pointerType === 'touch' && (e.width >= PALM_WIDTH || penId !== null)) p.palm = true;
      ptrs.set(e.pointerId, p);
      const tool = store.getState().tool;
      if (e.pointerType === 'pen' || (e.pointerType === 'mouse' && e.button === 0)) {
        penId = e.pointerId;
        nav = pan = null;
        if (tool === 'select') startDrag(e.pointerId, x, y);
        else pan = { cam, id: e.pointerId, x, y };
      } else if (e.pointerType === 'mouse') {
        pan = { cam, id: e.pointerId, x, y }; // middle/right drag pans
      } else if (!p.palm) {
        tapCandidate = fingers().length === 1 ? e.pointerId : null;
        resetNav();
      }
    };

    const onMove = (e: PointerEvent) => {
      const p = ptrs.get(e.pointerId);
      if (!p) return;
      const ev = e.getCoalescedEvents?.() ?? [];
      const last = ev.length ? ev[ev.length - 1] : e;
      [p.x, p.y] = local(last);
      if (p.type === 'touch' && !p.palm && last.width >= PALM_WIDTH) {
        p.palm = true;
        resetNav();
      }
      if (tapCandidate === e.pointerId && Math.hypot(p.x - p.sx, p.y - p.sy) > TAP_SLOP * dpr()) tapCandidate = null;
      if (drag && drag.id === e.pointerId) {
        const [dx, dy] = toDoc(p.x, p.y);
        const ox = Math.round(dx - drag.startDoc[0]),
          oy = Math.round(dy - drag.startDoc[1]);
        const orig = drag.orig;
        store.getState().preview((d: Doc) => {
          const nodes = { ...d.nodes };
          for (const [id, [x0, y0]] of orig) nodes[id] = { ...nodes[id], x: x0 + ox, y: y0 + oy } as never;
          return { ...d, nodes };
        });
      }
      dirty = true;
    };

    const onUp = (e: PointerEvent, cancelled: boolean) => {
      const p = ptrs.get(e.pointerId);
      if (!p) return;
      ptrs.delete(e.pointerId);
      if (drag && drag.id === e.pointerId) {
        if (cancelled) store.getState().cancel();
        else store.getState().commit(drag.orig.size > 1 ? `Move ${drag.orig.size} layers` : 'Move layer');
        drag = null;
      }
      if (e.pointerId === penId) penId = null;
      if (!cancelled && tapCandidate === e.pointerId && e.timeStamp - p.t0 < TAP_MS) selectAt(p.x, p.y);
      if (tapCandidate === e.pointerId) tapCandidate = null;
      resetNav();
      dirty = true;
    };

    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = glc.getBoundingClientRect();
      const x = (e.clientX - r.left) * dpr(),
        y = (e.clientY - r.top) * dpr();
      if (e.ctrlKey || !e.shiftKey) cam = zoomAt(cam, Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015)), x, y);
      else cam = [cam[0], cam[1], cam[2], cam[3], cam[4] - e.deltaX * dpr(), cam[5] - e.deltaY * dpr()];
      dirty = true;
    };
    const stopGesture = (e: Event) => e.preventDefault();

    glc.addEventListener('pointerdown', onDown);
    glc.addEventListener('pointermove', onMove);
    glc.addEventListener('pointerup', (e) => onUp(e, false));
    glc.addEventListener('pointercancel', (e) => onUp(e, true));
    glc.addEventListener('wheel', onWheel, { passive: false });
    glc.addEventListener('contextmenu', stopGesture);
    for (const t of ['gesturestart', 'gesturechange', 'gestureend']) glc.addEventListener(t, stopGesture);
    glc.addEventListener('touchstart', stopGesture, { passive: false });

    const applyNav = () => {
      if (nav) {
        const a = ptrs.get(nav.ids[0]),
          b = ptrs.get(nav.ids[1]);
        if (a && b) cam = mul(twoPointSimilarity(nav.p1, nav.p2, [a.x, a.y], [b.x, b.y]), nav.cam);
      } else if (pan) {
        const p = ptrs.get(pan.id);
        if (p) cam = [pan.cam[0], pan.cam[1], pan.cam[2], pan.cam[3], pan.cam[4] + p.x - pan.x, pan.cam[5] + p.y - pan.y];
      }
    };

    /* ---------------- drawing ---------------- */
    const drawOverlay = (doc: Doc, sel: Id[]) => {
      g2.setTransform(1, 0, 0, 1, 0, 0);
      g2.clearRect(0, 0, ov.width, ov.height);
      const d = dpr();
      const quad = (x: number, y: number, w: number, h: number) => {
        const pts = [applyM(cam, x, y), applyM(cam, x + w, y), applyM(cam, x + w, y + h), applyM(cam, x, y + h)];
        g2.beginPath();
        g2.moveTo(pts[0][0], pts[0][1]);
        for (const p of pts.slice(1)) g2.lineTo(p[0], p[1]);
        g2.closePath();
      };
      g2.lineWidth = 1 * d;
      g2.strokeStyle = 'rgba(255,255,255,0.35)';
      quad(0, 0, doc.width, doc.height);
      g2.stroke();
      if (!sel.length) return;
      g2.strokeStyle = '#58b6ff';
      g2.setLineDash([]);
      g2.lineWidth = 1.5 * d;
      for (const l of layersUnder(doc, sel)) {
        quad(l.x, l.y, l.width, l.height);
        g2.stroke();
      }
      const b = boundsOf(doc, sel);
      if (b && sel.length > 1) {
        g2.setLineDash([6 * d, 4 * d]);
        quad(b.x, b.y, b.w, b.h);
        g2.stroke();
        g2.setLineDash([]);
      }
    };

    let raf = 0;
    const frame = () => {
      raf = requestAnimationFrame(frame);
      if (nav || pan) {
        applyNav();
        dirty = true;
      }
      if (!dirty) return;
      dirty = false;
      const s = store.getState();
      if (!s.doc) {
        g2.setTransform(1, 0, 0, 1, 0, 0);
        g2.clearRect(0, 0, ov.width, ov.height);
        renderer.render({ camera: cam, docWidth: 0, docHeight: 0, items: [], showGrid: false });
        return;
      }
      const items: DrawItem[] = ops.drawList(s.doc).map(({ layer, opacity }) => ({
        imageId: layer.imageId,
        x: layer.x,
        y: layer.y,
        width: layer.width,
        height: layer.height,
        opacity,
        blendMode: layer.blendMode,
      }));
      renderer.render({ camera: cam, docWidth: s.doc.width, docHeight: s.doc.height, items, showGrid: s.showGrid });
      drawOverlay(s.doc, s.selection);
      if (!renderer.allLoaded(items)) dirty = true; // keep drawing until textures arrive
      const st = statsRef();
      st.zoom = scaleOf(cam) / dpr();
      st.textureMB = renderer.textureBytes / 1048576;
      st.textures = renderer.textureCount;
    };
    raf = requestAnimationFrame(frame);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      unsub();
      renderer.dispose();
    };
  }, []);

  return (
    <div className="viewport" ref={wrap}>
      <canvas ref={glRef} className="gl" />
      <canvas ref={ovRef} className="overlay" />
    </div>
  );
}

/** Live viewport statistics for the status bar (read by polling, not React state). */
const stats = { zoom: 1, textureMB: 0, textures: 0 };
export const statsRef = () => stats;
