import { resolve } from "path";
import { defineConfig, externalizeDepsPlugin } from "electron-vite";

const sharedAlias = {
  "@remote-desktop/shared": resolve(__dirname, "../shared/src/index.ts"),
};

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()],
    resolve: { alias: sharedAlias },
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    resolve: { alias: sharedAlias },
  },
  renderer: {
    resolve: {
      alias: {
        "@renderer": resolve(__dirname, "src/renderer"),
        ...sharedAlias,
      },
    },
  },
});
