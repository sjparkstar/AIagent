import type { IncomingMessage, ServerResponse } from "http";
import { createWriteStream, createReadStream, existsSync, mkdirSync, statSync } from "fs";
import { resolve, extname } from "path";
import { log } from "./logger.js";

const RECORDINGS_DIR = resolve(process.cwd(), "recordings");
const PDFS_DIR = resolve(process.cwd(), "pdfs");

if (!existsSync(RECORDINGS_DIR)) mkdirSync(RECORDINGS_DIR, { recursive: true });
if (!existsSync(PDFS_DIR)) mkdirSync(PDFS_DIR, { recursive: true });

export { RECORDINGS_DIR, PDFS_DIR };

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export function handleRecordingRoutes(req: IncomingMessage, res: ServerResponse): boolean {
  const url = req.url ?? "";

  if (req.method === "OPTIONS" && (url.startsWith("/api/upload-recording") || url.startsWith("/api/recordings/") || url.startsWith("/api/pdfs/"))) {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return true;
  }

  if (req.method === "POST" && url === "/api/upload-recording") {
    handleUpload(req, res);
    return true;
  }

  if (req.method === "GET" && url.startsWith("/api/recordings/")) {
    const filename = decodeURIComponent(url.slice("/api/recordings/".length));
    serveFile(res, RECORDINGS_DIR, filename, "video/webm");
    return true;
  }

  if (req.method === "GET" && url.startsWith("/api/pdfs/")) {
    const filename = decodeURIComponent(url.slice("/api/pdfs/".length));
    serveFile(res, PDFS_DIR, filename, "application/pdf");
    return true;
  }

  return false;
}

function handleUpload(req: IncomingMessage, res: ServerResponse): void {
  const contentType = req.headers["content-type"] ?? "";

  if (!contentType.includes("multipart/form-data")) {
    res.writeHead(400, { ...CORS_HEADERS, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "multipart/form-data required" }));
    return;
  }

  const boundary = contentType.split("boundary=")[1];
  if (!boundary) {
    res.writeHead(400, { ...CORS_HEADERS, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "boundary not found" }));
    return;
  }

  const chunks: Buffer[] = [];
  let totalSize = 0;
  const MAX_SIZE = 500 * 1024 * 1024; // 500MB

  req.on("data", (chunk: Buffer) => {
    totalSize += chunk.length;
    if (totalSize > MAX_SIZE) {
      res.writeHead(413, { ...CORS_HEADERS, "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "File too large (max 500MB)" }));
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on("end", () => {
    try {
      const body = Buffer.concat(chunks);
      const { fileData, sessionId } = parseMultipart(body, boundary);

      if (!fileData || !sessionId) {
        res.writeHead(400, { ...CORS_HEADERS, "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "file and sessionId required" }));
        return;
      }

      const filename = `${sessionId}.webm`;
      const filepath = resolve(RECORDINGS_DIR, filename);
      const ws = createWriteStream(filepath);
      ws.write(fileData);
      ws.end();

      const recordingUrl = `/api/recordings/${encodeURIComponent(filename)}`;
      log(`[recording] saved ${filename} (${Math.round(fileData.length / 1024)}KB)`);

      res.writeHead(200, { ...CORS_HEADERS, "Content-Type": "application/json" });
      res.end(JSON.stringify({ url: recordingUrl, filename }));
    } catch (e) {
      log(`[recording] upload error: ${e}`);
      res.writeHead(500, { ...CORS_HEADERS, "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: String(e) }));
    }
  });
}

function parseMultipart(body: Buffer, boundary: string): { fileData: Buffer | null; sessionId: string } {
  const boundaryBuf = Buffer.from(`--${boundary}`);
  let sessionId = "";
  let fileData: Buffer | null = null;

  const parts = splitBuffer(body, boundaryBuf);

  for (const part of parts) {
    const headerEnd = part.indexOf("\r\n\r\n");
    if (headerEnd === -1) continue;

    const header = part.slice(0, headerEnd).toString();
    const content = part.slice(headerEnd + 4);

    // 끝에 \r\n 제거
    const trimmed = content.length >= 2 && content[content.length - 2] === 0x0d && content[content.length - 1] === 0x0a
      ? content.slice(0, content.length - 2)
      : content;

    if (header.includes('name="sessionId"')) {
      sessionId = trimmed.toString().trim();
    } else if (header.includes('name="file"')) {
      fileData = trimmed;
    }
  }

  return { fileData, sessionId };
}

function splitBuffer(buf: Buffer, delimiter: Buffer): Buffer[] {
  const parts: Buffer[] = [];
  let start = 0;

  while (start < buf.length) {
    const idx = buf.indexOf(delimiter, start);
    if (idx === -1) {
      parts.push(buf.slice(start));
      break;
    }
    if (idx > start) {
      parts.push(buf.slice(start, idx));
    }
    start = idx + delimiter.length;
  }

  return parts;
}

function serveFile(res: ServerResponse, dir: string, filename: string, contentType: string): void {
  // 경로 탐색 공격 방지
  if (filename.includes("..") || filename.includes("/") || filename.includes("\\")) {
    res.writeHead(400, CORS_HEADERS);
    res.end("Invalid filename");
    return;
  }

  const filepath = resolve(dir, filename);
  if (!existsSync(filepath)) {
    res.writeHead(404, CORS_HEADERS);
    res.end("Not found");
    return;
  }

  const stat = statSync(filepath);
  const headers: Record<string, string | number> = {
    ...CORS_HEADERS,
    "Content-Type": contentType,
    "Content-Length": stat.size,
  };

  // Range 요청 지원 (비디오 스트리밍)
  const range = (res.req ?? {} as IncomingMessage).headers?.range;
  if (range && contentType.startsWith("video/")) {
    const match = /bytes=(\d+)-(\d*)/.exec(range);
    if (match) {
      const start = parseInt(match[1], 10);
      const end = match[2] ? parseInt(match[2], 10) : stat.size - 1;
      headers["Content-Range"] = `bytes ${start}-${end}/${stat.size}`;
      headers["Accept-Ranges"] = "bytes";
      headers["Content-Length"] = end - start + 1;
      res.writeHead(206, headers);
      createReadStream(filepath, { start, end }).pipe(res);
      return;
    }
  }

  headers["Accept-Ranges"] = "bytes";
  res.writeHead(200, headers);
  createReadStream(filepath).pipe(res);
}
