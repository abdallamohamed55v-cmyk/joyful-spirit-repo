import { supabase } from "@/integrations/supabase/client";
import { getActiveWorkspaceId, hydrateActiveWorkspaceFromDB } from "@/lib/activeWorkspace";

/**
 * Deduct credits — uses workspace credits when the user has an active workspace
 * and is a member, otherwise falls back to personal credits. Server-side enforced
 * via the `spend_credits_auto` RPC (atomic; no client trust required).
 */
export async function spendCredits(amount: number, actionType: string, description?: string): Promise<
  { success: true; credits: number; source: "workspace" | "personal"; monthly_used?: number }
  | { success: false; error: string; details?: any }
> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: "auth_required" };

  let activeWs = getActiveWorkspaceId();
  if (!activeWs) activeWs = await hydrateActiveWorkspaceFromDB();

  const { data, error } = await supabase.rpc("spend_credits_auto" as any, {
    p_user_id: user.id,
    p_workspace_id: activeWs ?? null,
    p_amount: amount,
    p_action_type: actionType,
    p_description: description ?? null,
  });
  if (error) return { success: false, error: error.message };
  const r = data as any;
  if (!r?.success) return { success: false, error: r?.error || "unknown", details: r };
  return {
    success: true,
    credits: Number(r.credits),
    source: r.source === "workspace" ? "workspace" : "personal",
    monthly_used: r.monthly_used != null ? Number(r.monthly_used) : undefined,
  };
}
