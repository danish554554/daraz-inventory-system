const express = require("express");
const CentralOrder = require("../models/CentralOrder");
const CentralOrderItem = require("../models/CentralOrderItem");
const {
  syncAllStores,
  syncStoreById,
  getSyncLockState
} = require("../services/centralInventorySyncService");
const { importProductsForStore } = require("../services/darazProductImportService");

const router = express.Router();

function normalizeString(value) {
  return (value || "").toString().trim();
}

function normalizeStatus(value) {
  return normalizeString(value).toLowerCase().replace(/[\s-]+/g, "_");
}

function toNumber(value, fallback = 0) {
  if (value === undefined || value === null || value === '') return fallback;
  if (typeof value === 'string') {
    const cleaned = value.replace(/[^0-9.-]/g, '');
    const parsed = Number(cleaned);
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function toDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function startOfDay(date = new Date()) {
  const output = new Date(date);
  output.setHours(0, 0, 0, 0);
  return output;
}

function endOfDay(date = new Date()) {
  const output = new Date(date);
  output.setHours(23, 59, 59, 999);
  return output;
}

function resolveHistoryWindow({ period = "today", start, end } = {}) {
  const now = new Date();
  if (start || end) {
    return {
      startDate: start ? startOfDay(toDate(start) || now) : startOfDay(now),
      endDate: end ? endOfDay(toDate(end) || now) : endOfDay(now)
    };
  }

  const startDate = startOfDay(now);
  if (period === "week") {
    startDate.setDate(startDate.getDate() - 6);
  } else if (period === "month") {
    startDate.setDate(startDate.getDate() - 29);
  }

  return { startDate, endDate: endOfDay(now) };
}

function applyDateWindow(query, fields = [], { start, end } = {}) {
  if (!start && !end) return query;
  const startDate = start ? startOfDay(toDate(start) || new Date()) : new Date(0);
  const endDate = end ? endOfDay(toDate(end) || new Date()) : endOfDay(new Date());
  query.$and = query.$and || [];
  query.$and.push({
    $or: fields.map((field) => ({ [field]: { $gte: startDate, $lte: endDate } }))
  });
  return query;
}

function isReturnStatus(status = "") {
  const normalized = normalizeStatus(status);
  return ["return", "returned", "returning", "refund", "refunded", "claim", "claimed"].some((key) => normalized.includes(key));
}

function isFailedDeliveryStatus(status = "") {
  const normalized = normalizeStatus(status);
  return normalized.includes("failed_delivery") ||
    normalized.includes("delivery_failed") ||
    normalized.includes("failed") ||
    normalized.includes("undelivered") ||
    normalized.includes("returned_to_shipper") ||
    normalized.includes("return_to_seller");
}

function storePayload(value) {
  if (!value || typeof value !== "object") return { id: value || "", name: "-", code: "-" };
  return {
    id: value._id || value.id || "",
    name: value.name || "-",
    code: value.code || "-"
  };
}

function itemPayload(item) {
  const store = storePayload(item.store_id);
  const order = item.order_id && typeof item.order_id === "object" ? item.order_id : {};
  const title = item.display_title || item.product_name || item.seller_sku || "Daraz Product";
  const unitPrice = toNumber(item.unit_price, 0);
  const quantity = toNumber(item.quantity, 1);
  const logisticDate = item.logistic_facility_at || item.updatedAt || item.createdAt;
  const deadline = logisticDate ? new Date(new Date(logisticDate).getTime() + 6 * 24 * 60 * 60 * 1000) : null;
  const daysLeft = deadline ? Math.ceil((deadline.getTime() - Date.now()) / (24 * 60 * 60 * 1000)) : null;

  return {
    _id: item._id,
    store_id: store.id,
    store_name: store.name,
    store_code: store.code,
    order_id: order._id || item.order_id || "",
    order_number: order.order_number || item.order_number || "-",
    order_status: order.status || item.order_status || "-",
    external_order_item_id: item.external_order_item_id,
    seller_sku: item.seller_sku,
    product_name: item.product_name,
    original_title: item.original_product_name || item.product_name,
    display_title: title,
    image_url: item.image_url || "",
    quantity,
    unit_price: unitPrice,
    amount: unitPrice * quantity,
    status: item.status || "pending",
    return_status: isReturnStatus(item.status) ? item.status : "",
    return_reason: item.return_reason || "",
    claim_date: item.claim_date || null,
    logistic_facility_at: item.logistic_facility_at || null,
    collection_deadline_at: deadline,
    days_left_to_collect: daysLeft,
    collection_status: item.collection_status || "pending",
    processing_status: item.processing_status,
    stock_deducted: !!item.stock_deducted,
    stock_restored: !!item.stock_restored,
    error_message: item.error_message || "",
    createdAt: item.createdAt
  };
}

async function enrichOrder(order) {
  const store = storePayload(order.store_id);
  const item = await CentralOrderItem.findOne({ order_id: order._id })
    .sort({ createdAt: 1 })
    .lean();
  const count = await CentralOrderItem.countDocuments({ order_id: order._id });
  const title = item?.display_title || item?.product_name || item?.seller_sku || (count > 1 ? `${count} order items` : "Order item");
  const amountRows = await CentralOrderItem.find({ order_id: order._id }).select("unit_price quantity").lean();
  const amount = amountRows.reduce((sum, row) => sum + toNumber(row.unit_price, 0) * toNumber(row.quantity, 1), 0);

  return {
    ...order,
    store_id: store.id,
    store_name: store.name,
    store_code: store.code,
    product_title: title,
    product_image_url: item?.image_url || "",
    item_count: count,
    amount
  };
}

router.get("/status", async (req, res) => {
  try {
    const lockState = getSyncLockState();

    res.json({
      success: true,
      scheduler_managed_by: "orderSyncScheduler",
      sync_engine: "centralInventorySyncService",
      sync_running_now: !!lockState.syncInProgress
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error getting sync status",
      error: error.message
    });
  }
});

router.post("/run-all", async (req, res) => {
  try {
    const lockState = getSyncLockState();

    if (lockState.syncInProgress) {
      return res.status(409).json({
        success: false,
        message: "Sync is already running"
      });
    }

    const result = await syncAllStores();

    res.json({
      success: true,
      message: "Daraz sync completed",
      result
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error running Daraz sync",
      error: error.message
    });
  }
});

router.post("/run-store/:storeId", async (req, res) => {
  try {
    const lockState = getSyncLockState();

    if (lockState.syncInProgress) {
      return res.status(409).json({
        success: false,
        message: "Sync is already running"
      });
    }

    const result = await syncStoreById(req.params.storeId);

    res.json({
      success: true,
      message: "Store sync completed",
      result
    });
  } catch (error) {
    const statusCode = error.message === "Store not found" ? 404 : 500;

    res.status(statusCode).json({
      success: false,
      message: "Error syncing store",
      error: error.message
    });
  }
});

router.post("/import-products/:storeId", async (req, res) => {
  try {
    const result = await importProductsForStore(req.params.storeId, req.body || {});

    res.json({
      success: true,
      message: "Daraz active products imported successfully",
      result
    });
  } catch (error) {
    const statusCode = error.message === "Store not found" ? 404 : 500;

    res.status(statusCode).json({
      success: false,
      message: "Error importing Daraz products",
      error: error.message
    });
  }
});

router.get("/orders", async (req, res) => {
  try {
    const { store_id, status, limit = 50 } = req.query;
    const query = {};

    if (store_id) query.store_id = store_id;
    if (status) query.status = normalizeString(status).toLowerCase();

    const orders = await CentralOrder.find(query)
      .populate("store_id", "name code deduct_stage")
      .sort({ order_created_at: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 50, 200))
      .lean();

    const enriched = await Promise.all(orders.map(enrichOrder));

    res.json({
      success: true,
      count: enriched.length,
      orders: enriched
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching synced orders",
      error: error.message
    });
  }
});

router.get("/order-items", async (req, res) => {
  try {
    const {
      store_id,
      seller_sku,
      processing_status,
      status,
      limit = 100
    } = req.query;

    const query = {};

    if (store_id) query.store_id = store_id;
    if (seller_sku) query.seller_sku = normalizeString(seller_sku);
    if (processing_status) query.processing_status = normalizeString(processing_status).toLowerCase();
    if (status) query.status = normalizeString(status).toLowerCase();

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    res.json({
      success: true,
      count: items.length,
      items: items.map(itemPayload)
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching synced order items",
      error: error.message
    });
  }
});

router.get("/return-orders", async (req, res) => {
  try {
    const { store_id, limit = 100, start, end } = req.query;
    const query = {
      $or: [
        { status: { $regex: "return|refund|claim|returned", $options: "i" } },
        { return_reason: { $ne: "" } },
        { claim_date: { $ne: null } }
      ]
    };
    if (store_id) query.store_id = store_id;
    applyDateWindow(query, ['claim_date', 'updatedAt', 'createdAt'], { start, end });

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ claim_date: -1, updatedAt: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    res.json({
      success: true,
      count: items.length,
      returns: items.map(itemPayload)
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching return orders",
      error: error.message
    });
  }
});

router.get("/failed-delivery", async (req, res) => {
  try {
    const { store_id, limit = 100, start, end } = req.query;
    const query = {
      $or: [
        { status: { $regex: "failed|undelivered|return_to_seller|returned_to_shipper|return_to_shipper|delivery_failed", $options: "i" } },
        { collection_status: "needs_collection" },
        { logistic_facility_at: { $ne: null } }
      ]
    };
    if (store_id) query.store_id = store_id;
    applyDateWindow(query, ['logistic_facility_at', 'updatedAt', 'createdAt'], { start, end });

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ logistic_facility_at: -1, updatedAt: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    res.json({
      success: true,
      count: items.length,
      failed_deliveries: items.map(itemPayload).filter((item) => isFailedDeliveryStatus(item.status) || item.collection_status === 'needs_collection' || item.logistic_facility_at)
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching failed delivery orders",
      error: error.message
    });
  }
});

router.get("/orders-history", async (req, res) => {
  try {
    const { period = "today", store_id, status, start, end, limit = 100 } = req.query;
    const { startDate, endDate } = resolveHistoryWindow({ period, start, end });
    const query = { order_created_at: { $gte: startDate, $lte: endDate } };
    if (store_id) query.store_id = store_id;
    if (status) query.status = normalizeString(status).toLowerCase();

    const orders = await CentralOrder.find(query)
      .populate("store_id", "name code")
      .sort({ order_created_at: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    const orderIds = orders.map((order) => order._id);
    const items = await CentralOrderItem.find({ order_id: { $in: orderIds } }).lean();
    const revenue = items.reduce((sum, item) => sum + toNumber(item.unit_price, 0) * toNumber(item.quantity, 1), 0);
    const returns = items.filter((item) => isReturnStatus(item.status) || normalizeString(item.return_reason) || item.claim_date).length;
    const failedDeliveries = items.filter((item) => isFailedDeliveryStatus(item.status) || item.collection_status === 'needs_collection' || item.logistic_facility_at).length;

    const seriesMap = new Map();
    for (const order of orders) {
      const key = new Date(order.order_created_at || order.createdAt).toISOString().slice(0, 10);
      if (!seriesMap.has(key)) seriesMap.set(key, { date: key, orders: 0, revenue: 0 });
      seriesMap.get(key).orders += 1;
    }
    for (const item of items) {
      const order = orders.find((row) => String(row._id) === String(item.order_id));
      const key = new Date(order?.order_created_at || item.createdAt).toISOString().slice(0, 10);
      if (!seriesMap.has(key)) seriesMap.set(key, { date: key, orders: 0, revenue: 0 });
      seriesMap.get(key).revenue += toNumber(item.unit_price, 0) * toNumber(item.quantity, 1);
    }

    const enriched = await Promise.all(orders.map(enrichOrder));

    res.json({
      success: true,
      period,
      start_date: startDate,
      end_date: endDate,
      summary: {
        total_orders: orders.length,
        revenue,
        returns,
        failed_deliveries: failedDeliveries
      },
      series: Array.from(seriesMap.values()).sort((a, b) => a.date.localeCompare(b.date)),
      orders: enriched
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching orders history",
      error: error.message
    });
  }
});

module.exports = router;
