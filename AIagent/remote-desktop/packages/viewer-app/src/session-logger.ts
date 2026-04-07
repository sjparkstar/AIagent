import { getSupabase } from "@remote-desktop/shared";
import type { HostSystemInfo } from "@remote-desktop/shared";

interface SessionStats {
  bitrateKbps: number;
  framerate: number;
  rttMs: number;
  packetsLost: number;
  bytesReceived: number;
}

let sessionId: string | null = null;
let statsSnapshots: SessionStats[] = [];

export async function startSession(roomId: string, viewerId: string): Promise<void> {
  const supabase = getSupabase();

  const { data, error } = await supabase
    .from("connection_sessions")
    .insert({
      room_id: roomId,
      viewer_id: viewerId,
      viewer_user_agent: navigator.userAgent,
      viewer_screen_width: window.screen.width,
      viewer_screen_height: window.screen.height,
      viewer_language: navigator.language,
    })
    .select("id")
    .single();

  if (error) {
    console.error("[session-logger] insert error:", error.message);
    return;
  }

  sessionId = data.id;
  statsSnapshots = [];
}

export async function updateHostInfo(info: HostSystemInfo): Promise<void> {
  if (!sessionId) return;
  const supabase = getSupabase();

  await supabase
    .from("connection_sessions")
    .update({
      host_os: info.os,
      host_os_version: info.version,
      host_cpu_model: info.cpuModel,
      host_mem_total_mb: info.memTotal,
    })
    .eq("id", sessionId);
}

export function recordStats(stats: SessionStats): void {
  statsSnapshots.push(stats);
}

export async function endSession(reason: string): Promise<void> {
  if (!sessionId) return;
  const supabase = getSupabase();

  const avg = (arr: number[]): number =>
    arr.length > 0 ? Math.round(arr.reduce((a, b) => a + b, 0) / arr.length * 10) / 10 : 0;

  const totalPacketsLost = statsSnapshots.length > 0
    ? statsSnapshots[statsSnapshots.length - 1].packetsLost
    : 0;
  const totalBytes = statsSnapshots.length > 0
    ? statsSnapshots[statsSnapshots.length - 1].bytesReceived
    : 0;

  await supabase
    .from("connection_sessions")
    .update({
      disconnected_at: new Date().toISOString(),
      disconnect_reason: reason,
      avg_bitrate_kbps: avg(statsSnapshots.map((s) => s.bitrateKbps)),
      avg_framerate: avg(statsSnapshots.map((s) => s.framerate)),
      avg_rtt_ms: avg(statsSnapshots.map((s) => s.rttMs)),
      total_packets_lost: totalPacketsLost,
      total_bytes_received: totalBytes,
    })
    .eq("id", sessionId);

  sessionId = null;
  statsSnapshots = [];
}

export function getSessionId(): string | null {
  return sessionId;
}

export async function logAssistantMessage(
  role: "user" | "assistant" | "system",
  content: string,
  meta?: { source?: string; query?: string; docResultsCount?: number; responseTimeMs?: number }
): Promise<void> {
  if (!sessionId) return;
  const supabase = getSupabase();

  await supabase.from("assistant_logs").insert({
    session_id: sessionId,
    role,
    content: content.slice(0, 5000),
    source: meta?.source ?? null,
    query: meta?.query ?? null,
    doc_results_count: meta?.docResultsCount ?? null,
    response_time_ms: meta?.responseTimeMs ?? null,
  });
}
