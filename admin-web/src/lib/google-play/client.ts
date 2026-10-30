import "server-only";

import { createSign } from "node:crypto";

import {
  configurationReport,
  EXPECTED_GOOGLE_PLAY_PACKAGE,
  GooglePlayApiError,
  type GoogleOneTimeProduct,
  type GooglePlayCatalogGateway,
  type GooglePlayCatalogReport,
  type GoogleSubscription,
  type LocalCatalog,
  verifyGooglePlayCatalog,
} from "./catalog";

type ServiceAccount = { client_email?: string; private_key?: string };
type Fetch = typeof fetch;

let cachedToken: { clientEmail: string; token: string; expiresAt: number } | null = null;

const base64url = (value: string | Buffer) => Buffer.from(value).toString("base64url");

function parseServiceAccount(raw: string): Required<ServiceAccount> | null {
  try {
    const parsed = JSON.parse(raw) as ServiceAccount;
    if (!parsed.client_email || !parsed.private_key || !parsed.client_email.includes("@")) return null;
    return { client_email: parsed.client_email, private_key: parsed.private_key };
  } catch {
    return null;
  }
}

async function getAccessToken(serviceAccount: Required<ServiceAccount>, request: Fetch): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken?.clientEmail === serviceAccount.client_email && cachedToken.expiresAt > now + 60) {
    return cachedToken.token;
  }
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  let signature: string;
  try {
    signature = createSign("RSA-SHA256").update(`${header}.${claims}`).sign(serviceAccount.private_key).toString("base64url");
  } catch {
    throw new GooglePlayApiError("permission_denied", "service_account_key_invalid");
  }
  let response: Response;
  try {
    response = await request("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: `${header}.${claims}.${signature}`,
      }),
      signal: AbortSignal.timeout(12_000),
    });
  } catch {
    throw new GooglePlayApiError("unavailable", "oauth_temporarily_unavailable");
  }
  if (!response.ok) {
    throw new GooglePlayApiError(
      response.status === 401 || response.status === 403 || response.status === 400 ? "permission_denied" : "unavailable",
      response.status === 401 || response.status === 403 || response.status === 400
        ? "service_account_not_authorized"
        : "oauth_temporarily_unavailable",
    );
  }
  const body = await response.json() as { access_token?: string; expires_in?: number };
  if (!body.access_token) throw new GooglePlayApiError("unavailable", "oauth_response_invalid");
  cachedToken = {
    clientEmail: serviceAccount.client_email,
    token: body.access_token,
    expiresAt: now + (body.expires_in ?? 3600),
  };
  return body.access_token;
}

function apiError(status: number): GooglePlayApiError {
  if (status === 401 || status === 403) return new GooglePlayApiError("permission_denied", "android_publisher_permission_denied");
  if (status === 429) return new GooglePlayApiError("unavailable", "android_publisher_rate_limited");
  return new GooglePlayApiError("unavailable", "android_publisher_unavailable");
}

async function googleGet<T>(path: string, token: string, request: Fetch): Promise<T | null> {
  let response: Response;
  try {
    response = await request(`https://androidpublisher.googleapis.com/androidpublisher/v3${path}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: AbortSignal.timeout(12_000),
    });
  } catch {
    throw new GooglePlayApiError("unavailable", "android_publisher_network_error");
  }
  if (response.status === 404) return null;
  if (!response.ok) throw apiError(response.status);
  try {
    return await response.json() as T;
  } catch {
    throw new GooglePlayApiError("unavailable", "android_publisher_response_invalid");
  }
}

type LegacyInAppProduct = {
  sku?: string;
  status?: string;
  prices?: Record<string, { priceMicros?: string; currency?: string }>;
};

function legacyProduct(value: LegacyInAppProduct): GoogleOneTimeProduct {
  const tr = value.prices?.TR;
  const micros = tr?.priceMicros == null ? null : Number(tr.priceMicros);
  return {
    productId: value.sku,
    purchaseOptions: [{
      purchaseOptionId: "legacy",
      state: value.status === "active" ? "ACTIVE" : "INACTIVE",
      buyOption: { legacyCompatible: true },
      regionalPricingAndAvailabilityConfigs: tr && Number.isSafeInteger(micros)
        ? [{
            regionCode: "TR",
            availability: "AVAILABLE",
            price: {
              currencyCode: tr.currency,
              units: String(Math.trunc(micros! / 1_000_000)),
              nanos: (micros! % 1_000_000) * 1000,
            },
          }]
        : [],
    }],
  };
}

function gateway(packageName: string, token: string, request: Fetch): GooglePlayCatalogGateway {
  const app = `/applications/${encodeURIComponent(packageName)}`;
  return {
    getSubscription: (productId) =>
      googleGet<GoogleSubscription>(`${app}/subscriptions/${encodeURIComponent(productId)}`, token, request),
    getOneTimeProduct: async (productId) => {
      const current = await googleGet<GoogleOneTimeProduct>(
        `${app}/oneTimeProducts/${encodeURIComponent(productId)}`,
        token,
        request,
      );
      if (current) return current;
      const legacy = await googleGet<LegacyInAppProduct>(`${app}/inappproducts/${encodeURIComponent(productId)}`, token, request);
      return legacy ? legacyProduct(legacy) : null;
    },
  };
}

export async function checkGooglePlayCatalog(
  local: LocalCatalog,
  env: NodeJS.ProcessEnv = process.env,
  request: Fetch = fetch,
): Promise<GooglePlayCatalogReport> {
  const packageName = env.GOOGLE_PLAY_PACKAGE_NAME;
  const raw = env.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON;
  if (!packageName || !raw) return configurationReport("environment_not_configured");
  if (packageName !== EXPECTED_GOOGLE_PLAY_PACKAGE) return configurationReport("package_name_mismatch");
  const serviceAccount = parseServiceAccount(raw);
  if (!serviceAccount) return configurationReport("service_account_json_invalid");
  try {
    const token = await getAccessToken(serviceAccount, request);
    return await verifyGooglePlayCatalog(gateway(packageName, token, request), local);
  } catch (error) {
    const known = error instanceof GooglePlayApiError ? error : new GooglePlayApiError("unavailable", "unexpected_api_error");
    return {
      connection_status: known.category,
      package_name: EXPECTED_GOOGLE_PLAY_PACKAGE,
      results: [],
      error_code: known.safeCode,
      checked_at: new Date().toISOString(),
    };
  }
}
