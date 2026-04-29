const crypto = require("crypto");

function getRequiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required in .env`);
  }
  return value;
}

function getBaseUrl(storeToken = null) {
  if (storeToken?.api_base_url) {
    return storeToken.api_base_url.trim();
  }

  return process.env.DARAZ_API_BASE_URL || "https://api.daraz.pk/rest";
}

function flattenParams(params = {}) {
  const flat = {};

  Object.keys(params).forEach((key) => {
    const value = params[key];
    if (value === undefined || value === null || value === "") return;
    flat[key] = value;
  });

  return flat;
}

function buildSignature(path, params, appSecret) {
  const sortedKeys = Object.keys(params).sort();
  let baseString = path;

  for (const key of sortedKeys) {
    baseString += key + params[key];
  }

  return crypto
    .createHmac("sha256", appSecret)
    .update(baseString, "utf8")
    .digest("hex")
    .toUpperCase();
}

function buildUrl(path, params = {}, storeToken = null) {
  const baseUrl = getBaseUrl(storeToken);
  const url = new URL(baseUrl + path);

  Object.keys(params).forEach((key) => {
    url.searchParams.append(key, String(params[key]));
  });

  return url.toString();
}

function safeString(value) {
  return (value || "").toString().trim();
}

function toNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function deepFindFirstArray(node, predicate) {
  if (Array.isArray(node)) {
    if (predicate(node)) {
      return node;
    }

    for (const item of node) {
      const found = deepFindFirstArray(item, predicate);
      if (found) return found;
    }

    return null;
  }

  if (node && typeof node === "object") {
    for (const value of Object.values(node)) {
      const found = deepFindFirstArray(value, predicate);
      if (found) return found;
    }
  }

  return null;
}

function deepFindAllArrays(node, collector = []) {
  if (Array.isArray(node)) {
    collector.push(node);

    for (const item of node) {
      deepFindAllArrays(item, collector);
    }

    return collector;
  }

  if (node && typeof node === "object") {
    for (const value of Object.values(node)) {
      deepFindAllArrays(value, collector);
    }
  }

  return collector;
}

function extractOrdersFromData(data) {
  if (!data) return [];

  if (Array.isArray(data.orders)) return data.orders;
  if (Array.isArray(data.order_list)) return data.order_list;
  if (Array.isArray(data.orders_list)) return data.orders_list;
  if (Array.isArray(data.list)) return data.list;

  const direct = deepFindFirstArray(data, (arr) => {
    if (!arr.length) return false;
    const first = arr[0];
    return (
      first &&
      typeof first === "object" &&
      (
        "order_id" in first ||
        "order_number" in first ||
        "statuses" in first ||
        "created_at" in first ||
        "updated_at" in first
      )
    );
  });

  if (direct) return direct;

  const arrays = deepFindAllArrays(data);
  for (const arr of arrays) {
    if (!arr.length) continue;
    const first = arr[0];

    if (
      first &&
      typeof first === "object" &&
      (
        "order_id" in first ||
        "order_number" in first ||
        "statuses" in first
      )
    ) {
      return arr;
    }
  }

  return [];
}

function extractItemsFromData(data) {
  if (!data) return [];

  if (Array.isArray(data.order_items)) return data.order_items;
  if (Array.isArray(data.items)) return data.items;
  if (Array.isArray(data.order_item_list)) return data.order_item_list;
  if (Array.isArray(data.list)) return data.list;

  const direct = deepFindFirstArray(data, (arr) => {
    if (!arr.length) return false;
    const first = arr[0];
    return (
      first &&
      typeof first === "object" &&
      (
        "order_item_id" in first ||
        "seller_sku" in first ||
        "shop_sku" in first ||
        "sku" in first
      )
    );
  });

  if (direct) return direct;

  const arrays = deepFindAllArrays(data);
  for (const arr of arrays) {
    if (!arr.length) continue;
    const first = arr[0];

    if (
      first &&
      typeof first === "object" &&
      (
        "order_item_id" in first ||
        "seller_sku" in first ||
        "shop_sku" in first ||
        "sku" in first
      )
    ) {
      return arr;
    }
  }

  return [];
}

function extractCount(data, listLength = 0) {
  if (!data || typeof data !== "object") return listLength;

  const possible =
    data.count ??
    data.total_count ??
    data.total ??
    data.totalRecords ??
    data.total_records ??
    data.record_count;

  if (possible !== undefined && possible !== null && possible !== "") {
    return toNumber(possible, listLength);
  }

  return listLength;
}

function isTokenError(code, message = "") {
  const normalizedCode = safeString(code).toLowerCase();
  const normalizedMessage = safeString(message).toLowerCase();

  const tokenSignals = [
    "invalid_token",
    "access_token",
    "token expired",
    "token is invalid",
    "illegal access token",
    "expired token",
    "refresh token",
    "seller authorization",
    "authorization expired"
  ];

  return (
    [
      "illegal_access_token",
      "invalid_access_token",
      "access_denied",
      "invalid_session",
      "insufficient_isv_permissions"
    ].includes(normalizedCode) ||
    tokenSignals.some((signal) => normalizedMessage.includes(signal))
  );
}

async function darazRequest(path, storeToken, customParams = {}) {
  const appKey = getRequiredEnv("DARAZ_APP_KEY");
  const appSecret = getRequiredEnv("DARAZ_APP_SECRET");

  if (!storeToken?.access_token) {
    const error = new Error("Store access token is missing");
    error.isTokenError = true;
    throw error;
  }

  const params = flattenParams({
    app_key: appKey,
    sign_method: "sha256",
    timestamp: Date.now(),
    access_token: storeToken.access_token,
    ...customParams
  });

  const sign = buildSignature(path, params, appSecret);
  const finalParams = {
    ...params,
    sign
  };

  const url = buildUrl(path, finalParams, storeToken);

  let response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        Accept: "application/json"
      }
    });
  } catch (networkError) {
    const error = new Error(`Daraz API network error: ${networkError.message}`);
    error.isNetworkError = true;
    throw error;
  }

  const text = await response.text();

  let json;
  try {
    json = JSON.parse(text);
  } catch (error) {
    const parseError = new Error(`Daraz API invalid JSON response: ${text}`);
    parseError.httpStatus = response.status;
    throw parseError;
  }

  const apiCode = json?.code;
  const apiMessage = json?.message || json?.msg || "";

  if (!response.ok) {
    const error = new Error(apiMessage || `Daraz API HTTP error ${response.status}`);
    error.httpStatus = response.status;
    error.apiCode = apiCode;
    error.apiMessage = apiMessage;
    error.isTokenError = response.status === 401 || response.status === 403 || isTokenError(apiCode, apiMessage);
    throw error;
  }

  if (String(apiCode) !== "0") {
    const error = new Error(apiMessage || `Daraz API returned error code ${apiCode || "unknown"}`);
    error.httpStatus = response.status;
    error.apiCode = apiCode;
    error.apiMessage = apiMessage;
    error.isTokenError = isTokenError(apiCode, apiMessage);
    throw error;
  }

  return json;
}

async function getOrders({
  storeToken,
  createdAfter,
  updatedAfter,
  status,
  offset = 0,
  limit = 50
}) {
  const params = {
    sort_direction: "DESC",
    offset,
    limit
  };

  if (createdAfter) params.created_after = createdAfter;
  if (updatedAfter) params.update_after = updatedAfter;
  if (status) params.status = status;

  const result = await darazRequest("/orders/get", storeToken, params);
  const orders = extractOrdersFromData(result.data);
  const count = extractCount(result.data, orders.length);

  return {
    raw: result,
    orders,
    count,
    offset,
    limit,
    hasMore: orders.length === limit || offset + orders.length < count
  };
}

async function getOrderItems({ storeToken, orderId }) {
  const result = await darazRequest("/order/items/get", storeToken, {
    order_id: orderId
  });

  const items = extractItemsFromData(result.data);

  return {
    raw: result,
    items
  };
}

module.exports = {
  darazRequest,
  getOrders,
  getOrderItems
};