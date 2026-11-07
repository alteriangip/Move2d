import { useEffect } from 'react';

export interface MenuItem {
  label: string;
  onSelect: () => void;
  danger?: boolean;
  disabled?: boolean;
}

/** Context menu with large touch targets, positioned at a point and kept on screen. */
export function Menu({ x, y, items, onClose }: { x: number; y: number; items: MenuItem[]; onClose: () => void }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  const left = Math.min(x, window.innerWidth - 240);
  const top = Math.min(y, window.innerHeight - items.length * 48 - 16);
  return (
    <div className="menu-backdrop" onPointerDown={onClose}>
      <div className="menu" style={{ left: Math.max(8, left), top: Math.max(8, top) }} onPointerDown={(e) => e.stopPropagation()} role="menu">
        {items.map((it) => (
          <button
            key={it.label}
            role="menuitem"
            className={it.danger ? 'danger' : ''}
            disabled={it.disabled}
            onClick={() => {
              onClose();
              it.onSelect();
            }}
          >
            {it.label}
          </button>
        ))}
      </div>
    </div>
  );
}
