
const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const { syncStoreById } = require("./centralInventorySyncService");

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

function normalizeIntervalMinutes(value) {
  const minutes = toNumber(value, 5);
  return minutes <= 0 ? 5 : minutes;
}

function getElapsedMs(fromDate) {
  if (!fromDate) return Number.POSITIVE_INFINITY;
  const time = new Date(fromDate).getTime();
  if (Number.isNaN(time)) return Number.POSITIVE_INFINITY;
  return Date.now() - time;
}

async function getDueStores() {
  const stores = await Store.find({ status: "active" }).sort({ createdAt: 1 }).lean();
  if (!stores.length) return [];

  const storeIds = stores.map((store) => store._id);
  const tokens = await StoreToken.find({ store_id: { $in: storeIds } }).lean();
  const tokenMap = new Map(tokens.map((token) => [String(token.store_id), token]));

  return stores
    .map((store) => {
      const token = tokenMap.get(String(store._id)) || null;
      const intervalMinutes = normalizeIntervalMinutes(store.sync_interval_minutes);
      const elapsedMs = getElapsedMs(token?.last_sync_at);
      const dueMs = intervalMinutes * 60 * 1000;

      return {
        store,
        token,
        intervalMinutes,
        elapsedMs,
        dueMs,
        isDue: elapsedMs >= dueMs
      };
    })
    .filter((entry) => entry.isDue);
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

async function runSchedulerCycle(label = "scheduled") {
  if (schedulerRunInProgress) {
    console.log(`[Daraz Sync Scheduler] skipped ${label} cycle because previous cycle is still running`);
    return;
  }

  schedulerRunInProgress = true;

  try {
    const dueStores = await getDueStores();

    if (!dueStores.length) {
      console.log(`[Daraz Sync Scheduler] ${label} cycle: no stores due for sync`);
      await runDailyLowStockSnapshot();
      return;
    }

    console.log(`[Daraz Sync Scheduler] ${label} cycle: ${dueStores.length} store(s) due for sync`);

    for (const entry of dueStores) {
      const { store, token, intervalMinutes } = entry;

      if (!token) {
        console.log(
          `[Daraz Sync Scheduler] skipped store "${store.name}" (${store.code}) because no token is connected`
        );
        continue;
      }

      try {
        const result = await syncStoreById(store._id, {
          triggerSource: label === "initial" ? "initial" : "scheduled"
        });

        console.log(
          `[Daraz Sync Scheduler] synced store "${store.name}" (${store.code}) on ${intervalMinutes} minute interval`
        );
        console.log(JSON.stringify(result, null, 2));
      } catch (error) {
        console.error(
          `[Daraz Sync Scheduler] failed syncing store "${store.name}" (${store.code}): ${error.message}`
        );
      }
    }

    await runDailyLowStockSnapshot();
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
    `[Daraz Sync Scheduler] started with per-store intervals. Heartbeat: ${heartbeatMs / 1000}s, initial delay: ${initialDelayMs / 1000}s`
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
