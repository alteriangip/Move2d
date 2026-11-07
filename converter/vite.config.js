import { defineConfig } from 'vite';
export default defineConfig({
  build: {
    outDir: 'dist-converter', emptyOutDir: true, target: 'es2020', minify: true,
    lib: { entry: new URL('./entry.js', import.meta.url).pathname, formats: ['es'], fileName: () => 'converter.js' },
    rollupOptions: { output: { inlineDynamicImports: true } },
  },
});
