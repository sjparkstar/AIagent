import http from "http";
import { WebSocketServer } from "ws";
import { DEFAULT_PORT } from "@remote-desktop/shared";
import { log } from "./logger.js";
import { attachWebSocketHandlers } from "./server.js";

const PORT = parseInt(process.env["PORT"] ?? String(DEFAULT_PORT), 10);

const httpServer = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({ status: "ok", timestamp: new Date().toISOString() })
    );
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server: httpServer });
attachWebSocketHandlers(wss);

httpServer.listen(PORT, "0.0.0.0", () => {
  log(`Signaling server listening on port ${PORT}`);
  log(`Health check: http://localhost:${PORT}/health`);
});

process.on("SIGTERM", () => {
  log("SIGTERM received, shutting down gracefully");
  wss.close(() => {
    httpServer.close(() => process.exit(0));
  });
});

process.on("SIGINT", () => {
  log("SIGINT received, shutting down gracefully");
  wss.close(() => {
    httpServer.close(() => process.exit(0));
  });
});
