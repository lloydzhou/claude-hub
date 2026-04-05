const { defineConfig } = require('vite');

module.exports = defineConfig({
  base: './',
  build: {
    outDir: 'html',
    emptyOutDir: false,
  },
});
