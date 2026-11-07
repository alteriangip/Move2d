import { defineConfig } from 'vite';
import { viteSingleFile } from 'vite-plugin-singlefile';

// "artifact" (default): one self-contained HTML file for claude.ai hosting.
// "pages": a normal static build with manifest + service worker for installation tests.
export default defineConfig(({ mode }) => ({
  base: './',
  plugins: mode === 'pages' ? [] : [viteSingleFile()],
  build: {
    outDir: mode === 'pages' ? 'dist-pages' : 'dist',
    target: 'es2022',
    assetsInlineLimit: mode === 'pages' ? 4096 : 100_000_000,
  },
  test: { environment: 'node', include: ['tests/**/*.test.ts'], testTimeout: 60_000 },
}));
