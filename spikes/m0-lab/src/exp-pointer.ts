/**
 * Interactive Pencil / touch logger.
 *
 * Measures what the input layer can rely on: pointer types, event rates,
 * pressure and tilt availability, coalesced events, cancellations, palm
 * contacts during pen strokes, page-zoom leakage, long-press side effects,
 * and Scribble interference with a nearby text field.
 */
import type { Ctx, Experiment } from './experiment';
import { round } from './experiment';
import { summarize } from './stats';

interface TypeStats {
  downs: number;
  moves: number;
  ups: number;
  cancels: number;
  coalescedTotal: number;
  coalescedMax: number;
  predictedTotal: number;
  intervals: number[];
  pressure: Set<number>;
  pressureMin: number;
  pressureMax: number;
  tiltXMin: number;
  tiltXMax: number;
  tiltYMin: number;
  tiltYMax: number;
  altitude: boolean;
  azimuth: boolean;
  twistNonZero: boolean;
  widthMax: number;
  heightMax: number;
}

const newStats = (): TypeStats => ({
  downs: 0,
  moves: 0,
  ups: 0,
  cancels: 0,
  coalescedTotal: 0,
  coalescedMax: 0,
  predictedTotal: 0,
  intervals: [],
  pressure: new Set(),
  pressureMin: Infinity,
  pressureMax: -Infinity,
  tiltXMin: Infinity,
  tiltXMax: -Infinity,
  tiltYMin: Infinity,
  tiltYMax: -Infinity,
  altitude: false,
  azimuth: false,
  twistNonZero: false,
  widthMax: 0,
  heightMax: 0,
});

const STEPS = [
  'Pencil: draw several slow and fast strokes; press lightly then firmly; tilt the Pencil.',
  'Finger: draw a few strokes with one finger.',
  'Two fingers: pinch and pan inside the box (the page itself must NOT zoom).',
  'Palm: rest your palm on the box while drawing with the Pencil.',
  'Long-press: hold one finger still in the box for 2 seconds.',
  'Scribble: with the Pencil, tap the text field below the box, write a word, then draw in the box again.',
];

export const pointerLab: Experiment = {
  id: 'pointer-lab',
  title: 'Apple Pencil & touch input',
  summary: 'Interactive: guided drawing steps measure event rate, pressure/tilt, coalesced events, palm contacts, zoom leakage and Scribble.',
  interactive: true,
  run(ctx: Ctx) {
    return new Promise((resolve) => {
      const stats: Record<string, TypeStats> = {};
      const lastTs = new Map<number, number>();
      const activePointers = new Map<number, string>();
      let maxSimultaneous = 0;
      let touchDuringPen = 0;
      let contextMenus = 0;
      let selectionChanges = 0;
      let longPressDetected = 0;
      let scaleMin = visualViewport?.scale ?? 1,
        scaleMax = scaleMin;
      let scrollMoved = 0;
      let inputFocusDuringCanvas = 0;
      let inputValueChangesFromCanvas = 0;
      let gestureEvents = 0;
      let touchStarts = 0;
      const startScroll = { x: scrollX, y: scrollY };

      ctx.panel.innerHTML = '';
      const steps = document.createElement('ol');
      steps.className = 'steps';
      for (const s of STEPS) {
        const li = document.createElement('li');
        li.textContent = s;
        steps.append(li);
      }
      const box = document.createElement('canvas');
      box.className = 'pointer-box';
      const input = document.createElement('input');
      input.type = 'text';
      input.placeholder = 'Scribble test field — write here with the Pencil';
      input.className = 'scribble';
      const live = document.createElement('div');
      live.className = 'live';
      const done = document.createElement('button');
      done.className = 'primary';
      done.textContent = 'Finish & save input results';
      ctx.panel.append(steps, box, input, live, done);

      const dpr = devicePixelRatio || 1;
      const fit = () => {
        box.width = Math.round(box.clientWidth * dpr);
        box.height = Math.round(box.clientHeight * dpr);
      };
      fit();
      const g = box.getContext('2d')!;
      const colors: Record<string, string> = { pen: '#7cc4ff', touch: '#ffb36b', mouse: '#a0ffa0' };
      const lastPt = new Map<number, [number, number]>();

      let canvasActiveAt = 0;
      const onFocus = () => {
        if (performance.now() - canvasActiveAt < 300) inputFocusDuringCanvas++;
      };
      let valueAtCanvasStart = '';
      input.addEventListener('focus', onFocus);

      const st = (t: string) => (stats[t] ??= newStats());

      const record = (e: PointerEvent, s: TypeStats) => {
        const p = round(e.pressure, 3);
        if (s.pressure.size < 2000) s.pressure.add(p);
        s.pressureMin = Math.min(s.pressureMin, e.pressure);
        s.pressureMax = Math.max(s.pressureMax, e.pressure);
        s.tiltXMin = Math.min(s.tiltXMin, e.tiltX);
        s.tiltXMax = Math.max(s.tiltXMax, e.tiltX);
        s.tiltYMin = Math.min(s.tiltYMin, e.tiltY);
        s.tiltYMax = Math.max(s.tiltYMax, e.tiltY);
        const ee = e as PointerEvent & { altitudeAngle?: number; azimuthAngle?: number };
        if (typeof ee.altitudeAngle === 'number') s.altitude = true;
        if (typeof ee.azimuthAngle === 'number') s.azimuth = true;
        if (e.twist) s.twistNonZero = true;
        s.widthMax = Math.max(s.widthMax, e.width);
        s.heightMax = Math.max(s.heightMax, e.height);
      };

      const drawTo = (e: PointerEvent) => {
        const r = box.getBoundingClientRect();
        const x = (e.clientX - r.left) * dpr,
          y = (e.clientY - r.top) * dpr;
        const prev = lastPt.get(e.pointerId);
        g.strokeStyle = colors[e.pointerType] ?? '#fff';
        g.lineWidth = (e.pointerType === 'pen' ? 1 + e.pressure * 6 : 3) * dpr;
        g.lineCap = 'round';
        if (prev) {
          g.beginPath();
          g.moveTo(prev[0], prev[1]);
          g.lineTo(x, y);
          g.stroke();
        }
        lastPt.set(e.pointerId, [x, y]);
      };

      let lpTimer = 0;
      let lpStart: [number, number] | null = null;

      box.addEventListener('pointerdown', (e) => {
        canvasActiveAt = performance.now();
        valueAtCanvasStart = input.value;
        if (document.activeElement === input && e.pointerType === 'pen') input.blur();
        box.setPointerCapture(e.pointerId);
        const s = st(e.pointerType);
        s.downs++;
        record(e, s);
        activePointers.set(e.pointerId, e.pointerType);
        maxSimultaneous = Math.max(maxSimultaneous, activePointers.size);
        if (e.pointerType === 'touch' && [...activePointers.values()].includes('pen')) touchDuringPen++;
        lastTs.set(e.pointerId, e.timeStamp);
        lastPt.delete(e.pointerId);
        drawTo(e);
        if (e.pointerType === 'touch') {
          lpStart = [e.clientX, e.clientY];
          clearTimeout(lpTimer);
          lpTimer = window.setTimeout(() => {
            if (lpStart) longPressDetected++;
          }, 500);
        }
      });
      box.addEventListener('pointermove', (e) => {
        if (!activePointers.has(e.pointerId)) return;
        canvasActiveAt = performance.now();
        const s = st(e.pointerType);
        s.moves++;
        record(e, s);
        const prev = lastTs.get(e.pointerId);
        if (prev !== undefined && s.intervals.length < 20000) s.intervals.push(e.timeStamp - prev);
        lastTs.set(e.pointerId, e.timeStamp);
        if (e.getCoalescedEvents) {
          const c = e.getCoalescedEvents();
          s.coalescedTotal += c.length;
          s.coalescedMax = Math.max(s.coalescedMax, c.length);
          for (const ce of c) drawTo(ce);
        } else drawTo(e);
        if (e.getPredictedEvents) s.predictedTotal += e.getPredictedEvents().length;
        if (lpStart && Math.hypot(e.clientX - lpStart[0], e.clientY - lpStart[1]) > 8) {
          lpStart = null;
          clearTimeout(lpTimer);
        }
        if (input.value !== valueAtCanvasStart) inputValueChangesFromCanvas++;
      });
      const end = (e: PointerEvent, cancel: boolean) => {
        if (!activePointers.has(e.pointerId)) return;
        const s = st(e.pointerType);
        if (cancel) s.cancels++;
        else s.ups++;
        activePointers.delete(e.pointerId);
        lastPt.delete(e.pointerId);
        lpStart = null;
        clearTimeout(lpTimer);
      };
      box.addEventListener('pointerup', (e) => end(e, false));
      box.addEventListener('pointercancel', (e) => end(e, true));
      box.addEventListener('contextmenu', (e) => {
        contextMenus++;
        e.preventDefault();
      });
      box.addEventListener('touchstart', () => touchStarts++, { passive: true });
      const onSel = () => selectionChanges++;
      document.addEventListener('selectionchange', onSel);
      const onGesture = (e: Event) => {
        gestureEvents++;
        e.preventDefault();
      };
      box.addEventListener('gesturestart', onGesture);
      box.addEventListener('gesturechange', onGesture);
      const onVV = () => {
        const sc = visualViewport?.scale ?? 1;
        scaleMin = Math.min(scaleMin, sc);
        scaleMax = Math.max(scaleMax, sc);
      };
      visualViewport?.addEventListener('resize', onVV);
      const onScroll = () => {
        if (scrollX !== startScroll.x || scrollY !== startScroll.y) scrollMoved++;
      };
      window.addEventListener('scroll', onScroll);

      const tick = window.setInterval(() => {
        const parts = Object.entries(stats).map(([t, s]) => {
          const med = s.intervals.length ? summarize(s.intervals).p50 : NaN;
          return `${t}: ${s.moves} moves, ~${med ? Math.round(1000 / med) : '–'} Hz, pressure ${s.pressure.size} levels`;
        });
        live.textContent = parts.join(' · ') || 'Waiting for input…';
      }, 300);

      done.onclick = () => {
        clearInterval(tick);
        document.removeEventListener('selectionchange', onSel);
        visualViewport?.removeEventListener('resize', onVV);
        window.removeEventListener('scroll', onScroll);
        const byType: Record<string, unknown> = {};
        for (const [t, s] of Object.entries(stats)) {
          const iv = summarize(s.intervals);
          byType[t] = {
            downs: s.downs,
            moves: s.moves,
            ups: s.ups,
            cancels: s.cancels,
            moveIntervalMs: iv,
            eventRateHzMedian: iv.p50 ? round(1000 / iv.p50, 1) : null,
            coalescedPerMoveAvg: s.moves ? round(s.coalescedTotal / s.moves, 2) : null,
            coalescedMax: s.coalescedMax,
            predictedTotal: s.predictedTotal,
            pressureDistinctLevels: s.pressure.size,
            pressureRange: [round(s.pressureMin, 3), round(s.pressureMax, 3)],
            pressureLooksReal: s.pressure.size > 5 && s.pressureMax - s.pressureMin > 0.2,
            tiltXRange: [s.tiltXMin, s.tiltXMax],
            tiltYRange: [s.tiltYMin, s.tiltYMax],
            tiltLooksReal: s.tiltXMax - s.tiltXMin > 5 || s.tiltYMax - s.tiltYMin > 5,
            altitudeAngleProvided: s.altitude,
            azimuthAngleProvided: s.azimuth,
            twistNonZero: s.twistNonZero,
            contactSizeMax: [round(s.widthMax, 1), round(s.heightMax, 1)],
          };
        }
        resolve({
          byType,
          maxSimultaneousPointers: maxSimultaneous,
          touchContactsWhilePenDown: touchDuringPen,
          longPressDetectedByRecognizer: longPressDetected,
          contextmenuEvents: contextMenus,
          selectionChangeEvents: selectionChanges,
          gestureEventsPrevented: gestureEvents,
          touchStartEvents: touchStarts,
          pageZoomLeak: { visualViewportScaleMin: round(scaleMin, 3), visualViewportScaleMax: round(scaleMax, 3), leaked: scaleMax - scaleMin > 0.01 },
          pageScrollEvents: scrollMoved,
          scribble: {
            inputFocusedWithin300msOfCanvasInput: inputFocusDuringCanvas,
            inputValueChangedDuringCanvasStroke: inputValueChangesFromCanvas,
            finalInputLength: input.value.length,
          },
        });
      };
    });
  },
};
