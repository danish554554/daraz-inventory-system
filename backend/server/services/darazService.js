const crypto = require("crypto");
const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const StoreConnectionConfig = require("../models/StoreConnectionConfig");
const { getOrders } = require("./darazApiService");

function safeString(value) {
  return (value || "").toString().trim();
}

function toDateOrNull(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function toBoolean(value, fallback = false) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "1", "yes", "on"].includes(normalized)) return true;
    if (["false", "0", "no", "off"].includes(normalized)) return false;
  }
  return fallback;
}

function getRequiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required in .env`);
  }
  return value;
}

function getClientAppUrl() {
  return safeString(process.env.CLIENT_APP_URL || "http://localhost:3000/stores");
}

function normalizeClientRedirectUri(value) {
  const input = safeString(value);
  if (!input) return "";

  try {
    const url = new URL(input);
    const blockedProtocols = ["javascript:", "data:", "file:"];
    if (blockedProtocols.includes(url.protocol)) {
      throw new Error("Unsupported client redirect URI protocol");
    }
    return url.toString();
  } catch (error) {
    throw new Error("Invalid client redirect URI");
  }
}

function getOauthRedirectUri() {
  return safeString(
    process.env.DARAZ_OAUTH_REDIRECT_URI || "http://localhost:5000/api/stores/oauth/callback"
  );
}

function getForceAuthValue() {
  return safeString(process.env.DARAZ_OAUTH_FORCE_AUTH || "true");
}

function isLiveApiEnabled() {
  return String(process.env.DARAZ_ENABLE_LIVE_API || "false").toLowerCase() === "true";
}

function getPreemptiveRefreshMinutes() {
  const value = Number(process.env.DARAZ_PREEMPTIVE_REFRESH_MINUTES || 30);
  if (!Number.isFinite(value) || value < 1) return 30;
  return value;
}

function maskToken(token) {
  const value = safeString(token);
  if (!value) return "";
  if (value.length <= 10) return `${value.slice(0, 2)}***${value.slice(-2)}`;
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function countryToAuthorizeBase(country = "") {
  const code = safeString(country).toUpperCase();

  const map = {
    PK: "https://api.daraz.pk",
    BD: "https://api.daraz.com.bd",
    LK: "https://api.daraz.lk",
    NP: "https://api.daraz.com.np",
    MM: "https://api.shop.com.mm"
  };

  return map[code] || "https://api.daraz.pk";
}

function countryToApiBase(country = "") {
  const code = safeString(country).toUpperCase();

  const map = {
    PK: "https://api.daraz.pk/rest",
    BD: "https://api.daraz.com.bd/rest",
    LK: "https://api.daraz.lk/rest",
    NP: "https://api.daraz.com.np/rest",
    MM: "https://api.shop.com.mm/rest"
  };

  return map[code] || "https://api.daraz.pk/rest";
}

function getExpiryState(expiresAt) {
  if (!expiresAt) {
    return {
      status: "active",
      expires_in_minutes: null,
      is_expired: false,
      is_expiring_soon: false
    };
  }

  const expiryDate = new Date(expiresAt);
  const diffMs = expiryDate.getTime() - Date.now();
  const diffMinutes = Math.floor(diffMs / (1000 * 60));
  const refreshSoonMinutes = getPreemptiveRefreshMinutes();

  if (diffMs <= 0) {
    return {
      status: "expired",
      expires_in_minutes: 0,
      is_expired: true,
      is_expiring_soon: false
    };
  }

  if (diffMinutes <= refreshSoonMinutes) {
    return {
      status: "expiring_soon",
      expires_in_minutes: diffMinutes,
      is_expired: false,
      is_expiring_soon: true
    };
  }

  return {
    status: "active",
    expires_in_minutes: diffMinutes,
    is_expired: false,
    is_expiring_soon: false
  };
}

function buildTokenSummary(token) {
  if (!token) {
    return {
      token_connected: false,
      token_status: "not_connected",
      token_source: null,
      access_token_preview: "",
      refresh_token_preview: "",
      seller_id: "",
      user_id: "",
      account: "",
      country_code: "",
      api_base_url: "",
      expires_at: null,
      refresh_expires_at: null,
      expires_in_minutes: null,
      is_expired: false,
      is_expiring_soon: false,
      last_sync_at: null,
      last_validated_at: null,
      last_refreshed_at: null,
      last_error: ""
    };
  }

  const expiry = getExpiryState(token.expires_at);
  const effectiveStatus =
    token.token_status === "invalid"
      ? "invalid"
      : expiry.status === "expired"
      ? "expired"
      : expiry.status === "expiring_soon"
      ? "expiring_soon"
      : token.token_status || "active";

  return {
    token_connected: true,
    token_status: effectiveStatus,
    token_source: token.token_source || "manual",
    access_token_preview: maskToken(token.access_token),
    refresh_token_preview: maskToken(token.refresh_token),
    seller_id: token.seller_id || "",
    user_id: token.user_id || "",
    account: token.account || "",
    country_code: token.country_code || "",
    api_base_url: token.api_base_url || "",
    expires_at: token.expires_at || null,
    refresh_expires_at: token.refresh_expires_at || null,
    expires_in_minutes: expiry.expires_in_minutes,
    is_expired: expiry.is_expired,
    is_expiring_soon: expiry.is_expiring_soon,
    last_sync_at: token.last_sync_at || null,
    last_validated_at: token.last_validated_at || null,
    last_refreshed_at: token.last_refreshed_at || null,
    last_error: token.last_error || ""
  };
}

function base64UrlEncode(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function base64UrlDecode(input) {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padding = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  return Buffer.from(normalized + padding, "base64").toString("utf8");
}

function signState(payloadString) {
  const secret = getRequiredEnv("DARAZ_APP_SECRET");
  return crypto
    .createHmac("sha256", secret)
    .update(payloadString, "utf8")
    .digest("hex");
}

function createSignedState(payload) {
  const payloadString = JSON.stringify(payload);
  const encodedPayload = base64UrlEncode(payloadString);
  const signature = signState(encodedPayload);
  return `${encodedPayload}.${signature}`;
}

function verifySignedState(state) {
  const value = safeString(state);
  const [encodedPayload, signature] = value.split(".");

  if (!encodedPayload || !signature) {
    throw new Error("Invalid OAuth state");
  }

  const expectedSignature = signState(encodedPayload);

  if (signature !== expectedSignature) {
    throw new Error("OAuth state signature mismatch");
  }

  const json = base64UrlDecode(encodedPayload);
  const payload = JSON.parse(json);

  if (!payload?.store_id) {
    throw new Error("OAuth state missing store_id");
  }

  if (!payload?.ts) {
    throw new Error("OAuth state missing timestamp");
  }

  const ageMs = Date.now() - Number(payload.ts);
  if (!Number.isFinite(ageMs) || ageMs < 0 || ageMs > 30 * 60 * 1000) {
    throw new Error("OAuth state expired");
  }

  return payload;
}

function buildFrontendRedirectUrl(params = {}, clientRedirectUri = "") {
  const hasCustomRedirect = Boolean(safeString(clientRedirectUri));
  const target = normalizeClientRedirectUri(clientRedirectUri || getClientAppUrl());
  const url = new URL(target);

  if (!hasCustomRedirect && (!url.pathname || url.pathname === "/")) {
    url.pathname = "/stores";
  }

  Object.keys(params).forEach((key) => {
    const value = params[key];
    if (value !== undefined && value !== null && value !== "") {
      url.searchParams.set(key, String(value));
    }
  });

  return url.toString();
}

function pickCountryUserInfo(tokenPayload, storeCountry) {
  const countryInfoList = Array.isArray(tokenPayload?.country_user_info)
    ? tokenPayload.country_user_info
    : [];

  if (!countryInfoList.length) {
    return null;
  }

  const normalizedStoreCountry = safeString(storeCountry).toLowerCase();
  const normalizedTokenCountry = safeString(tokenPayload.country).toLowerCase();

  if (normalizedTokenCountry && normalizedTokenCountry !== "cb") {
    const exact = countryInfoList.find(
      (item) => safeString(item?.country).toLowerCase() === normalizedTokenCountry
    );
    if (exact) return exact;
  }

  if (normalizedStoreCountry) {
    const exact = countryInfoList.find(
      (item) => safeString(item?.country).toLowerCase() === normalizedStoreCountry
    );
    if (exact) return exact;
  }

  return countryInfoList[0] || null;
}

function convertSecondsToDate(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return null;
  return new Date(Date.now() + value * 1000);
}

function normalizeTokenPayload(tokenPayload, store) {
  const matchedUserInfo = pickCountryUserInfo(tokenPayload, store.country);

  const countryCode =
    safeString(tokenPayload.country) ||
    safeString(matchedUserInfo?.country) ||
    safeString(store.country).toLowerCase();

  return {
    access_token: safeString(tokenPayload.access_token),
    refresh_token: safeString(tokenPayload.refresh_token),
    seller_id: safeString(matchedUserInfo?.seller_id || tokenPayload.seller_id),
    user_id: safeString(matchedUserInfo?.user_id || tokenPayload.user_id),
    account: safeString(tokenPayload.account),
    country_code: countryCode.toUpperCase(),
    api_base_url: countryToApiBase(countryCode || store.country),
    expires_at: convertSecondsToDate(tokenPayload.expires_in),
    refresh_expires_at: convertSecondsToDate(tokenPayload.refresh_expires_in)
  };
}

async function callDarazAuthApi(path, params = {}, country = "PK") {
  const appKey = getRequiredEnv("DARAZ_APP_KEY");
  const appSecret = getRequiredEnv("DARAZ_APP_SECRET");
  const baseUrl = countryToApiBase(country);
  const url = new URL(baseUrl + path);

  const finalParams = {
    app_key: appKey,
    sign_method: "sha256",
    timestamp: Date.now(),
    ...params
  };

  const signBase = path + Object.keys(finalParams)
    .sort()
    .map((key) => `${key}${finalParams[key]}`)
    .join("");

  const sign = crypto
    .createHmac("sha256", appSecret)
    .update(signBase, "utf8")
    .digest("hex")
    .toUpperCase();

  Object.keys(finalParams).forEach((key) => {
    if (finalParams[key] !== undefined && finalParams[key] !== null && finalParams[key] !== "") {
      url.searchParams.append(key, String(finalParams[key]));
    }
  });

  url.searchParams.append("sign", sign);

  console.log(`[Daraz Auth API] Calling ${baseUrl}${path} for country=${country}`);

  const response = await fetch(url.toString(), {
    method: "GET",
    headers: {
      Accept: "application/json"
    }
  });

  const text = await response.text();

  let json;
  try {
    json = JSON.parse(text);
  } catch (error) {
    console.error("[Daraz Auth API] Invalid JSON response:", text);
    throw new Error(`Daraz auth API returned invalid JSON: ${text}`);
  }

  const apiCode = String(json?.code ?? "");
  const apiMessage = safeString(json?.message || json?.msg);

  console.log("[Daraz Auth API] Response summary:", {
    httpStatus: response.status,
    code: apiCode,
    message: apiMessage,
    hasData: Boolean(json?.data),
    hasRootAccessToken: Boolean(json?.access_token),
    hasDataAccessToken: Boolean(json?.data?.access_token)
  });

  if (!response.ok || apiCode !== "0") {
    const error = new Error(apiMessage || `Daraz auth API error (${response.status})`);
    error.apiCode = apiCode;
    error.apiMessage = apiMessage;
    error.httpStatus = response.status;
    error.isTokenError = true;
    throw error;
  }

  // Daraz/Lazada auth endpoints commonly return token fields at the root level:
  // { code: "0", access_token: "...", refresh_token: "..." }
  // Some responses may wrap them in data. Support both shapes.
  return json?.data || json || {};
}

async function persistTokenFromPayload({
  store,
  tokenPayload,
  tokenSource = "oauth"
}) {
  const normalized = normalizeTokenPayload(tokenPayload, store);

  console.log("[Daraz OAuth] Token payload summary:", {
    store_id: String(store._id),
    store_name: store.name,
    has_access_token: Boolean(normalized.access_token),
    has_refresh_token: Boolean(normalized.refresh_token),
    account: normalized.account,
    seller_id: normalized.seller_id,
    country_code: normalized.country_code,
    expires_at: normalized.expires_at,
    refresh_expires_at: normalized.refresh_expires_at
  });

  if (!normalized.access_token) {
    throw new Error("Daraz token response missing access_token");
  }

  const expiryState = getExpiryState(normalized.expires_at);

  const updateDoc = {
    store_id: store._id,
    access_token: normalized.access_token,
    refresh_token: normalized.refresh_token,
    seller_id: normalized.seller_id,
    user_id: normalized.user_id,
    account: normalized.account,
    country_code: normalized.country_code,
    api_base_url: normalized.api_base_url,
    expires_at: normalized.expires_at,
    refresh_expires_at: normalized.refresh_expires_at,
    token_status: expiryState.status === "expired" ? "expired" : expiryState.status,
    token_source: tokenSource,
    last_validated_at: new Date(),
    last_error: ""
  };

  if (tokenSource === "refreshed") {
    updateDoc.last_refreshed_at = new Date();
  }

  const token = await StoreToken.findOneAndUpdate(
    { store_id: store._id },
    updateDoc,
    {
      returnDocument: "after",
      upsert: true,
      setDefaultsOnInsert: true
    }
  );

  await StoreConnectionConfig.findOneAndUpdate(
    { store_id: store._id },
    {
      store_id: store._id,
      app_key: getRequiredEnv("DARAZ_APP_KEY"),
      app_secret: getRequiredEnv("DARAZ_APP_SECRET"),
      redirect_uri: getOauthRedirectUri(),
      api_region: safeString(normalized.country_code || store.country).toLowerCase(),
      seller_account_name: safeString(normalized.account),
      auth_status: expiryState.status === "expired" ? "token_expired" : "token_active",
      last_connected_at: new Date(),
      last_validated_at: new Date(),
      last_error_message: ""
    },
    {
      upsert: true,
      returnDocument: "after",
      setDefaultsOnInsert: true
    }
  );

  console.log("[Daraz OAuth] Token saved successfully:", {
    store_id: String(store._id),
    store_name: store.name,
    token_id: String(token._id),
    token_status: token.token_status,
    token_source: token.token_source
  });

  return {
    token,
    token_summary: buildTokenSummary(token)
  };
}

async function saveStoreTokenConnection(storeId, payload = {}) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const accessToken = safeString(payload.access_token);
  if (!accessToken) {
    throw new Error("access_token is required");
  }

  const refreshToken = safeString(payload.refresh_token);
  const expiresAt = toDateOrNull(payload.expires_at);
  const refreshExpiresAt = toDateOrNull(payload.refresh_expires_at);
  const expiryState = getExpiryState(expiresAt);

  const token = await StoreToken.findOneAndUpdate(
    { store_id: store._id },
    {
      store_id: store._id,
      access_token: accessToken,
      refresh_token: refreshToken,
      seller_id: safeString(payload.seller_id),
      user_id: safeString(payload.user_id),
      account: safeString(payload.account),
      country_code: safeString(payload.country_code || store.country).toUpperCase(),
      api_base_url: safeString(payload.api_base_url) || countryToApiBase(store.country),
      expires_at: expiresAt,
      refresh_expires_at: refreshExpiresAt,
      token_status: expiryState.status === "expired" ? "expired" : expiryState.status,
      token_source: safeString(payload.token_source) || "manual",
      last_error: ""
    },
    {
      returnDocument: "after",
      upsert: true,
      setDefaultsOnInsert: true
    }
  );

  return {
    store,
    token,
    token_summary: buildTokenSummary(token)
  };
}

async function validateStoreToken(storeId) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const token = await StoreToken.findOne({ store_id: store._id });

  if (!token) {
    throw new Error("Store token not found");
  }

  const expiryState = getExpiryState(token.expires_at);

  if (expiryState.is_expired) {
    token.token_status = "expired";
    token.last_validated_at = new Date();
    token.last_error = "Token is expired based on expires_at";
    await token.save();

    return {
      ok: false,
      message: "Token is expired",
      store,
      token,
      token_summary: buildTokenSummary(token)
    };
  }

  if (!isLiveApiEnabled()) {
    token.token_status = expiryState.is_expiring_soon ? "expiring_soon" : "active";
    token.last_validated_at = new Date();
    token.last_error = "";
    await token.save();

    return {
      ok: true,
      message: "Token format/status checked locally. Live API validation is disabled.",
      store,
      token,
      token_summary: buildTokenSummary(token)
    };
  }

  try {
    const updatedAfter = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    await getOrders({
      storeToken: token,
      updatedAfter,
      offset: 0,
      limit: 1
    });

    token.token_status = expiryState.is_expiring_soon ? "expiring_soon" : "active";
    token.last_validated_at = new Date();
    token.last_error = "";
    await token.save();

    return {
      ok: true,
      message: "Token validated successfully",
      store,
      token,
      token_summary: buildTokenSummary(token)
    };
  } catch (error) {
    token.last_validated_at = new Date();
    token.last_error = safeString(error.message);
    token.token_status = error.isTokenError
      ? "invalid"
      : expiryState.is_expiring_soon
      ? "expiring_soon"
      : "active";

    await token.save();

    return {
      ok: false,
      message: error.isTokenError
        ? "Token is invalid or expired on Daraz"
        : `Validation failed: ${error.message}`,
      store,
      token,
      token_summary: buildTokenSummary(token)
    };
  }
}

async function disconnectStoreToken(storeId) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const existing = await StoreToken.findOne({ store_id: store._id });

  if (!existing) {
    return {
      ok: true,
      message: "Store token already disconnected",
      store
    };
  }

  await StoreToken.deleteOne({ store_id: store._id });

  return {
    ok: true,
    message: "Store token disconnected successfully",
    store
  };
}

async function getStoresWithTokenState() {
  const stores = await Store.find().sort({ createdAt: -1 });
  const storeIds = stores.map((item) => item._id);

  const tokens = await StoreToken.find({
    store_id: { $in: storeIds }
  });

  const tokenMap = {};
  for (const token of tokens) {
    tokenMap[token.store_id.toString()] = token;
  }

  return stores.map((store) => {
    const token = tokenMap[store._id.toString()] || null;

    return {
      ...store.toObject(),
      ...buildTokenSummary(token)
    };
  });
}

async function createOauthConnectUrl(storeId, options = {}) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const appKey = getRequiredEnv("DARAZ_APP_KEY");
  const appSecret = getRequiredEnv("DARAZ_APP_SECRET");
  const redirectUri = getOauthRedirectUri();
  const authorizeBase = countryToAuthorizeBase(store.country);
  const clientRedirectUri = options.clientRedirectUri
    ? normalizeClientRedirectUri(options.clientRedirectUri)
    : "";
  const forceAuth = safeString(options.forceAuth || getForceAuthValue());
  const state = createSignedState({
    store_id: String(store._id),
    client_redirect_uri: clientRedirectUri,
    ts: Date.now()
  });

  await StoreConnectionConfig.findOneAndUpdate(
    { store_id: store._id },
    {
      store_id: store._id,
      app_key: appKey,
      app_secret: appSecret,
      redirect_uri: redirectUri,
      api_region: safeString(store.country).toLowerCase(),
      auth_state: state,
      auth_status: "auth_url_generated",
      auth_url_last_generated_at: new Date(),
      last_error_message: ""
    },
    {
      upsert: true,
      returnDocument: "after",
      setDefaultsOnInsert: true
    }
  );

  const url = new URL("/oauth/authorize", authorizeBase);

  url.searchParams.set("response_type", "code");
  url.searchParams.set("force_auth", forceAuth || getForceAuthValue());
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("client_id", appKey);
  url.searchParams.set("state", state);

  if (safeString(store.country)) {
    url.searchParams.set("country", safeString(store.country).toLowerCase());
  }

  return {
    store,
    authorize_url: url.toString()
  };
}

async function exchangeCodeForStoreToken({ storeId, code }) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const tokenPayload = await callDarazAuthApi(
    "/auth/token/create",
    {
      code: safeString(code)
    },
    store.country
  );

  const result = await persistTokenFromPayload({
    store,
    tokenPayload,
    tokenSource: "oauth"
  });

  return {
    store,
    token: result.token,
    token_summary: result.token_summary
  };
}

async function handleOauthCallback({ code, state, error, error_description }) {
  let statePayload = null;
  let clientRedirectUri = "";

  if (safeString(state)) {
    try {
      statePayload = verifySignedState(state);
      clientRedirectUri = safeString(statePayload.client_redirect_uri);
    } catch (stateError) {
      return {
        ok: false,
        redirect_url: buildFrontendRedirectUrl({
          oauth: "error",
          message: stateError.message
        })
      };
    }
  }

  if (safeString(error)) {
    return {
      ok: false,
      redirect_url: buildFrontendRedirectUrl({
        oauth: "error",
        message: error_description || error
      }, clientRedirectUri)
    };
  }

  if (!safeString(code)) {
    return {
      ok: false,
      redirect_url: buildFrontendRedirectUrl({
        oauth: "error",
        message: "Missing authorization code"
      }, clientRedirectUri)
    };
  }

  if (!statePayload) {
    return {
      ok: false,
      redirect_url: buildFrontendRedirectUrl({
        oauth: "error",
        message: "Invalid OAuth state"
      })
    };
  }

  try {
    console.log("[Daraz OAuth] Exchanging code for token:", {
      store_id: statePayload.store_id,
      has_code: Boolean(safeString(code))
    });

    const result = await exchangeCodeForStoreToken({
      storeId: statePayload.store_id,
      code
    });

    console.log("[Daraz OAuth] Store connected successfully:", {
      store_id: String(result.store._id),
      store_name: result.store.name
    });

    return {
      ok: true,
      redirect_url: buildFrontendRedirectUrl({
        oauth: "success",
        store_id: result.store._id,
        store_name: result.store.name
      }, clientRedirectUri),
      store: result.store,
      token_summary: result.token_summary
    };
  } catch (exchangeError) {
    console.error("[Daraz OAuth] Token exchange/save failed:", {
      message: exchangeError.message,
      apiCode: exchangeError.apiCode,
      apiMessage: exchangeError.apiMessage,
      httpStatus: exchangeError.httpStatus
    });

    return {
      ok: false,
      redirect_url: buildFrontendRedirectUrl({
        oauth: "error",
        message: exchangeError.message
      }, clientRedirectUri)
    };
  }
}

async function refreshStoreAccessToken(storeId) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const token = await StoreToken.findOne({ store_id: store._id });

  if (!token) {
    throw new Error("Store token not found");
  }

  if (!safeString(token.refresh_token)) {
    throw new Error("Refresh token is missing");
  }

  const refreshExpiry = getExpiryState(token.refresh_expires_at);
  if (refreshExpiry.is_expired) {
    token.token_status = "invalid";
    token.last_error = "Refresh token is expired";
    await token.save();
    throw new Error("Refresh token is expired. Reconnect the store.");
  }

  if (!isLiveApiEnabled()) {
    const simulatedExpiry = new Date(Date.now() + 2 * 60 * 60 * 1000);
    token.expires_at = simulatedExpiry;
    token.token_status = "active";
    token.token_source = token.token_source || "manual";
    token.last_refreshed_at = new Date();
    token.last_error = "";
    await token.save();

    return {
      ok: true,
      message: "Live API disabled. Token refresh was simulated locally.",
      store,
      token,
      token_summary: buildTokenSummary(token)
    };
  }

  const tokenPayload = await callDarazAuthApi(
    "/auth/token/refresh",
    {
      refresh_token: token.refresh_token
    },
    store.country
  );

  const result = await persistTokenFromPayload({
    store,
    tokenPayload,
    tokenSource: "refreshed"
  });

  return {
    ok: true,
    message: "Access token refreshed successfully",
    store,
    token: result.token,
    token_summary: result.token_summary
  };
}

async function ensureStoreTokenReadyForSync(storeId) {
  const store = await Store.findById(storeId);

  if (!store) {
    throw new Error("Store not found");
  }

  const token = await StoreToken.findOne({ store_id: store._id });

  if (!token || !safeString(token.access_token)) {
    return {
      ok: false,
      skipped: true,
      reason: "not_connected",
      message: "Store is not connected"
    };
  }

  const expiry = getExpiryState(token.expires_at);

  if (!expiry.is_expired && !expiry.is_expiring_soon) {
    if (token.token_status !== "active") {
      token.token_status = "active";
      token.last_error = "";
      await token.save();
    }

    return {
      ok: true,
      refreshed: false,
      token,
      message: "Token is ready"
    };
  }

  if (!safeString(token.refresh_token)) {
    token.token_status = expiry.is_expired ? "expired" : "expiring_soon";
    token.last_error = expiry.is_expired
      ? "Access token expired and no refresh token available"
      : "Access token expiring soon and no refresh token available";
    await token.save();

    return {
      ok: false,
      skipped: true,
      reason: "refresh_token_missing",
      message: token.last_error
    };
  }

  try {
    const refreshResult = await refreshStoreAccessToken(store._id);

    return {
      ok: true,
      refreshed: true,
      token: refreshResult.token,
      message: refreshResult.message
    };
  } catch (error) {
    return {
      ok: false,
      skipped: true,
      reason: "refresh_failed",
      message: error.message
    };
  }
}

module.exports = {
  toBoolean,
  buildTokenSummary,
  saveStoreTokenConnection,
  validateStoreToken,
  disconnectStoreToken,
  getStoresWithTokenState,
  createOauthConnectUrl,
  handleOauthCallback,
  refreshStoreAccessToken,
  ensureStoreTokenReadyForSync,
  isLiveApiEnabled
};