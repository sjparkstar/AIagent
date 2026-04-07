const { existsSync } = require("fs");
const { spawn } = require("child_process");
const { join } = require("path");

const mainFile = join(__dirname, "..", "dist", "main", "index.js");
const maxWait = 30000;
const interval = 500;
let waited = 0;

function tryStart() {
  if (existsSync(mainFile)) {
    const electron = require("electron");
    const electronPath = typeof electron === "string" ? electron : electron.default || electron;
    const child = spawn(electronPath, ["."], {
      cwd: join(__dirname, ".."),
      stdio: "inherit",
      env: { ...process.env, ELECTRON_RENDERER_URL: "http://localhost:5173", ELECTRON_RUN_AS_NODE: "" },
    });
    child.on("close", () => process.exit());
    return;
  }
  waited += interval;
  if (waited >= maxWait) {
    console.error("Timed out waiting for main process build");
    process.exit(1);
  }
  setTimeout(tryStart, interval);
}

tryStart();
