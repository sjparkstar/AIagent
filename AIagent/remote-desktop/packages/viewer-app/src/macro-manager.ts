import { getSupabase } from "@remote-desktop/shared";

export interface Macro {
  id: string;
  name: string;
  description: string;
  category: string;
  command_type: string;
  command: string;
  os: string;
  requires_admin: boolean;
  is_dangerous: boolean;
  enabled: boolean;
  sort_order: number;
}

export async function fetchMacros(): Promise<Macro[]> {
  const { data, error } = await getSupabase()
    .from("macros")
    .select("*")
    .eq("enabled", true)
    .order("sort_order");
  if (error || !data) return [];
  return data as Macro[];
}

export async function createMacro(macro: Omit<Macro, "id">): Promise<Macro | null> {
  const { data, error } = await getSupabase()
    .from("macros")
    .insert(macro)
    .select()
    .single();
  if (error || !data) return null;
  return data as Macro;
}

export async function updateMacro(id: string, fields: Partial<Macro>): Promise<boolean> {
  const { error } = await getSupabase()
    .from("macros")
    .update({ ...fields, updated_at: new Date().toISOString() })
    .eq("id", id);
  return !error;
}

export async function deleteMacro(id: string): Promise<boolean> {
  const { error } = await getSupabase()
    .from("macros")
    .delete()
    .eq("id", id);
  return !error;
}

const CATEGORY_LABELS: Record<string, string> = {
  network: "네트워크",
  process: "프로세스/서비스",
  cleanup: "시스템 정리",
  diagnostic: "진단/로그",
  security: "보안/정책",
  system: "시스템 제어",
  general: "일반",
};

export function renderMacroList(
  container: HTMLElement,
  macros: Macro[],
  onEdit: (m: Macro) => void,
  onDelete: (m: Macro) => void,
  onRun: (m: Macro) => void,
  mode: "full" | "run-only" = "full"
): void {
  const grouped = new Map<string, Macro[]>();
  for (const m of macros) {
    const cat = m.category || "general";
    if (!grouped.has(cat)) grouped.set(cat, []);
    grouped.get(cat)!.push(m);
  }

  const osIcon = (os: string) => {
    if (os === "win32") return "🪟";
    if (os === "darwin") return "🍎";
    if (os === "linux") return "🐧";
    return "🌐";
  };

  let html = "";
  for (const [cat, items] of grouped) {
    html += `<div class="macro-category"><div class="macro-cat-title">${CATEGORY_LABELS[cat] ?? cat}</div>`;
    for (const m of items) {
      html += `
        <div class="macro-item" data-id="${m.id}">
          <div class="macro-item-info">
            <span class="macro-item-name">${osIcon(m.os)} ${m.name}</span>
            <span class="macro-item-desc">${m.description ?? ""}</span>
          </div>
          <div class="macro-item-actions">
            <button class="btn macro-btn macro-run-btn" data-action="run" title="실행">▶</button>
            ${mode === "full" ? `<button class="btn macro-btn macro-edit-btn" data-action="edit" title="수정">✎</button>
            <button class="btn macro-btn macro-del-btn" data-action="delete" title="삭제">✕</button>` : `<button class="btn macro-btn" data-action="view" title="보기">👁</button>`}
          </div>
        </div>`;
    }
    html += `</div>`;
  }

  container.innerHTML = html;

  container.querySelectorAll<HTMLButtonElement>(".macro-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const item = btn.closest<HTMLElement>("[data-id]");
      if (!item) return;
      const macro = macros.find((m) => m.id === item.dataset["id"]);
      if (!macro) return;
      const action = btn.dataset["action"];
      if (action === "run") onRun(macro);
      else if (action === "edit") onEdit(macro);
      else if (action === "delete") onDelete(macro);
      else if (action === "view") alert(`${macro.name}\n\n${macro.description ?? ""}\n\n명령어: ${macro.command}\nOS: ${macro.os}\n타입: ${macro.command_type}`);
    });
  });
}
