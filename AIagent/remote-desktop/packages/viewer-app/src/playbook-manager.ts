import { getSupabase } from "@remote-desktop/shared";

export interface PlaybookStep {
  name: string;
  command: string;
  commandType: string;
  validateContains?: string;
}

export interface Playbook {
  id: string;
  name: string;
  description: string;
  steps: PlaybookStep[];
  enabled: boolean;
  sort_order: number;
}

export async function fetchPlaybooks(): Promise<Playbook[]> {
  const { data, error } = await getSupabase()
    .from("playbooks")
    .select("*")
    .eq("enabled", true)
    .order("sort_order");
  if (error || !data) return [];
  return data.map((d) => ({
    ...d,
    steps: Array.isArray(d.steps) ? d.steps : [],
  })) as Playbook[];
}

export async function createPlaybook(pb: Omit<Playbook, "id">): Promise<Playbook | null> {
  const { data, error } = await getSupabase()
    .from("playbooks")
    .insert({ ...pb, steps: JSON.parse(JSON.stringify(pb.steps)) })
    .select()
    .single();
  if (error || !data) return null;
  return { ...data, steps: Array.isArray(data.steps) ? data.steps : [] } as Playbook;
}

export async function updatePlaybook(id: string, fields: Partial<Playbook>): Promise<boolean> {
  const update: Record<string, unknown> = { ...fields, updated_at: new Date().toISOString() };
  if (fields.steps) update.steps = JSON.parse(JSON.stringify(fields.steps));
  const { error } = await getSupabase().from("playbooks").update(update).eq("id", id);
  return !error;
}

export async function deletePlaybook(id: string): Promise<boolean> {
  const { error } = await getSupabase().from("playbooks").delete().eq("id", id);
  return !error;
}
