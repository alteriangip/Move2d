/**
 * Getting files in and out on iPad, where there are no native save dialogs:
 * inside claude.ai the page uses the host's download capability; elsewhere the
 * Web Share sheet ("Save to Files") with a plain download as fallback.
 */
interface DownloadsNs {
  save(o: { filename: string; data: Blob | string }): Promise<unknown>;
}

export async function saveFile(name: string, bytes: Uint8Array, mime: string): Promise<'saved' | 'shared' | 'downloaded' | 'cancelled'> {
  const blob = new Blob([bytes as Uint8Array<ArrayBuffer>], { type: mime });
  const w = window as unknown as { claude?: { use(n: string): Promise<unknown> } };
  const dl = (w.claude ? await w.claude.use('downloads').catch(() => null) : null) as DownloadsNs | null;
  if (dl) {
    await dl.save({ filename: name, data: blob });
    return 'saved';
  }
  const file = new File([blob], name, { type: mime });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: name });
      return 'shared';
    } catch (e) {
      if ((e as Error).name === 'AbortError') return 'cancelled';
    }
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
  return 'downloaded';
}

/** Opens the system file picker. */
export function pickFile(accept: string): Promise<File | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = accept;
    input.onchange = () => resolve(input.files?.[0] ?? null);
    input.oncancel = () => resolve(null);
    input.click();
  });
}

export const safeName = (s: string) => s.replace(/[\\/:*?"<>|]+/g, '_').trim() || 'project';
