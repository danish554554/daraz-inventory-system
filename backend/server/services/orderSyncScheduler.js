const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const { syncStoreById, refreshCollectionWatch } = require("./centralInventorySyncService");

let inventoryAlertService = null;
try {
  inventoryAlertService = require("./inventoryAlertService");
} catch (error) {
  inventoryAlertService = null;
}

let schedulerStarted = false;
let schedulerTimer = null;
let schedulerRunInProgress = false;

function toNumber(value, fallback) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function isSchedulerEnabled() {
  return String(process.env.ORDER_SYNC_ENABLED || "true").toLowerCase() === "true";
}

function getHeartbeatMs() {
  const minutes = toNumber(process.env.ORDER_SYNC_HEARTBEAT_MINUTES || 1, 1);
  return minutes <= 0 ? 60 * 1000 : minutes * 60 * 1000;
}

function getInitialDelayMs() {
  const seconds = toNumber(process.env.ORDER_SYNC_INITIAL_DELAY_SECONDS || 10, 10);
  return seconds < 0 ? 10 * 1000 : seconds * 1000;
}

function normalizeIntervalMinutes(value, fallback = 5) {
  const minutes = toNumber(value, fallback);
  return minutes <= 0 ? fallback : minutes;
}

function getReturnScanIntervalMinutes() {
  return normalizeIntervalMinutes(process.env.RETURN_SYNC_INTERVAL_MINUTES || 30, 30);
}

function getFailedDeliveryScanIntervalMinutes() {
  return normalizeIntervalMinutes(process.env.FAILED_DELIVERY_SYNC_INTERVAL_MINUTES || 30, 30);
}

function getHistoryDays() {
  const days = toNumber(process.env.ORDER_SYNC_HISTORY_DAYS || 30, 30);
  return Math.min(Math.max(days, 1), 180);
}

function getElapsedMs(fromDate) {
  if (!fromDate) return Number.POSITIVE_INFINITY;
  const time = new Date(fromDate).getTime();
  if (Number.isNaN(time)) return Number.POSITIVE_INFINITY;
  return Date.now() - time;
}

function dateForTrigger(store, token, triggerSource) {
  if (triggerSource === "return_scan") {
    return store.last_return_scan_at || token?.last_return_scan_at || store.last_return_scan_attempt_at || token?.last_return_scan_attempt_at || null;
  }

  if (triggerSource === "failed_delivery_scan") {
    return store.last_failed_delivery_scan_at || token?.last_failed_delivery_scan_at || store.last_failed_delivery_scan_attempt_at || token?.last_failed_delivery_scan_attempt_at || null;
  }

  return store.last_success_sync_at || store.last_sync_at || token?.last_success_sync_at || token?.last_sync_at || store.last_sync_attempt_at || token?.last_sync_attempt_at || null;
}

async function getDueStores({ triggerSource, intervalMinutes = null } = {}) {
  const stores = await Store.find({ status: { $ne: "inactive" } }).sort({ createdAt: 1 }).lean();
  if (!stores.length) return [];

  const storeIds = stores.map((store) => store._id);
  const tokens = await StoreToken.find({ store_id: { $in: storeIds } }).lean();
  const tokenMap = new Map(tokens.map((token) => [String(token.store_id), token]));

  return stores
    .map((store) => {
      const token = tokenMap.get(String(store._id)) || null;
      const storeIntervalMinutes = intervalMinutes || normalizeIntervalMinutes(store.sync_interval_minutes, 5);
      const lastSyncDate = dateForTrigger(store, token, triggerSource);
      const elapsedMs = getElapsedMs(lastSyncDate);
      const dueMs = storeIntervalMinutes * 60 * 1000;

      return {
        store,
        token,
        intervalMinutes: storeIntervalMinutes,
        elapsedMs,
        dueMs,
        isDue: elapsedMs >= dueMs
      };
    })
    .filter((entry) => entry.isDue);
}

async function runCollectionWatchSnapshot() {
  if (typeof refreshCollectionWatch !== "function") return;
  try {
    const summary = await refreshCollectionWatch();
    if (summary.pending_collection || summary.due_soon || summary.overdue) {
      console.log(`[Daraz Sync Scheduler] collection watch: ${summary.pending_collection} pending, ${summary.due_soon} due soon, ${summary.overdue} overdue`);
    }
  } catch (error) {
    console.error(`[Daraz Sync Scheduler] collection watch failed: ${error.message}`);
  }
}

async function runDailyLowStockSnapshot() {
  if (!inventoryAlertService?.runDailyLowStockAlertSnapshot) {
    return;
  }

  try {
    await inventoryAlertService.runDailyLowStockAlertSnapshot();
  } catch (error) {
    console.error(`[Daraz Sync Scheduler] low-stock snapshot failed: ${error.message}`);
  }
}

async function runDueStoreBatch({ label, triggerSource, intervalMinutes = null, historyDays = null }) {
  const dueStores = await getDueStores({ triggerSource, intervalMinutes });

  if (!dueStores.length) {
    console.log(`[Daraz Sync Scheduler] ${label}: no stores due for ${triggerSource}`);
    return 0;
  }

  console.log(`[Daraz Sync Scheduler] ${label}: ${dueStores.length} store(s) due for ${triggerSource}`);

  for (const entry of dueStores) {
    const { store, token, intervalMinutes: resolvedInterval } = entry;

    if (!token) {
      console.log(
        `[Daraz Sync Scheduler] skipped store "${store.name}" (${store.code}) because no token is connected`
      );
      continue;
    }

    try {
      const result = await syncStoreById(store._id, {
        triggerSource,
        historyDays: historyDays || getHistoryDays()
      });

      console.log(
        `[Daraz Sync Scheduler] ${triggerSource} completed for "${store.name}" (${store.code}) on ${resolvedInterval} minute interval`
      );
      console.log(JSON.stringify(result, null, 2));
    } catch (error) {
      console.error(
        `[Daraz Sync Scheduler] ${triggerSource} failed for "${store.name}" (${store.code}): ${error.message}`
      );
    }
  }

  return dueStores.length;
}

async function runSchedulerCycle(label = "scheduled") {
  if (schedulerRunInProgress) {
    console.log(`[Daraz Sync Scheduler] skipped ${label} cycle because previous cycle is still running`);
    return;
  }

  schedulerRunInProgress = true;

  try {
    const orderTrigger = label === "initial" ? "initial" : "scheduled";

    await runDueStoreBatch({
      label,
      triggerSource: orderTrigger
    });

    await runDueStoreBatch({
      label,
      triggerSource: "return_scan",
      intervalMinutes: getReturnScanIntervalMinutes(),
      historyDays: getHistoryDays()
    });

    await runDueStoreBatch({
      label,
      triggerSource: "failed_delivery_scan",
      intervalMinutes: getFailedDeliveryScanIntervalMinutes(),
      historyDays: getHistoryDays()
    });

    await runDailyLowStockSnapshot();
    await runCollectionWatchSnapshot();
  } catch (error) {
    console.error(`[Daraz Sync Scheduler] ${label} cycle failed: ${error.message}`);
  } finally {
    schedulerRunInProgress = false;
  }
}

function startOrderSyncScheduler() {
  if (schedulerStarted) return;
  schedulerStarted = true;

  if (!isSchedulerEnabled()) {
    console.log("[Daraz Sync Scheduler] disabled by ORDER_SYNC_ENABLED");
    return;
  }

  const heartbeatMs = getHeartbeatMs();
  const initialDelayMs = getInitialDelayMs();

  console.log(
    `[Daraz Sync Scheduler] started. Heartbeat: ${heartbeatMs / 1000}s, initial delay: ${initialDelayMs / 1000}s, return scan: ${getReturnScanIntervalMinutes()}m, failed-delivery scan: ${getFailedDeliveryScanIntervalMinutes()}m`
  );

  setTimeout(() => {
    runSchedulerCycle("initial");
  }, initialDelayMs);

  schedulerTimer = setInterval(() => {
    runSchedulerCycle("scheduled");
  }, heartbeatMs);
}

function stopOrderSyncScheduler() {
  if (schedulerTimer) {
    clearInterval(schedulerTimer);
    schedulerTimer = null;
  }
  schedulerStarted = false;
  schedulerRunInProgress = false;
}

module.exports = {
  startOrderSyncScheduler,
  stopOrderSyncScheduler
};
