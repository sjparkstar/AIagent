import { resolve } from "path";
import { defineConfig } from "vite";

export default defineConfig({
  root: resolve(__dirname, "src/renderer"),
  resolve: {
    alias: {
      "@remote-desktop/shared": resolve(__dirname, "../shared/src/index.ts"),
    },
  },
  server: {
    port: 5173,
  },
  build: {
    outDir: resolve(__dirname, "dist/renderer"),
    emptyOutDir: true,
  },
  base: "./",
});
