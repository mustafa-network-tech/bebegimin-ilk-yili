"use server";

import { revalidatePath } from "next/cache";

import type { ActionState } from "@/app/actions/admin";
import { requireSuperAdmin } from "@/lib/admin/auth";
import { createServerSupabase } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Safe, fixed messages: database error text is never shown as is for the known cases.
const TRIAL_ERRORS: Record<string, string> = {
  trial_already_active: "Bu kullanıcının zaten süren bir denemesi var.",
  trial_already_used: "Bu kullanıcı daha önce deneme almış. Yeniden vermek için ‘bilinçli yenileme’ kutusunu işaretleyin.",
  subscription_active: "Kullanıcının ailesinde zaten aktif bir abonelik var.",
  test_access_included: "Kullanıcının süresiz test erişimi var; deneme gerekmiyor.",
};

function failure(error: { message: string; hint?: string | null }): ActionState {
  return { error: (error.hint && TRIAL_ERRORS[error.hint]) || error.message };
}

export async function grantTrialAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const userId = String(formData.get("user_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  const repeat = formData.get("allow_repeat") === "on";
  if (!UUID.test(userId)) return { error: "Geçerli bir kullanıcı UUID'si zorunludur." };
  if (reason.length < 3 || reason.length > 500) return { error: "Gerekçe 3–500 karakter olmalıdır." };

  const supabase = await createServerSupabase();
  const { error } = await supabase.rpc("admin_grant_trial", {
    p_user_id: userId,
    p_reason: reason,
    p_allow_repeat: repeat,
  });
  if (error) return failure(error);
  revalidatePath(`/kullanicilar/${userId}`);
  revalidatePath("/yeni-kayitlar");
  return { success: "72 saatlik deneme tanımlandı ve denetim kaydına yazıldı." };
}

export async function revokeTrialAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const userId = String(formData.get("user_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!UUID.test(userId)) return { error: "Geçerli bir kullanıcı UUID'si zorunludur." };
  if (reason.length < 3 || reason.length > 500) return { error: "Gerekçe 3–500 karakter olmalıdır." };

  const supabase = await createServerSupabase();
  const { data, error } = await supabase.rpc("admin_revoke_trial", { p_user_id: userId, p_reason: reason });
  if (error) return failure(error);
  revalidatePath(`/kullanicilar/${userId}`);
  revalidatePath("/yeni-kayitlar");
  return { success: data === "revoked" ? "Deneme sonlandırıldı ve denetlendi." : "Sürmekte olan bir deneme yoktu." };
}

export async function markEmailSentAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const userId = String(formData.get("user_id") ?? "");
  const template = String(formData.get("template") ?? "");
  const trialId = String(formData.get("trial_id") ?? "");
  if (!UUID.test(userId)) return { error: "Geçerli bir kullanıcı UUID'si zorunludur." };
  if (!["welcome", "trial_activated"].includes(template)) return { error: "Geçersiz şablon." };
  if (template === "trial_activated" && !UUID.test(trialId)) return { error: "Deneme kaydı bulunamadı." };

  const supabase = await createServerSupabase();
  const { data, error } = await supabase.rpc("admin_mark_email_sent", {
    p_user_id: userId,
    p_template: template,
    p_trial_id: template === "trial_activated" ? trialId : null,
  });
  if (error) return failure(error);
  revalidatePath("/yeni-kayitlar");
  revalidatePath(`/kullanicilar/${userId}`);
  return { success: data === "marked" ? "Gönderildi olarak işaretlendi." : "Bu e-posta zaten işaretlenmişti." };
}

export async function saveEmailTemplateAction(_: ActionState, formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const kind = String(formData.get("kind") ?? "");
  const subject = String(formData.get("subject") ?? "");
  const body = String(formData.get("body") ?? "");
  if (!["welcome", "trial_activated"].includes(kind)) return { error: "Geçersiz şablon." };
  if (subject.length > 200) return { error: "Konu en fazla 200 karakter olabilir." };
  if (body.length > 10000) return { error: "Metin en fazla 10.000 karakter olabilir." };

  const supabase = await createServerSupabase();
  const { data, error } = await supabase.rpc("admin_save_email_template", {
    p_kind: kind,
    p_subject: subject,
    p_body: body,
  });
  if (error) {
    return {
      error: error.message.includes("unknown placeholder")
        ? "Bilinmeyen yer tutucu var. Yalnızca {{ad}} ve {{deneme_bitis}} kullanılabilir."
        : error.message,
    };
  }
  revalidatePath("/e-posta-sablonlari");
  revalidatePath("/yeni-kayitlar");
  return { success: `Şablon kaydedildi (sürüm ${data}).` };
}
