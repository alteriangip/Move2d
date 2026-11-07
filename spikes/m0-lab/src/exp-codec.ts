/**
 * Video export capabilities: WebCodecs encoder configurations, a real 1080p
 * H.264 encode throughput test, and MediaRecorder MIME support.
 */
import type { Experiment } from './experiment';
import { round, MB } from './experiment';

const CONFIGS: { label: string; codec: string; width: number; height: number; alpha?: 'keep' }[] = [
  { label: 'H.264 Baseline 720p', codec: 'avc1.42E01F', width: 1280, height: 720 },
  { label: 'H.264 Baseline 1080p', codec: 'avc1.42E028', width: 1920, height: 1080 },
  { label: 'H.264 Main 1080p', codec: 'avc1.4D0028', width: 1920, height: 1080 },
  { label: 'H.264 High 1080p', codec: 'avc1.640028', width: 1920, height: 1080 },
  { label: 'H.264 High 4K', codec: 'avc1.640033', width: 3840, height: 2160 },
  { label: 'HEVC Main 1080p', codec: 'hvc1.1.6.L120.90', width: 1920, height: 1080 },
  { label: 'VP8 1080p', codec: 'vp8', width: 1920, height: 1080 },
  { label: 'VP9 1080p', codec: 'vp09.00.40.08', width: 1920, height: 1080 },
  { label: 'VP9 1080p + alpha', codec: 'vp09.00.40.08', width: 1920, height: 1080, alpha: 'keep' },
  { label: 'AV1 1080p', codec: 'av01.0.08M.08', width: 1920, height: 1080 },
];

const MR_TYPES = ['video/mp4', 'video/mp4;codecs=avc1', 'video/mp4;codecs=hvc1', 'video/webm', 'video/webm;codecs=vp8', 'video/webm;codecs=vp9'];

export const codecLab: Experiment = {
  id: 'video-export',
  title: 'Video export (WebCodecs / MediaRecorder)',
  summary: 'Checks encoder configs and encodes 120 frames of 1080p H.264 from a canvas to measure throughput.',
  async run(ctx) {
    const out: Record<string, unknown> = {};
    out.mediaRecorder =
      typeof MediaRecorder !== 'undefined' ? Object.fromEntries(MR_TYPES.map((t) => [t, MediaRecorder.isTypeSupported(t)])) : 'unavailable';
    if (typeof VideoEncoder === 'undefined') {
      out.webCodecs = 'VideoEncoder unavailable';
      return out;
    }
    const support: Record<string, unknown> = {};
    for (const c of CONFIGS) {
      try {
        const r = await VideoEncoder.isConfigSupported({ codec: c.codec, width: c.width, height: c.height, bitrate: 8_000_000, framerate: 30, alpha: c.alpha });
        support[c.label] = r.supported;
      } catch (e) {
        support[c.label] = `error: ${(e as Error).message}`;
      }
    }
    out.encoderSupport = support;

    const pick = CONFIGS.slice(1, 4).find((c) => support[c.label] === true);
    if (!pick) return out;
    ctx.log(`encoding 120 frames with ${pick.label}…`);
    const canvas = document.createElement('canvas');
    canvas.width = 1920;
    canvas.height = 1080;
    const g = canvas.getContext('2d')!;
    let bytes = 0,
      chunks = 0,
      err: string | null = null;
    const enc = new VideoEncoder({
      output: (chunk) => {
        bytes += chunk.byteLength;
        chunks++;
      },
      error: (e) => (err = e.message),
    });
    enc.configure({ codec: pick.codec, width: 1920, height: 1080, bitrate: 8_000_000, framerate: 30, latencyMode: 'quality' });
    const FRAMES = 120;
    const t0 = performance.now();
    let drawMs = 0;
    for (let i = 0; i < FRAMES; i++) {
      const d0 = performance.now();
      g.fillStyle = `hsl(${(i * 3) % 360},50%,20%)`;
      g.fillRect(0, 0, 1920, 1080);
      g.fillStyle = '#fff';
      g.beginPath();
      g.arc(200 + i * 12, 540 + Math.sin(i / 8) * 300, 120, 0, Math.PI * 2);
      g.fill();
      drawMs += performance.now() - d0;
      const frame = new VideoFrame(canvas, { timestamp: (i * 1e6) / 30 });
      enc.encode(frame, { keyFrame: i % 60 === 0 });
      frame.close();
      while (enc.encodeQueueSize > 8) await new Promise((r) => setTimeout(r, 1));
    }
    await enc.flush();
    const ms = performance.now() - t0;
    enc.close();
    out.encode1080p = {
      config: pick.label,
      frames: FRAMES,
      chunks,
      totalMs: round(ms),
      encodeFps: round(FRAMES / (ms / 1000), 1),
      canvasDrawMsTotal: round(drawMs),
      outputMB: round(bytes / MB, 2),
      error: err,
    };
    return out;
  },
};
