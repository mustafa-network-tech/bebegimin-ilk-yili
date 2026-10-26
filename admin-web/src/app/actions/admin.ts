"use server";

import { revalidatePath } from "next/cache";

import { requireSuperAdmin } from "@/lib/admin/auth";
import type { PlanRow, ProductRow } from "@/lib/admin/types";
import { checkGooglePlayCatalog } from "@/lib/google-play/client";
import type { LocalCatalog } from "@/lib/google-play/catalog";
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

export async function checkGooglePlayCatalogAction(_: ActionState, _formData: FormData): Promise<ActionState> {
  await requireSuperAdmin();
  const supabase = await createServerSupabase();
  const [{ data: planData, error: planError }, { data: productData, error: productError }] = await Promise.all([
    supabase.rpc("admin_subscription_plans"),
    supabase.rpc("admin_premium_products"),
  ]);
  if (planError || productError) return { error: "Yerel ürün kataloğu okunamadı." };

  const plans = (planData ?? []) as PlanRow[];
  const products = (productData ?? []) as ProductRow[];
  const expectedPlans = [
    ["small_family", "monthly"],
    ["small_family", "annual"],
    ["normal_family", "monthly"],
    ["normal_family", "annual"],
    ["large_family", "monthly"],
    ["large_family", "annual"],
  ] as const;
  const expectedProducts = ["first_year_book", "first_year_html", "first_year_film"] as const;
  const currentPlans = expectedPlans.map(([planCode, period]) =>
    plans.find((item) => item.catalog_active && item.plan_code === planCode && item.billing_period === period));
  const currentProducts = expectedProducts.map((productCode) =>
    products.find((item) => item.catalog_active && item.product_code === productCode));
  if (currentPlans.some((item) => !item) || currentProducts.some((item) => !item)) {
    return { error: "Beklenen yerel katalog satırlarından biri eksik veya pasif." };
  }

  const local: LocalCatalog = {
    subscriptions: currentPlans.map((item) => ({
      kind: "subscription",
      productId: item!.google_product_id ?? "",
      basePlanId: item!.google_base_plan_id ?? "",
      expectedPriceMinor: item!.price_minor,
      expectedCurrency: item!.currency,
    })),
    oneTimeProducts: currentProducts.map((item) => ({
      kind: "one_time",
      productId: item!.google_product_id ?? "",
      expectedPriceMinor: item!.price_minor,
      expectedCurrency: item!.currency,
    })),
  };
  if (local.subscriptions.some((item) => !item.productId || !item.basePlanId)
      || local.oneTimeProducts.some((item) => !item.productId)) {
    return { error: "Yerel Google Play ürün eşlemelerinden biri eksik." };
  }

  const report = await checkGooglePlayCatalog(local);
  const { error } = await supabase.rpc("admin_record_google_play_catalog_check", {
    p_connection_status: report.connection_status,
    p_package_name: report.package_name,
    p_results: report.results,
    p_error_code: report.error_code,
  });
  if (error) return { error: "Google Play kontrol sonucu denetim kaydına yazılamadı." };
  revalidatePath("/abonelik-planlari");
  revalidatePath("/urunler");
  revalidatePath("/denetim");

  return {
    success: report.connection_status === "success"
      ? "Google Play kataloğu kontrol edildi ve sonuçlar denetlendi."
      : report.connection_status === "not_configured"
      ? "Google Play API bağlantısı henüz yapılandırılmadı."
      : report.connection_status === "permission_denied"
      ? "Google Play API hizmet hesabının yetkisi reddedildi."
      : "Google Play API geçici olarak kullanılamıyor.",
  };
}
