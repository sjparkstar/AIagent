import { defineConfig } from "vite";
import path from "path";

export default defineConfig({
  resolve: {
    alias: {
      "@remote-desktop/shared": path.resolve(
        __dirname,
        "../shared/src/index.ts"
      ),
    },
  },
  server: {
    port: 3000,
    host: "0.0.0.0",
  },
});
