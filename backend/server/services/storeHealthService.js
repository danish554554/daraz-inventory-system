
const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const StoreConnectionConfig = require("../models/StoreConnectionConfig");
const StoreSyncLog = require("../models/StoreSyncLog");
const { buildTokenSummary } = require("./darazService");

function normalizeString(value) {
  return String(value || "").trim();
}

function safeDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function diffMinutes(fromDate) {
  const date = safeDate(fromDate);
  if (!date) return null;
  return Math.max(0, Math.floor((Date.now() - date.getTime()) / (1000 * 60)));
}

function getOverallHealth({ store, tokenSummary, config, latestSync }) {
  if (store.status !== "active") {
    return {
      state: "inactive",
      label: "Inactive",
      priority: 5,
      reason: "Store is inactive"
    };
  }

  if (!config) {
    return {
      state: "setup_required",
      label: "Setup required",
      priority: 1,
      reason: "Daraz configuration not saved"
    };
  }

  if (!tokenSummary.token_connected) {
    return {
      state: "not_connected",
      label: "Not connected",
      priority: 1,
      reason: "Store has no token connection"
    };
  }

  if (["invalid", "expired"].includes(tokenSummary.token_status)) {
    return {
      state: "reconnect_required",
      label: "Reconnect required",
      priority: 1,
      reason: tokenSummary.last_error || "Token is invalid or expired"
    };
  }

  if (tokenSummary.token_status === "expiring_soon") {
    return {
      state: "attention",
      label: "Attention",
      priority: 2,
      reason: "Token is expiring soon"
    };
  }

  if (latestSync && latestSync.success === false) {
    return {
      state: "sync_error",
      label: "Sync error",
      priority: 2,
      reason: latestSync.summary_message || "Latest sync failed"
    };
  }

  return {
    state: "healthy",
    label: "Healthy",
    priority: 4,
    reason: "Connection and latest sync look good"
  };
}

function summarizeSync(latestSync) {
  if (!latestSync) {
    return {
      last_sync_started_at: null,
      last_sync_finished_at: null,
      last_sync_success: null,
      last_sync_trigger: null,
      last_sync_message: "No sync has run yet",
      last_sync_duration_ms: 0,
      last_sync_failed_count: 0,
      last_sync_warning_count: 0
    };
  }

  return {
    last_sync_started_at: latestSync.sync_started_at || latestSync.createdAt || null,
    last_sync_finished_at: latestSync.sync_finished_at || latestSync.updatedAt || null,
    last_sync_success: latestSync.success,
    last_sync_trigger: latestSync.trigger_source || "manual",
    last_sync_message: latestSync.summary_message || "",
    last_sync_duration_ms: latestSync.duration_ms || 0,
    last_sync_failed_count: latestSync.failed || 0,
    last_sync_warning_count: Array.isArray(latestSync.warnings) ? latestSync.warnings.length : 0
  };
}

function buildStoreHealthRecord(store, token, config, latestSync) {
  const tokenSummary = buildTokenSummary(token);
  const syncSummary = summarizeSync(latestSync);
  const overall = getOverallHealth({
    store,
    tokenSummary,
    config,
    latestSync
  });

  return {
    ...store,
    daraz_connected: !!config,
    daraz_auth_status: config?.auth_status || "not_connected",
    daraz_region: config?.api_region || null,
    token_status: tokenSummary.token_status,
    token_connected: tokenSummary.token_connected,
    token_source: tokenSummary.token_source,
    expires_at: tokenSummary.expires_at,
    expires_in_minutes: tokenSummary.expires_in_minutes,
    is_expired: tokenSummary.is_expired,
    is_expiring_soon: tokenSummary.is_expiring_soon,
    last_sync_at: tokenSummary.last_sync_at,
    last_validated_at: tokenSummary.last_validated_at,
    last_refreshed_at: tokenSummary.last_refreshed_at,
    last_error: tokenSummary.last_error,
    seller_id: tokenSummary.seller_id,
    account: tokenSummary.account,
    auth_last_error: config?.last_error_message || "",
    auth_last_connected_at: config?.last_connected_at || null,
    auth_last_generated_at: config?.auth_url_last_generated_at || null,
    sync_minutes_since_last: diffMinutes(syncSummary.last_sync_finished_at || syncSummary.last_sync_started_at),
    ...syncSummary,
    health_state: overall.state,
    health_label: overall.label,
    health_priority: overall.priority,
    health_reason: overall.reason
  };
}

async function getStoresHealthData() {
  const stores = await Store.find().sort({ createdAt: -1 }).lean();
  if (!stores.length) {
    return { stores: [], summary: emptySummary() };
  }

  const storeIds = stores.map((store) => store._id);
  const [tokens, configs, logs] = await Promise.all([
    StoreToken.find({ store_id: { $in: storeIds } }).lean(),
    StoreConnectionConfig.find({ store_id: { $in: storeIds } }).lean(),
    StoreSyncLog.find({ store_id: { $in: storeIds } })
      .sort({ sync_started_at: -1, createdAt: -1 })
      .lean()
  ]);

  const tokenMap = new Map(tokens.map((item) => [String(item.store_id), item]));
  const configMap = new Map(configs.map((item) => [String(item.store_id), item]));

  const latestLogMap = new Map();
  for (const log of logs) {
    const key = String(log.store_id);
    if (!latestLogMap.has(key)) {
      latestLogMap.set(key, log);
    }
  }

  const enriched = stores.map((store) =>
    buildStoreHealthRecord(
      store,
      tokenMap.get(String(store._id)) || null,
      configMap.get(String(store._id)) || null,
      latestLogMap.get(String(store._id)) || null
    )
  );

  return {
    stores: enriched,
    summary: buildHealthSummary(enriched)
  };
}

function emptySummary() {
  return {
    total_stores: 0,
    active_stores: 0,
    inactive_stores: 0,
    healthy_stores: 0,
    attention_stores: 0,
    reconnect_required: 0,
    setup_required: 0,
    sync_error_stores: 0,
    connected_stores: 0,
    disconnected_stores: 0,
    expiring_soon: 0
  };
}

function buildHealthSummary(stores) {
  const summary = emptySummary();
  summary.total_stores = stores.length;
  summary.active_stores = stores.filter((store) => store.status === "active").length;
  summary.inactive_stores = stores.filter((store) => store.status !== "active").length;
  summary.healthy_stores = stores.filter((store) => store.health_state === "healthy").length;
  summary.attention_stores = stores.filter((store) => store.health_state === "attention").length;
  summary.reconnect_required = stores.filter((store) => store.health_state === "reconnect_required").length;
  summary.setup_required = stores.filter((store) => ["setup_required", "not_connected"].includes(store.health_state)).length;
  summary.sync_error_stores = stores.filter((store) => store.health_state === "sync_error").length;
  summary.connected_stores = stores.filter((store) => store.token_connected).length;
  summary.disconnected_stores = stores.length - summary.connected_stores;
  summary.expiring_soon = stores.filter((store) => store.token_status === "expiring_soon").length;
  return summary;
}

async function getSingleStoreHealth(storeId, logLimit = 10) {
  const store = await Store.findById(storeId).lean();

  if (!store) {
    throw new Error("Store not found");
  }

  const [token, config, logs] = await Promise.all([
    StoreToken.findOne({ store_id: storeId }).lean(),
    StoreConnectionConfig.findOne({ store_id: storeId }).lean(),
    StoreSyncLog.find({ store_id: storeId })
      .sort({ sync_started_at: -1, createdAt: -1 })
      .limit(logLimit)
      .lean()
  ]);

  const record = buildStoreHealthRecord(
    store,
    token,
    config,
    logs[0] || null
  );

  return {
    store: record,
    sync_logs: logs
  };
}

module.exports = {
  getStoresHealthData,
  getSingleStoreHealth,
  buildStoreHealthRecord,
  buildHealthSummary
};
