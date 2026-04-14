import "dotenv/config";
import http from "http";
import { WebSocketServer } from "ws";
import { DEFAULT_PORT } from "@remote-desktop/shared";
import { log } from "./logger.js";
import { attachWebSocketHandlers } from "./server.js";
import { handleAssistantChat } from "./assistant-api.js";
import { handleDownloadPage } from "./download-page.js";
import { handleRecordingRoutes } from "./recording-api.js";
import { handleSummarizeSession } from "./summarize-api.js";
import { handleChatRoutes } from "./chat-api.js";
import { handleDiagnosisRoutes } from "./diagnosis-api.js";

const PORT = parseInt(process.env["PORT"] ?? String(DEFAULT_PORT), 10);

const httpServer = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({ status: "ok", timestamp: new Date().toISOString() })
    );
    return;
  }
  if (handleDownloadPage(req, res)) return;
  if (handleRecordingRoutes(req, res)) return;
  if (handleChatRoutes(req, res)) return;
  if (handleDiagnosisRoutes(req, res)) return;
  if (req.url === "/api/summarize-session" || (req.method === "OPTIONS" && req.url === "/api/summarize-session")) {
    handleSummarizeSession(req, res).catch(() => { res.writeHead(500); res.end(); });
    return;
  }
  if (req.url === "/api/assistant-chat") {
    handleAssistantChat(req, res).catch(() => {
      res.writeHead(500);
      res.end();
    });
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
  log(`Download page: http://localhost:${PORT}/download`);
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
