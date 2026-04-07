import type { IncomingMessage, ServerResponse } from "http";
import { log } from "./logger.js";

const KIMI_API_KEY = process.env["KIMI_API_KEY"] ?? "";

interface AssistantRequest {
  query: string;
  context?: string;
}

interface KimiResponse {
  choices?: { message: { content: string } }[];
}

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
      max_tokens: 1024,
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

  const data = (await res.json()) as KimiResponse;
  return data.choices?.[0]?.message?.content ?? "답변을 생성할 수 없습니다.";
}

export async function handleAssistantChat(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (req.method === "OPTIONS") {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }

  if (req.method !== "POST") {
    sendJson(res, 405, { error: "Method not allowed" });
    return;
  }

  if (!KIMI_API_KEY) {
    sendJson(res, 500, { error: "KIMI_API_KEY not configured" });
    return;
  }

  try {
    const body = JSON.parse(await readBody(req)) as AssistantRequest;
    const { query, context } = body;

    if (!query || typeof query !== "string") {
      sendJson(res, 400, { error: "query is required" });
      return;
    }

    let systemPrompt: string;
    let source: "supabase" | "llm";

    if (context) {
      systemPrompt =
        "당신은 리모트콜(RemoteCall) 고객지원 어시스턴트입니다. " +
        "아래 문서를 참고하여 사용자 질문에 한국어로 답변하세요. " +
        "문서에 없는 내용은 추측하지 마세요.\n\n## 참고 문서\n" + context;
      source = "supabase";
    } else {
      systemPrompt =
        "당신은 리모트콜(RemoteCall) 고객지원 어시스턴트입니다. " +
        "내부 문서에서 관련 정보를 찾지 못했습니다. " +
        "일반 지식을 활용하여 한국어로 답변하세요. " +
        "확실하지 않은 내용은 '정확한 정보는 고객센터에 문의해주세요'라고 안내하세요.";
      source = "llm";
    }

    log(`[assistant] query="${query.slice(0, 50)}" source=${source}`);
    const answer = await callKimi(systemPrompt, query);

    sendJson(res, 200, { source, answer });
  } catch (err) {
    log(`[assistant] error: ${String(err)}`);
    sendJson(res, 500, { error: String(err) });
  }
}
