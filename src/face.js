// Face shape keys (morph targets). Works with MMD Japanese names, VRM/ARKit and plain English names.
const MEANINGS = {
  blink: ['まばたき', 'blink', 'eyeclose', 'eyesclosed', 'eyesclose', '目閉じ', 'eyeblink', 'eyeblinkboth', 'close'],
  wink: ['ウィンク', 'wink', 'ウィンク2', 'blinkl', 'eyeblinkleft', 'eyeclosel', 'winkl', 'ウィンク右', 'blinkleft'],
  smile: ['笑い', 'smile', 'にこり', 'joy', 'happy', 'fun', '笑顔', 'mouthsmile', 'eyesmile', 'にっこり'],
  mouthA: ['あ', 'a', 'aa', 'vrcvaa', 'moutha', 'mouthopen', 'jawopen', 'open'],
  mouthO: ['お', 'o', 'oh', 'vrcvoh', 'moutho'],
  angry: ['怒り', 'angry', 'anger', 'mad'],
  sad: ['困る', 'sad', 'sorrow', 'troubled'],
  surprised: ['びっくり', 'surprised', 'surprise', 'shock'],
};
const norm = s => s.toLowerCase().replace(/[\s_.\-:]/g, '').replace(/[０-９]/g, c => '０１２３４５６７８９'.indexOf(c));

export class Face {
  constructor(root) {
    this.meshes = [];
    const names = new Set();
    root.traverse(o => {
      if (o.morphTargetDictionary && o.morphTargetInfluences) {
        this.meshes.push(o);
        Object.keys(o.morphTargetDictionary).forEach(n => names.add(n));
      }
    });
    this.names = [...names];
    this.values = Object.fromEntries(this.names.map(n => [n, 0]));
  }
  set(name, v) {
    this.values[name] = v;
    for (const m of this.meshes) {
      const i = m.morphTargetDictionary[name];
      if (i !== undefined) m.morphTargetInfluences[i] = v;
    }
  }
  reset() { for (const n of this.names) if (this.values[n]) this.set(n, 0); }
  find(meaning) {
    const list = MEANINGS[meaning] || [meaning];
    const ns = this.names.map(n => [n, norm(n)]);
    for (const a of list) { const hit = ns.find(([, k]) => k === norm(a)); if (hit) return hit[0]; }
    for (const a of list) {
      if (norm(a).length < 3) continue;
      const hit = ns.find(([, k]) => k.includes(norm(a)));
      if (hit) return hit[0];
    }
    return null;
  }
  setMeaning(meaning, v) { const n = this.find(meaning); if (n) this.set(n, v); return n; }
  snapshot() { return Object.fromEntries(Object.entries(this.values).filter(([, v]) => v > 1e-4)); }
  restore(s = {}) { for (const n of this.names) { const v = s[n] || 0; if (v !== this.values[n]) this.set(n, v); } }
}
