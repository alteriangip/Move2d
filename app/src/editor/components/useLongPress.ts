import { useRef } from 'react';

/**
 * Long-press (500 ms, < 8 px movement) for touch and Pencil; right-click on
 * desktop. Returns pointer handlers to spread on an element.
 */
export function useLongPress(onLongPress: (x: number, y: number) => void) {
  const t = useRef<number | null>(null);
  const start = useRef<[number, number] | null>(null);
  const fired = useRef(false);
  const clear = () => {
    if (t.current) clearTimeout(t.current);
    t.current = null;
    start.current = null;
  };
  return {
    onPointerDown(e: React.PointerEvent) {
      if (e.pointerType === 'mouse') return;
      fired.current = false;
      start.current = [e.clientX, e.clientY];
      const { clientX, clientY } = e;
      t.current = window.setTimeout(() => {
        fired.current = true;
        onLongPress(clientX, clientY);
      }, 500);
    },
    onPointerMove(e: React.PointerEvent) {
      if (start.current && Math.hypot(e.clientX - start.current[0], e.clientY - start.current[1]) > 8) clear();
    },
    onPointerUp: clear,
    onPointerCancel: clear,
    onContextMenu(e: React.MouseEvent) {
      e.preventDefault();
      onLongPress(e.clientX, e.clientY);
    },
    /** true if the last press turned into a long-press (suppress the click) */
    consumed: () => {
      const f = fired.current;
      fired.current = false;
      return f;
    },
  };
}
