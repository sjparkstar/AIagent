import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const SUPABASE_URL = "https://xrvbktzsxtgadrcwhxkl.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_aL9Oh6wdJEdE_xO8lC3hHA_yx-ac2YQ";

let client: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient {
  if (!client) {
    client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
  return client;
}
