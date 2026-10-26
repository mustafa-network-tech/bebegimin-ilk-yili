export const EXPECTED_GOOGLE_PLAY_PACKAGE = "com.mkdigitalsystems.bebegimin_ilk_yili";

export type GooglePlayConnectionStatus =
  | "success"
  | "not_configured"
  | "permission_denied"
  | "unavailable";

export type GooglePlayItemStatus = "verified" | "not_found" | "mismatch";

export type LocalSubscriptionItem = {
  kind: "subscription";
  productId: string;
  basePlanId: string;
  expectedPriceMinor: number;
  expectedCurrency: string;
};

export type LocalOneTimeItem = {
  kind: "one_time";
  productId: string;
  expectedPriceMinor: number;
  expectedCurrency: string;
};

export type LocalCatalog = {
  subscriptions: LocalSubscriptionItem[];
  oneTimeProducts: LocalOneTimeItem[];
};

export type GoogleMoney = {
  currencyCode?: string;
  units?: string;
  nanos?: number;
};

export type GoogleSubscription = {
  productId?: string;
  basePlans?: Array<{
    basePlanId?: string;
    state?: string;
    regionalConfigs?: Array<{
      regionCode?: string;
      newSubscriberAvailability?: boolean;
      price?: GoogleMoney;
    }>;
  }>;
};

export type GoogleOneTimeProduct = {
  productId?: string;
  purchaseOptions?: Array<{
    purchaseOptionId?: string;
    state?: string;
    buyOption?: { legacyCompatible?: boolean };
    regionalPricingAndAvailabilityConfigs?: Array<{
      regionCode?: string;
      availability?: string;
      price?: GoogleMoney;
    }>;
  }>;
};

export type GooglePlayCatalogItemResult = {
  kind: "subscription" | "one_time";
  product_id: string;
  base_plan_id: string | null;
  status: GooglePlayItemStatus;
  play_state: string | null;
  expected_price_minor: number;
  play_price_minor: number | null;
  expected_currency: string;
  play_currency: string | null;
  detail_code: string | null;
};

export type GooglePlayCatalogReport = {
  connection_status: GooglePlayConnectionStatus;
  package_name: string;
  results: GooglePlayCatalogItemResult[];
  error_code: string | null;
  checked_at: string;
};

export type GooglePlayCatalogGateway = {
  getSubscription(productId: string): Promise<GoogleSubscription | null>;
  getOneTimeProduct(productId: string): Promise<GoogleOneTimeProduct | null>;
};

export class GooglePlayApiError extends Error {
  readonly category: Exclude<GooglePlayConnectionStatus, "success" | "not_configured">;
  readonly safeCode: string;

  constructor(
    category: Exclude<GooglePlayConnectionStatus, "success" | "not_configured">,
    safeCode: string,
  ) {
    super(safeCode);
    this.name = "GooglePlayApiError";
    this.category = category;
    this.safeCode = safeCode;
  }
}

export function configurationReport(errorCode: string, now = new Date()): GooglePlayCatalogReport {
  return {
    connection_status: "not_configured",
    package_name: EXPECTED_GOOGLE_PLAY_PACKAGE,
    results: [],
    error_code: errorCode,
    checked_at: now.toISOString(),
  };
}

function moneyMinor(money: GoogleMoney | undefined): { minor: number; currency: string } | null {
  if (!money?.currencyCode || money.units == null) return null;
  const units = Number(money.units);
  const nanos = money.nanos ?? 0;
  if (!Number.isSafeInteger(units) || !Number.isInteger(nanos) || Math.abs(nanos) >= 1_000_000_000) return null;
  return { minor: Math.round(units * 100 + nanos / 10_000_000), currency: money.currencyCode };
}

function comparison(
  base: Omit<GooglePlayCatalogItemResult, "status" | "detail_code">,
  stateOk: boolean,
  availabilityOk = true,
): GooglePlayCatalogItemResult {
  if (!stateOk) return { ...base, status: "mismatch", detail_code: "catalog_item_inactive" };
  if (!availabilityOk) return { ...base, status: "mismatch", detail_code: "not_available_in_tr" };
  if (base.play_price_minor == null || base.play_currency == null) {
    return { ...base, status: "mismatch", detail_code: "tr_price_missing" };
  }
  if (base.play_currency !== base.expected_currency) {
    return { ...base, status: "mismatch", detail_code: "currency_mismatch" };
  }
  if (base.play_price_minor !== base.expected_price_minor) {
    return { ...base, status: "mismatch", detail_code: "price_mismatch" };
  }
  return { ...base, status: "verified", detail_code: null };
}

function subscriptionResult(
  local: LocalSubscriptionItem,
  remote: GoogleSubscription | null,
): GooglePlayCatalogItemResult {
  const empty = {
    kind: "subscription" as const,
    product_id: local.productId,
    base_plan_id: local.basePlanId,
    play_state: null,
    expected_price_minor: local.expectedPriceMinor,
    play_price_minor: null,
    expected_currency: local.expectedCurrency,
    play_currency: null,
  };
  if (!remote) return { ...empty, status: "not_found", detail_code: "subscription_product_missing" };
  const basePlan = remote.basePlans?.find((item) => item.basePlanId === local.basePlanId);
  if (!basePlan) return { ...empty, status: "mismatch", detail_code: "base_plan_missing" };
  const regional = basePlan.regionalConfigs?.find((item) => item.regionCode === "TR");
  const price = moneyMinor(regional?.price);
  return comparison({
    ...empty,
    play_state: basePlan.state ?? null,
    play_price_minor: price?.minor ?? null,
    play_currency: price?.currency ?? null,
  }, basePlan.state === "ACTIVE", regional?.newSubscriberAvailability === true);
}

function oneTimeResult(local: LocalOneTimeItem, remote: GoogleOneTimeProduct | null): GooglePlayCatalogItemResult {
  const empty = {
    kind: "one_time" as const,
    product_id: local.productId,
    base_plan_id: null,
    play_state: null,
    expected_price_minor: local.expectedPriceMinor,
    play_price_minor: null,
    expected_currency: local.expectedCurrency,
    play_currency: null,
  };
  if (!remote) return { ...empty, status: "not_found", detail_code: "one_time_product_missing" };
  const buyOptions = remote.purchaseOptions?.filter((item) => item.buyOption) ?? [];
  const option = buyOptions.find((item) => item.buyOption?.legacyCompatible) ?? buyOptions[0];
  if (!option) return { ...empty, status: "mismatch", detail_code: "buy_option_missing" };
  const regional = option.regionalPricingAndAvailabilityConfigs?.find((item) => item.regionCode === "TR");
  const price = moneyMinor(regional?.price);
  return comparison({
    ...empty,
    play_state: option.state ?? null,
    play_price_minor: price?.minor ?? null,
    play_currency: price?.currency ?? null,
  }, option.state === "ACTIVE", regional?.availability === "AVAILABLE");
}

export async function verifyGooglePlayCatalog(
  gateway: GooglePlayCatalogGateway,
  local: LocalCatalog,
  now = new Date(),
): Promise<GooglePlayCatalogReport> {
  try {
    const subscriptionIds = [...new Set(local.subscriptions.map((item) => item.productId))];
    const [subscriptions, products] = await Promise.all([
      Promise.all(subscriptionIds.map(async (id) => [id, await gateway.getSubscription(id)] as const)),
      Promise.all(local.oneTimeProducts.map(async (item) => [item.productId, await gateway.getOneTimeProduct(item.productId)] as const)),
    ]);
    const subscriptionMap = new Map(subscriptions);
    const productMap = new Map(products);
    return {
      connection_status: "success",
      package_name: EXPECTED_GOOGLE_PLAY_PACKAGE,
      results: [
        ...local.subscriptions.map((item) => subscriptionResult(item, subscriptionMap.get(item.productId) ?? null)),
        ...local.oneTimeProducts.map((item) => oneTimeResult(item, productMap.get(item.productId) ?? null)),
      ],
      error_code: null,
      checked_at: now.toISOString(),
    };
  } catch (error) {
    const known = error instanceof GooglePlayApiError ? error : new GooglePlayApiError("unavailable", "unexpected_api_error");
    return {
      connection_status: known.category,
      package_name: EXPECTED_GOOGLE_PLAY_PACKAGE,
      results: [],
      error_code: known.safeCode,
      checked_at: now.toISOString(),
    };
  }
}
