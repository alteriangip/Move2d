import { describe, it, expect } from 'vitest';
import { generatePsd, type SynthSpec } from '../src/psd-synth';
import { agStructure, agEager, agLazy, webtoon, census } from '../src/psd-bench';

const spec: SynthSpec = { name: 'test', width: 600, height: 900, layers: 24, sizeFrac: [0.05, 0.3], seed: 99 };

describe('synthetic PSD round trip', () => {
  const g = generatePsd(spec);
  it('generates the requested number of layers in nested groups', () => {
    expect(g.expected.length).toBe(24);
    expect(g.groups).toBeGreaterThan(2);
    expect(g.buffer.byteLength).toBeGreaterThan(1000);
  });
  it('ag-psd structure parse preserves names, order, bounds, opacity, visibility, blend, clipping', () => {
    const r = agStructure(g.buffer, g.expected);
    expect(r.ok).toBe(true);
    expect(r.fidelity!.firstMismatch).toBeUndefined();
    expect(r.fidelity!.mismatches).toBe(0);
  });
  it('ag-psd eager decodes all layer pixels with correct sizes', () => {
    const r = agEager(g.buffer, g.expected);
    expect(r.ok).toBe(true);
    expect(r.fidelity!.mismatches).toBe(0);
    expect(r.decodedBytes).toBe(g.rawLayerBytes);
  });
  it('ag-psd lazy decodes the same pixels one layer at a time', async () => {
    const r = await agLazy(g.buffer, g.expected);
    expect(r.ok).toBe(true);
    expect(r.decodedBytes).toBe(g.rawLayerBytes);
  });
  it('@webtoon/psd parses the same structure and pixels', async () => {
    const r = await webtoon(g.buffer, g.expected);
    expect(r.error).toBeUndefined();
    expect(r.fidelity!.firstMismatch).toBeUndefined();
    expect(r.decodedBytes).toBe(g.rawLayerBytes);
  });
  it('census counts features', () => {
    const c = census(g.buffer) as Record<string, number>;
    expect(c.pixelLayers).toBe(24);
    expect(c.maxDepth).toBe(3);
  });
});
