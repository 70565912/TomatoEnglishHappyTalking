import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import type { Plugin } from 'vite';

function normalizeGeneratedHtml(content: string): string {
  const normalized = content
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map((line) => line.replace(/[ \t]+$/g, ''))
    .join('\n');

  return normalized.endsWith('\n') ? normalized : `${normalized}\n`;
}

function normalizeHtmlBuildOutput(): Plugin {
  return {
    name: 'tomato-normalize-html-build-output',
    apply: 'build',
    enforce: 'post',
    generateBundle(_, bundle) {
      for (const asset of Object.values(bundle)) {
        if (
          asset.type === 'asset' &&
          asset.fileName.toLowerCase().endsWith('.html') &&
          typeof asset.source === 'string'
        ) {
          asset.source = normalizeGeneratedHtml(asset.source);
        }
      }
    },
  };
}

export default defineConfig({
  base: './',
  plugins: [react(), normalizeHtmlBuildOutput()],
  build: {
    outDir: '../app/assets/web',
    emptyOutDir: true,
  },
  test: {
    environment: 'jsdom',
    setupFiles: './src/test/setup.ts',
  },
});
