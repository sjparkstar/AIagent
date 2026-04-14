import type { IncomingMessage, ServerResponse } from "http";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { PDFDocument, rgb } from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import { log } from "./logger.js";
import { RECORDINGS_DIR, PDFS_DIR } from "./recording-api.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

import { SUPABASE_URL, SUPABASE_ANON_KEY } from "@remote-desktop/shared";

const KIMI_API_KEY = process.env["KIMI_API_KEY"] ?? "";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { ...CORS_HEADERS, "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
    req.on("error", reject);
  });
}

async function callKimi(systemPrompt: string, userMessage: string): Promise<string> {
  const res = await fetch("https://api.moonshot.ai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${KIMI_API_KEY}`,
    },
    body: JSON.stringify({
      model: "moonshot-v1-128k",
      max_tokens: 2048,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userMessage },
      ],
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Kimi API error: ${res.status} ${text}`);
  }

  const data = await res.json() as { choices?: { message: { content: string } }[] };
  return data.choices?.[0]?.message?.content ?? "";
}

async function fetchSessionData(sessionId: string): Promise<{ session: Record<string, unknown>; logs: Record<string, unknown>[] } | null> {
  if (!SUPABASE_URL) return null;

  const headers = {
    "apikey": SUPABASE_ANON_KEY,
    "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
    "Content-Type": "application/json",
  };

  const [sessionRes, logsRes] = await Promise.all([
    fetch(`${SUPABASE_URL}/rest/v1/connection_sessions?id=eq.${sessionId}&select=*`, { headers }),
    fetch(`${SUPABASE_URL}/rest/v1/assistant_logs?session_id=eq.${sessionId}&order=created_at.asc&select=*`, { headers }),
  ]);

  if (!sessionRes.ok) return null;
  const sessions = await sessionRes.json() as Record<string, unknown>[];
  if (!sessions.length) return null;

  const logs = logsRes.ok ? (await logsRes.json() as Record<string, unknown>[]) : [];
  return { session: sessions[0], logs };
}

async function updateSessionPdfUrl(sessionId: string, pdfUrl: string): Promise<void> {
  if (!SUPABASE_URL) return;

  await fetch(`${SUPABASE_URL}/rest/v1/connection_sessions?id=eq.${sessionId}`, {
    method: "PATCH",
    headers: {
      "apikey": SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({ pdf_url: pdfUrl }),
  });
}

function buildPdfContent(
  session: Record<string, unknown>,
  logs: Record<string, unknown>[],
  aiSummary: string,
): string {
  const s = session;
  const connectedAt = s.connected_at ? new Date(s.connected_at as string).toLocaleString("ko-KR") : "-";
  const disconnectedAt = s.disconnected_at ? new Date(s.disconnected_at as string).toLocaleString("ko-KR") : "-";
  const dur = s.connected_at && s.disconnected_at
    ? Math.round((new Date(s.disconnected_at as string).getTime() - new Date(s.connected_at as string).getTime()) / 1000)
    : 0;
  const durStr = dur >= 60 ? `${Math.floor(dur / 60)}분 ${dur % 60}초` : `${dur}초`;

  let text = "";
  text += "=" .repeat(60) + "\n";
  text += "       RemoteCall-mini 상담 세션 요약 보고서\n";
  text += "=".repeat(60) + "\n\n";

  text += "[ 세션 정보 ]\n";
  text += `  접속번호: ${s.room_id ?? "-"}\n`;
  text += `  연결 시간: ${connectedAt}\n`;
  text += `  종료 시간: ${disconnectedAt}\n`;
  text += `  지속 시간: ${durStr}\n`;
  text += `  종료 사유: ${s.disconnect_reason ?? "-"}\n\n`;

  text += "[ 호스트 정보 ]\n";
  text += `  OS: ${s.host_os ?? "-"} ${s.host_os_version ?? ""}\n`;
  text += `  CPU: ${s.host_cpu_model ?? "-"}\n`;
  text += `  메모리: ${s.host_mem_total_mb ? s.host_mem_total_mb + "MB" : "-"}\n\n`;

  text += "[ 연결 품질 ]\n";
  text += `  평균 비트레이트: ${s.avg_bitrate_kbps ?? "-"} kbps\n`;
  text += `  평균 FPS: ${s.avg_framerate ?? "-"}\n`;
  text += `  평균 RTT: ${s.avg_rtt_ms ?? "-"} ms\n`;
  text += `  패킷 손실: ${s.total_packets_lost ?? "-"}\n\n`;

  // 매크로/플레이북 실행 기록
  const macroLogs = logs.filter((l) => {
    const c = String(l.content ?? "");
    return c.includes("매크로 실행") || c.includes("매크로 완료") || c.includes("매크로 실패") ||
      c.includes("플레이북 시작") || c.includes("플레이북 완료") || c.includes("플레이북 오류");
  });

  if (macroLogs.length > 0) {
    text += "[ 매크로/플레이북 실행 기록 ]\n";
    for (const l of macroLogs) {
      const time = l.created_at ? new Date(l.created_at as string).toLocaleTimeString("ko-KR") : "";
      text += `  ${time} ${String(l.content ?? "").slice(0, 200)}\n`;
    }
    text += "\n";
  }

  // AI 대화 기록
  const chatLogs = logs.filter((l) => !macroLogs.includes(l));
  if (chatLogs.length > 0) {
    text += "[ AI Assistant 대화 기록 ]\n";
    for (const l of chatLogs) {
      const time = l.created_at ? new Date(l.created_at as string).toLocaleTimeString("ko-KR") : "";
      const role = l.role === "user" ? "사용자" : l.role === "assistant" ? "AI" : "시스템";
      text += `  [${time}] ${role}: ${String(l.content ?? "").slice(0, 300)}\n`;
    }
    text += "\n";
  }

  text += "-".repeat(60) + "\n";
  text += "[ AI 요약 ]\n\n";
  text += aiSummary + "\n\n";
  text += "=".repeat(60) + "\n";
  text += "이 보고서는 RemoteCall-mini에서 자동 생성되었습니다.\n";

  return text;
}

// 한글 폰트 로드 (NanumGothic)
const FONT_PATH = resolve(__dirname, "..", "fonts", "NanumGothic-Regular.ttf");
let cachedFontBytes: Uint8Array | null = null;
function loadKoreanFont(): Uint8Array {
  if (!cachedFontBytes) {
    cachedFontBytes = readFileSync(FONT_PATH);
  }
  return cachedFontBytes;
}

// pdf-lib 기반 PDF 생성 (한글 지원)
async function createPdf(text: string): Promise<Buffer> {
  const pdfDoc = await PDFDocument.create();
  pdfDoc.registerFontkit(fontkit);

  const fontBytes = loadKoreanFont();
  const koreanFont = await pdfDoc.embedFont(fontBytes, { subset: true });

  const fontSize = 10;
  const pageWidth = 612;
  const pageHeight = 792;
  const margin = 50;
  const lineHeight = 14;
  const maxY = pageHeight - margin;
  const usableWidth = pageWidth - 2 * margin;
  const maxLinesPerPage = Math.floor((pageHeight - 2 * margin) / lineHeight);

  // 긴 줄을 페이지 너비에 맞게 분할
  const wrappedLines: string[] = [];
  for (const rawLine of text.split("\n")) {
    if (rawLine.length === 0) {
      wrappedLines.push("");
      continue;
    }
    let remaining = rawLine;
    while (remaining.length > 0) {
      let end = remaining.length;
      while (end > 1 && koreanFont.widthOfTextAtSize(remaining.slice(0, end), fontSize) > usableWidth) {
        end--;
      }
      wrappedLines.push(remaining.slice(0, end));
      remaining = remaining.slice(end);
    }
  }

  // 페이지별로 분할
  for (let i = 0; i < wrappedLines.length; i += maxLinesPerPage) {
    const pageLines = wrappedLines.slice(i, i + maxLinesPerPage);
    const page = pdfDoc.addPage([pageWidth, pageHeight]);

    let y = maxY;
    for (const line of pageLines) {
      if (line.length > 0) {
        page.drawText(line, {
          x: margin,
          y,
          size: fontSize,
          font: koreanFont,
          color: rgb(0, 0, 0),
        });
      }
      y -= lineHeight;
    }
  }

  if (pdfDoc.getPageCount() === 0) {
    pdfDoc.addPage([pageWidth, pageHeight]);
  }

  const pdfBytes = await pdfDoc.save();
  return Buffer.from(pdfBytes);
}

export async function handleSummarizeSession(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (req.method === "OPTIONS") {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }

  if (req.method !== "POST") {
    sendJson(res, 405, { error: "Method not allowed" });
    return;
  }

  try {
    const body = JSON.parse(await readBody(req)) as { sessionId: string };
    const { sessionId } = body;

    if (!sessionId) {
      sendJson(res, 400, { error: "sessionId required" });
      return;
    }

    log(`[summarize] starting for session ${sessionId}`);

    // Supabase에서 세션 데이터 조회
    const data = await fetchSessionData(sessionId);
    if (!data) {
      sendJson(res, 404, { error: "Session not found" });
      return;
    }

    // AI 요약 생성
    let aiSummary = "AI 요약을 생성할 수 없습니다.";
    if (KIMI_API_KEY) {
      try {
        const sessionContext = JSON.stringify({
          roomId: data.session.room_id,
          hostOs: data.session.host_os,
          duration: data.session.connected_at && data.session.disconnected_at
            ? Math.round((new Date(data.session.disconnected_at as string).getTime() - new Date(data.session.connected_at as string).getTime()) / 1000)
            : 0,
          disconnectReason: data.session.disconnect_reason,
          avgRtt: data.session.avg_rtt_ms,
          chatLogs: data.logs.slice(0, 50).map((l) => ({
            role: l.role,
            content: String(l.content ?? "").slice(0, 200),
          })),
        });

        aiSummary = await callKimi(
          "당신은 원격 지원 상담 세션 분석 전문가입니다. 제공된 세션 데이터를 분석하여 한국어로 상담 요약 보고서를 작성하세요. " +
          "다음 항목을 포함하세요: 1) 상담 개요, 2) 주요 이슈 및 조치사항, 3) 연결 품질 평가, 4) 개선 권장사항",
          sessionContext,
        );
      } catch (e) {
        log(`[summarize] Kimi error: ${e}`);
      }
    }

    // PDF 생성 (한글 폰트 임베딩)
    const textContent = buildPdfContent(data.session, data.logs, aiSummary);
    const pdfBuffer = await createPdf(textContent);

    const pdfFilename = `${sessionId}-summary.pdf`;
    const pdfPath = resolve(PDFS_DIR, pdfFilename);
    writeFileSync(pdfPath, pdfBuffer);

    const pdfUrl = `/api/pdfs/${encodeURIComponent(pdfFilename)}`;

    // DB 업데이트
    await updateSessionPdfUrl(sessionId, pdfUrl);

    log(`[summarize] PDF created: ${pdfFilename} (${Math.round(pdfBuffer.length / 1024)}KB)`);
    sendJson(res, 200, { pdfUrl });
  } catch (err) {
    log(`[summarize] error: ${err}`);
    sendJson(res, 500, { error: String(err) });
  }
}
