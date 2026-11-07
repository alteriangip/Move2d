import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

// default ("artifact"): one self-contained HTML file (claude.ai hosting)
// "pages": static site with manifest + service worker (installable PWA, offline)
export default defineConfig(({ mode }) => ({
  base: './',
  plugins: mode === 'pages' ? [react()] : [react(), viteSingleFile()],
  worker: { format: 'es' },
  build: { outDir: mode === 'pages' ? 'dist-pages' : 'dist', target: 'es2022', assetsInlineLimit: mode === 'pages' ? 4096 : 100_000_000 },
  test: { environment: 'node', include: ['tests/**/*.test.ts'] },
}));
