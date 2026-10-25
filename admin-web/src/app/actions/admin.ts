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

export async function setTestAccessAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const userId = String(formData.get("user_id") ?? "");
  const enabled = String(formData.get("enabled") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    return { error: "Geçerli bir kullanıcı UUID'si zorunludur." };
  }
  if (!['true', 'false'].includes(enabled)) return { error: "Geçersiz erişim işlemi." };
  if (reason.length < 3 || reason.length > 500) return { error: "Gerekçe 3–500 karakter olmalıdır." };

  const supabase = await createServerSupabase();
  const { data, error } = await supabase.rpc("admin_set_test_access", {
    p_user_id: userId,
    p_enabled: enabled === "true",
    p_reason: reason,
  });
  if (error) return { error: error.message };
  revalidatePath("/test-erisimleri");
  const result = data as string;
  return {
    success: result === "granted"
      ? "Sınırsız test erişimi verildi ve denetlendi."
      : result === "revoked"
      ? "Test erişimi iptal edildi ve denetlendi."
      : "Erişim durumu zaten seçilen değerdeydi.",
  };
}
