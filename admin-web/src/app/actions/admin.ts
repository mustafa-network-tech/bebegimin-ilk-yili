"use server";

import { revalidatePath } from "next/cache";

import { requireSuperAdmin } from "@/lib/admin/auth";
import { createServerSupabase } from "@/lib/supabase/server";

export type ActionState = { error?: string; success?: string };

export async function decideExtensionAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const requestId = String(formData.get("request_id") ?? "");
  const decision = String(formData.get("decision") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  if (!requestId || !["approved", "rejected"].includes(decision)) return { error: "Geçersiz karar isteği." };
  if (decision === "rejected" && !note) return { error: "Reddetme işlemi için karar notu zorunludur." };

  const supabase = await createServerSupabase();
  const { data, error } = await supabase.rpc("admin_decide_extension", {
    p_request_id: requestId,
    p_decision: decision,
    p_note: note || null,
  });
  if (error) return { error: error.message };
  revalidatePath("/uzatmalar");
  return { success: data === "expired" ? "Talebin süresi dolmuş; karar uygulanmadı." : "Karar kaydedildi ve denetlendi." };
}

export async function correctBirthDateAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const babyId = String(formData.get("baby_id") ?? "");
  const birthDate = String(formData.get("birth_date") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  const confirmReopen = formData.get("confirm_reopen") === "on";
  if (!babyId || !/^\d{4}-\d{2}-\d{2}$/.test(birthDate)) return { error: "Bebek ve geçerli tarih zorunludur." };
  if (!reason) return { error: "Düzeltme gerekçesi zorunludur." };

  const supabase = await createServerSupabase();
  const { error } = await supabase.rpc("admin_correct_birth_date", {
    p_baby_id: babyId,
    p_birth_date: birthDate,
    p_reason: reason,
    p_confirm_reopen: confirmReopen,
  });
  if (error) return { error: error.message };
  revalidatePath("/dogum-tarihi");
  revalidatePath("/denetim");
  return { success: "Doğum tarihi düzeltildi ve denetim kaydı oluşturuldu." };
}
