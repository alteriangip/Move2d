/** Summary statistics for benchmark samples. */
export interface Summary {
  n: number;
  min: number;
  p50: number;
  p95: number;
  p99: number;
  max: number;
  mean: number;
}

/** Linear-interpolated percentile of a sorted array (q in [0,1]). */
export function percentile(sorted: ArrayLike<number>, q: number): number {
  if (sorted.length === 0) return NaN;
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

/** Summarizes samples; values are rounded to 3 decimals for compact reports. */
export function summarize(samples: ArrayLike<number>): Summary {
  const s = Float64Array.from(samples as ArrayLike<number>).sort();
  let sum = 0;
  for (let i = 0; i < s.length; i++) sum += s[i];
  const r = (x: number) => Math.round(x * 1000) / 1000;
  return {
    n: s.length,
    min: r(s[0] ?? NaN),
    p50: r(percentile(s, 0.5)),
    p95: r(percentile(s, 0.95)),
    p99: r(percentile(s, 0.99)),
    max: r(s[s.length - 1] ?? NaN),
    mean: r(s.length ? sum / s.length : NaN),
  };
}

/** Least-squares line fit y = a + b·x. */
export function linearFit(xs: number[], ys: number[]): { a: number; b: number } {
  const n = xs.length;
  let sx = 0,
    sy = 0,
    sxx = 0,
    sxy = 0;
  for (let i = 0; i < n; i++) {
    sx += xs[i];
    sy += ys[i];
    sxx += xs[i] * xs[i];
    sxy += xs[i] * ys[i];
  }
  const b = (n * sxy - sx * sy) / (n * sxx - sx * sx);
  const a = (sy - b * sx) / n;
  return { a, b };
}
