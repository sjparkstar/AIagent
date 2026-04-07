import { getSupabase } from "@remote-desktop/shared";

export interface SearchResult {
  documentId: string;
  title: string;
  content: string;
  category: string;
  url: string;
}

export interface AssistantResponse {
  source: "supabase" | "llm";
  answer: string;
}

/**
 * documents 테이블에서 title 컬럼을 ILIKE 검색하여
 * 유사한 문서의 title, content를 가져온다.
 */
export async function searchDocuments(query: string): Promise<SearchResult[]> {
  const supabase = getSupabase();

  // 검색어를 공백 기준으로 분리하여 각 단어를 OR 검색
  const words = query.split(/\s+/).filter((w) => w.length > 0);
  const orFilter = words.map((w) => `title.ilike.%${w}%`).join(",");

  const { data, error } = await supabase
    .from("documents")
    .select("id, title, content, category, url")
    .or(orFilter)
    .limit(5);

  if (error) {
    console.error("[assistant-search] Supabase query error:", error.message, error.details);
    return [];
  }
  if (!data) return [];

  return data
    .filter((d) => d.title && d.content)
    .map((d) => ({
      documentId: d.id,
      title: d.title,
      content: d.content,
      category: d.category ?? "",
      url: d.url ?? "",
    }));
}

/**
 * SearchResult 배열을 표시용 문자열로 변환한다.
 */
export function formatSearchResults(results: SearchResult[]): string | null {
  if (results.length === 0) return null;

  return results
    .map((r, i) => {
      const header = r.title ? `📄 ${r.title}` : `문서 ${i + 1}`;
      const category = r.category ? ` [${r.category}]` : "";
      const preview = r.content.length > 300
        ? r.content.slice(0, 300) + "..."
        : r.content;
      return `${header}${category}\n${preview}`;
    })
    .join("\n\n");
}

/**
 * 시그널링 서버의 /api/assistant-chat 엔드포인트를 통해
 * Claude API로 답변을 가져온다.
 *
 * @param query - 사용자 질문
 * @param context - Supabase 검색 결과 (있으면 문서 기반 답변, 없으면 LLM 일반 답변)
 */
export async function askAssistant(query: string, context?: string): Promise<AssistantResponse> {
  const serverUrl = `http://${window.location.hostname}:8080`;

  const res = await fetch(`${serverUrl}/api/assistant-chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, context }),
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(err.error ?? `Server error: ${res.status}`);
  }

  return res.json();
}
