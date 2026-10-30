import assert from "node:assert/strict";
import { test } from "node:test";

import {
  configurationReport,
  GooglePlayApiError,
  type GooglePlayCatalogGateway,
  type GoogleSubscription,
  type LocalCatalog,
  verifyGooglePlayCatalog,
} from "./catalog.ts";

const local: LocalCatalog = {
  subscriptions: [
    { kind: "subscription", productId: "small_family", basePlanId: "monthly", expectedPriceMinor: 29900, expectedCurrency: "TRY" },
    { kind: "subscription", productId: "small_family", basePlanId: "annual", expectedPriceMinor: 322920, expectedCurrency: "TRY" },
  ],
  oneTimeProducts: [
    { kind: "one_time", productId: "first_year_book", expectedPriceMinor: 34900, expectedCurrency: "TRY" },
  ],
};

const subscription = (annual = true): GoogleSubscription => ({
  productId: "small_family",
  basePlans: [
    { basePlanId: "monthly", state: "ACTIVE", regionalConfigs: [{ regionCode: "TR", newSubscriberAvailability: true, price: { units: "299", currencyCode: "TRY" } }] },
    ...(annual
      ? [{ basePlanId: "annual", state: "ACTIVE", regionalConfigs: [{ regionCode: "TR", newSubscriberAvailability: true, price: { units: "3229", nanos: 200_000_000, currencyCode: "TRY" } }] }]
      : []),
  ],
});

const oneTime = (priceUnits = "349") => ({
  productId: "first_year_book",
  purchaseOptions: [{
    purchaseOptionId: "buy",
    state: "ACTIVE",
    buyOption: { legacyCompatible: true },
    regionalPricingAndAvailabilityConfigs: [{
      regionCode: "TR",
      availability: "AVAILABLE",
      price: { units: priceUnits, currencyCode: "TRY" },
    }],
  }],
});

const gateway = (overrides: Partial<GooglePlayCatalogGateway> = {}): GooglePlayCatalogGateway => ({
  getSubscription: async () => subscription(),
  getOneTimeProduct: async () => oneTime(),
  ...overrides,
});

test("API bağlantısı yoksa hiçbir ürün doğrulanmış sayılmaz", () => {
  const report = configurationReport("environment_not_configured", new Date("2026-10-25T12:00:00Z"));
  assert.equal(report.connection_status, "not_configured");
  assert.deepEqual(report.results, []);
});

test("başarılı katalog bağlantısı abonelik ve dijital ürünü doğrular", async () => {
  const report = await verifyGooglePlayCatalog(gateway(), local);
  assert.equal(report.connection_status, "success");
  assert.equal(report.results.length, 3);
  assert.ok(report.results.every((item) => item.status === "verified"));
});

test("bulunamayan abonelik ürünü açıkça ayrılır", async () => {
  const report = await verifyGooglePlayCatalog(gateway({ getSubscription: async () => null }), local);
  assert.ok(report.results.filter((item) => item.kind === "subscription").every((item) => item.status === "not_found"));
});

test("eksik yıllık temel plan ürün varlığından ayrı raporlanır", async () => {
  const report = await verifyGooglePlayCatalog(gateway({ getSubscription: async () => subscription(false) }), local);
  const annual = report.results.find((item) => item.base_plan_id === "annual");
  assert.equal(annual?.status, "mismatch");
  assert.equal(annual?.detail_code, "base_plan_missing");
});

test("Türkiye fiyat uyuşmazlığı doğrulama sayılmaz", async () => {
  const report = await verifyGooglePlayCatalog(gateway({ getOneTimeProduct: async () => oneTime("350") }), local);
  const product = report.results.find((item) => item.kind === "one_time");
  assert.equal(product?.status, "mismatch");
  assert.equal(product?.detail_code, "price_mismatch");
});

test("Türkiye'de yeni abonelere kapalı temel plan doğrulanmaz", async () => {
  const unavailable = subscription();
  unavailable.basePlans![0].regionalConfigs![0].newSubscriberAvailability = false;
  const report = await verifyGooglePlayCatalog(gateway({ getSubscription: async () => unavailable }), local);
  const monthly = report.results.find((item) => item.base_plan_id === "monthly");
  assert.equal(monthly?.status, "mismatch");
  assert.equal(monthly?.detail_code, "not_available_in_tr");
});

test("tek seferlik dijital ürünün durum ve Türkiye fiyatı doğrulanır", async () => {
  const report = await verifyGooglePlayCatalog(gateway(), local);
  const product = report.results.find((item) => item.kind === "one_time");
  assert.equal(product?.play_state, "ACTIVE");
  assert.equal(product?.play_price_minor, 34900);
  assert.equal(product?.play_currency, "TRY");
});

test("API yetki hatasında kısmi sonuç doğrulanmış olarak saklanmaz", async () => {
  const report = await verifyGooglePlayCatalog(gateway({
    getSubscription: async () => { throw new GooglePlayApiError("permission_denied", "android_publisher_permission_denied"); },
  }), local);
  assert.equal(report.connection_status, "permission_denied");
  assert.deepEqual(report.results, []);
});

test("geçici API hatası ayrı durum olarak raporlanır", async () => {
  const report = await verifyGooglePlayCatalog(gateway({
    getSubscription: async () => { throw new GooglePlayApiError("unavailable", "android_publisher_rate_limited"); },
  }), local);
  assert.equal(report.connection_status, "unavailable");
  assert.deepEqual(report.results, []);
});
