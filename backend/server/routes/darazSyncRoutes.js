const express = require("express");
const CentralOrder = require("../models/CentralOrder");
const CentralOrderItem = require("../models/CentralOrderItem");
const {
  syncAllStores,
  syncStoreById,
  getSyncLockState,
  markOrderItemReceivedBack
} = require("../services/centralInventorySyncService");
const { importProductsForStore } = require("../services/darazProductImportService");
const orderRules = require("../utils/orderClassification");

const router = express.Router();

function normalizeString(value) {
  return (value || "").toString().trim();
}

function normalizeStatus(value) {
  return normalizeString(value).toLowerCase().replace(/[\s-]+/g, "_");
}

function toNumber(value, fallback = 0) {
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

function applyDateRange(query, field, { period = "today", start, end } = {}) {
  const { startDate, endDate } = resolveHistoryWindow({ period, start, end });
  query[field] = { $gte: startDate, $lte: endDate };
  return { startDate, endDate };
}

function buildEventDateRangeQuery(fields, { period = "all", start, end } = {}) {
  if (period === "all" && !start && !end) {
    return {
      startDate: null,
      endDate: null,
      dateQuery: {}
    };
  }
  const { startDate, endDate } = resolveHistoryWindow({ period: period === "all" ? "month" : period, start, end });
  return {
    startDate,
    endDate,
    dateQuery: {
      $or: fields.map((field) => ({ [field]: { $gte: startDate, $lte: endDate } }))
    }
  };
}

function notCancelledQuery() {
  return {
    $and: [
      { status_category: { $ne: "cancelled" } },
      { status: { $not: /cancel|cancelled|canceled|closed|unpaid|payment_failed|failed_payment|not_completed|incomplete/i } }
    ]
  };
}

function cancelledQuery() {
  return {
    $or: [
      { status_category: "cancelled" },
      { status: { $regex: "cancel|cancelled|canceled|closed|unpaid|payment_failed|failed_payment|not_completed|incomplete", $options: "i" } }
    ]
  };
}

function returnOrClaimQuery() {
  return {
    $and: [
      notCancelledQuery(),
      {
        parcel_type: { $ne: "failed_delivery" }
      },
      {
        status_category: { $ne: "failed_delivery" }
      },
      {
        status: { $not: /failed_delivery|delivery_failed|undelivered|returned_to_shipper|return_to_seller|failed_to_deliver|unable_to_deliver|rejected_at_doorstep|rejected at doorstep/i }
      },
      {
        return_reason: { $not: /rejected at doorstep|rejected_at_doorstep|customer rescheduled|outside of delivery sla|others_missing_mapping|wrong address|delivery address|consignee not available|customer not available|customer unreachable|phone switched off|no answer|premises closed|out of delivery area|failed delivery|delivery failed|unable to deliver|undelivered/i }
      },
      {
        $or: [
          { parcel_type: "return" },
          { status_category: "return" },
          { status_category: "collected", parcel_type: "return" },
          { claim_date: { $ne: null } },
          { status: { $regex: "customer_return|buyer_return|return_requested|returning|refund|refunded|claim|claimed|^returned$", $options: "i" } },
          { return_reason: { $regex: "defective|not_working|wrong_item|damaged|broken|missing_parts|missing_items|counterfeit|poor_quality|change_of_mind|customer_return|buyer_return|rma", $options: "i" } }
        ]
      }
    ]
  };
}

function failedDeliveryQuery() {
  return {
    $and: [
      notCancelledQuery(),
      {
        collection_status: { $nin: ["collected", "received"] }
      },
      {
        status_category: { $nin: ["cancelled", "collected", "scrapped"] }
      },
      {
        $or: [
          { parcel_type: "failed_delivery" },
          { status_category: "failed_delivery" },
          { status: { $regex: "failed_delivery|delivery_failed|undelivered|unable_to_deliver|failed_to_deliver|returned_to_shipper|return_to_seller|package_scrapped", $options: "i" } },
          { hub_arrived_at: { $ne: null }, parcel_type: { $ne: "return" } },
          { logistic_facility_at: { $ne: null }, parcel_type: { $ne: "return" } }
        ]
      },
      {
        status: { $not: /successfully_returned|successfully returned|package_returned|package returned|delivered_to_merchant/i }
      },
      { return_reason: { $in: [null, ""] } },
      { claim_date: { $in: [null] } }
    ]
  };
}

function activeSaleItemQuery() {
  return {
    $and: [
      notCancelledQuery(),
      {
        $or: [
          { revenue_countable: true },
          { status_category: "active_sale" },
          { status: { $regex: "confirmed|created|pending|packed|ready_to_ship|shipped|delivered|completed|processed", $options: "i" } }
        ]
      },
      { parcel_type: { $nin: ["return", "failed_delivery"] } },
      { status_category: { $nin: ["cancelled", "return", "failed_delivery", "collected", "scrapped"] } }
    ]
  };
}

function isReturnStatus(status = "", item = {}) {
  return orderRules.isReturnStatus(status, item);
}

function isFailedDeliveryStatus(status = "", item = {}) {
  return orderRules.isFailedDeliveryStatus(status, item);
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
  if (!item) return {};
  try {
    const order = item.order_id && typeof item.order_id === "object" ? item.order_id : {};
    let store = storePayload(item.store_id);
    if ((!store.name || store.name === "-") && order.store_id) {
      store = storePayload(order.store_id);
    }
    const title = item.display_title || item.product_name || item.seller_sku || "Daraz Product";
    const unitPrice = toNumber(item.unit_price, 0);
    const quantity = toNumber(item.quantity, 1);
    const costPrice = toNumber(item.cost_price, 0);
    const totalAmount = unitPrice * quantity;
    const totalCost = costPrice * quantity;
    const profitReady = !!(item.profit_ready || (costPrice > 0));
    const itemProfit = (item.profit !== null && item.profit !== undefined)
      ? Number(item.profit)
      : (costPrice > 0 ? totalAmount - totalCost : null);
    const itemProfitMargin = (item.profit_margin !== null && item.profit_margin !== undefined)
      ? Number(item.profit_margin)
      : (totalAmount > 0 && costPrice > 0 ? Number((((totalAmount - totalCost) / totalAmount) * 100).toFixed(2)) : null);

    const hubArrivedAt = item.hub_arrived_at || item.logistic_facility_at || null;
    const storedDeadline = item.collection_deadline_at || null;
    const defaultDeadlineDays = orderRules.DEFAULT_COLLECTION_DEADLINE_DAYS || 6;
    const deadline = storedDeadline || (hubArrivedAt ? new Date(new Date(hubArrivedAt).getTime() + defaultDeadlineDays * 24 * 60 * 60 * 1000) : null);
    const rawInspectionText = `${item.status || ''} ${item.return_reason || ''} ${item.hub_name || ''} ${item.collection_notes || ''}`;
    const classification = orderRules.classifyOrderItem({
      status: item.status || "",
      orderStatus: order.status || item.order_status || "",
      returnReason: item.return_reason || "",
      claimDate: item.claim_date || null,
      hubArrivedAt,
      rawPayload: item.raw_payload || {}
    });

    const isAutoReturned = classification.isCollected || orderRules.isSuccessfullyReturnedToMerchant(rawInspectionText, item.raw_payload || {});
    const baseCollectionStatus = item.collection_status || "pending";
    const collectionStatus = isAutoReturned ? "collected" : baseCollectionStatus;
    const collected = isAutoReturned || ["collected", "received"].includes(normalizeStatus(collectionStatus)) || !!item.collected_at;
    const daysLeft = collected ? 0 : (deadline ? Math.ceil((new Date(deadline).getTime() - Date.now()) / (24 * 60 * 60 * 1000)) : null);
    const notificationLevel = collected ? "collected" : orderRules.collectionNotificationLevel({
      collectionStatus,
      deadline,
      hubArrivedAt
    });

    return {
      _id: item._id,
      store_id: store.id,
      store_name: store.name,
      store_code: store.code,
      order_id: order._id || item.order_id || "",
      order_number: order.order_number || item.order_number || "-",
      order_status: order.status || item.order_status || "-",
      external_order_item_id: item.external_order_item_id || "",
      seller_sku: item.seller_sku || "",
      product_name: item.product_name || "",
      original_title: item.original_product_name || item.product_name || "",
      display_title: title,
      image_url: item.image_url || "",
      quantity,
      unit_price: unitPrice,
      cost_price: costPrice,
      amount: totalAmount,
      total_cost: totalCost,
      profit: itemProfit,
      profit_margin: itemProfitMargin,
      profit_ready: profitReady,
      status: item.status || "pending",
      original_daraz_status: item.original_daraz_status || item.status || "",
      original_daraz_reason: item.original_daraz_reason || item.return_reason || "",
      reason_code: item.reason_code || classification.reasonCode || "",
      reason_label: item.reason_label || classification.reasonLabel || "",
      mapping_confidence: item.mapping_confidence || classification.mappingConfidence || "mapped",
      needs_review: item.needs_review !== undefined ? !!item.needs_review : !!classification.needsReview,
      review_reason: item.review_reason || classification.reviewReason || "",
      status_category: item.status_category || classification.statusCategory || "pending",
      parcel_type: item.parcel_type || classification.parcelType || "none",
      revenue_countable: !!item.revenue_countable,
      return_status: isReturnStatus(item.status, item) ? item.status : "",
      return_reason: item.return_reason || "",
      claim_date: item.claim_date || null,
      logistic_facility_at: item.logistic_facility_at || null,
      hub_name: item.hub_name || orderRules.DEFAULT_COLLECTION_HUB_NAME || "Islamabad I9 Center",
      hub_arrived_at: hubArrivedAt,
      collection_deadline_at: deadline,
      days_left_to_collect: daysLeft,
      collection_status: collected ? "collected" : collectionStatus,
      collection_action_required: orderRules.collectionActionRequired({
        parcelType: item.parcel_type || "none",
        hubArrivedAt,
        collectionStatus
      }),
      collection_notification_level: notificationLevel,
      collected_at: item.collected_at || null,
      processing_status: item.processing_status || "pending",
      stock_deducted: !!item.stock_deducted,
      stock_restored: !!item.stock_restored,
      error_message: item.error_message || "",
      createdAt: item.createdAt || new Date(),
      updatedAt: item.updatedAt || new Date()
    };
  } catch (err) {
    console.error("itemPayload processing error:", err);
    return {
      _id: item._id || "",
      store_id: "",
      store_name: "-",
      store_code: "-",
      order_id: item.order_id || "",
      order_number: item.order_number || "-",
      order_status: item.status || "-",
      external_order_item_id: item.external_order_item_id || "",
      seller_sku: item.seller_sku || "",
      product_name: item.product_name || "",
      original_title: item.product_name || "",
      display_title: item.product_name || item.seller_sku || "Daraz Product",
      image_url: item.image_url || "",
      quantity: 1,
      unit_price: 0,
      cost_price: 0,
      amount: 0,
      total_cost: 0,
      profit: null,
      profit_margin: null,
      profit_ready: false,
      status: item.status || "pending",
      status_category: item.status_category || "pending",
      parcel_type: item.parcel_type || "none",
      revenue_countable: false,
      return_status: "",
      return_reason: item.return_reason || "",
      claim_date: null,
      logistic_facility_at: null,
      hub_name: "Islamabad I9 Center",
      hub_arrived_at: null,
      collection_deadline_at: null,
      days_left_to_collect: null,
      collection_status: "pending",
      collection_action_required: false,
      collection_notification_level: "none",
      collected_at: null,
      processing_status: "pending",
      stock_deducted: false,
      stock_restored: false,
      error_message: "",
      createdAt: new Date(),
      updatedAt: new Date()
    };
  }
}

async function enrichOrder(order) {
  const store = storePayload(order.store_id);
  const item = await CentralOrderItem.findOne({ order_id: order._id })
    .sort({ createdAt: 1 })
    .lean();
  const count = await CentralOrderItem.countDocuments({ order_id: order._id });
  const title = item?.display_title || item?.product_name || item?.seller_sku || "Order items";
  const amountRows = await CentralOrderItem.find({ order_id: order._id })
    .select("unit_price cost_price profit profit_margin profit_ready quantity status status_category parcel_type revenue_countable")
    .lean();
  const saleRows = amountRows.filter((row) => orderRules.itemMatchesSale(row, order));
  const amount = saleRows.reduce((sum, row) => sum + toNumber(row.unit_price, 0) * toNumber(row.quantity, 1), 0);
  const totalCost = saleRows.reduce((sum, row) => sum + toNumber(row.cost_price, 0) * toNumber(row.quantity, 1), 0);
  const profitReady = saleRows.some((row) => row.profit_ready || toNumber(row.cost_price, 0) > 0);
  const profit = profitReady ? amount - totalCost : null;
  const profitMargin = (profitReady && amount > 0)
    ? Number((((amount - totalCost) / amount) * 100).toFixed(2))
    : null;

  return {
    ...order,
    store_id: store.id,
    store_name: store.name,
    store_code: store.code,
    product_title: title,
    product_image_url: item?.image_url || "",
    status_category: order.status_category || orderRules.classifyOrderStatus(order.status),
    revenue_countable: !!order.revenue_countable,
    item_count: count,
    amount,
    total_cost: totalCost,
    profit,
    profit_margin: profitMargin,
    profit_ready: profitReady
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

router.post("/scan-returns", async (req, res) => {
  try {
    const lockState = getSyncLockState();
    if (lockState.syncInProgress) {
      return res.status(409).json({ success: false, message: "Sync is already running" });
    }

    const result = await syncAllStores({ triggerSource: "return_scan", historyDays: Number(req.body?.history_days || 40) });
    const count = await CentralOrderItem.countDocuments(returnOrClaimQuery());

    res.json({ success: true, message: "Return orders scanned from all connected stores (last 40 days).", count, result });
  } catch (error) {
    res.status(500).json({ success: false, message: "Error scanning return orders", error: error.message });
  }
});

router.post("/scan-failed-delivery", async (req, res) => {
  try {
    const lockState = getSyncLockState();
    if (lockState.syncInProgress) {
      return res.status(409).json({ success: false, message: "Sync is already running" });
    }

    const result = await syncAllStores({ triggerSource: "failed_delivery_scan", historyDays: Number(req.body?.history_days || 40) });
    const count = await CentralOrderItem.countDocuments(failedDeliveryQuery());

    res.json({ success: true, message: "Failed delivery records scanned from all connected stores.", count, result });
  } catch (error) {
    res.status(500).json({ success: false, message: "Error scanning failed delivery orders", error: error.message });
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
    const { store_id, period, start, end, limit = 100 } = req.query;
    const effectivePeriod = period || (start || end ? "custom" : "all");
    const { startDate, endDate, dateQuery } = buildEventDateRangeQuery(["claim_date", "hub_arrived_at", "logistic_facility_at", "updatedAt", "createdAt"], { period: effectivePeriod, start, end });
    const baseQuery = returnOrClaimQuery();
    const query = Object.keys(dateQuery).length
      ? { $and: [baseQuery, dateQuery] }
      : baseQuery;
    if (store_id) query.store_id = store_id;

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ claim_date: -1, updatedAt: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    res.json({
      success: true,
      count: items.length,
      start_date: startDate,
      end_date: endDate,
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
    const { store_id, period, start, end, limit = 100 } = req.query;
    const effectivePeriod = period || (start || end ? "custom" : "all");
    const { startDate, endDate, dateQuery } = buildEventDateRangeQuery(["hub_arrived_at", "logistic_facility_at", "updatedAt", "createdAt"], { period: effectivePeriod, start, end });
    const baseQuery = failedDeliveryQuery();
    const query = Object.keys(dateQuery).length
      ? { $and: [baseQuery, dateQuery] }
      : baseQuery;
    if (store_id) query.store_id = store_id;

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ logistic_facility_at: -1, updatedAt: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    res.json({
      success: true,
      count: items.length,
      start_date: startDate,
      end_date: endDate,
      failed_deliveries: items.map(itemPayload)
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching failed delivery orders",
      error: error.message
    });
  }
});

router.post("/order-items/:id/mark-received", async (req, res) => {
  try {
    const result = await markOrderItemReceivedBack(req.params.id, { actor: req.body?.actor || 'admin' });
    res.json({ success: true, message: "Parcel marked as collected.", result });
  } catch (error) {
    res.status(400).json({ success: false, message: error.message || "Unable to mark parcel as collected", error: error.message });
  }
});

router.get("/cancelled-orders", async (req, res) => {
  try {
    const { store_id, period = "today", start, end, limit = 100 } = req.query;
    const { startDate, endDate } = resolveHistoryWindow({ period, start, end });
    const query = {
      $and: [
        cancelledQuery(),
        {
          $or: [
            { order_created_at: { $gte: startDate, $lte: endDate } },
            { updatedAt: { $gte: startDate, $lte: endDate } },
            { createdAt: { $gte: startDate, $lte: endDate } }
          ]
        }
      ]
    };
    if (store_id) query.store_id = store_id;

    const orders = await CentralOrder.find(query)
      .populate("store_id", "name code")
      .sort({ order_updated_at: -1, updatedAt: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    const enriched = await Promise.all(orders.map(enrichOrder));

    res.json({
      success: true,
      count: enriched.length,
      start_date: startDate,
      end_date: endDate,
      cancelled_orders: enriched
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching cancelled orders",
      error: error.message
    });
  }
});

router.get("/collection-watch", async (req, res) => {
  try {
    const { store_id, parcel_type, limit = 100, include_collected = "false" } = req.query;
    const query = {
      parcel_type: { $in: ["return", "failed_delivery"] },
      status_category: { $ne: "cancelled" }
    };
    if (store_id) query.store_id = store_id;
    if (parcel_type && ["return", "failed_delivery"].includes(parcel_type)) query.parcel_type = parcel_type;
    if (String(include_collected).toLowerCase() !== "true") {
      query.collection_status = { $nin: ["collected", "received", "scrapped", "expired"] };
    }

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ collection_action_required: -1, collection_deadline_at: 1, hub_arrived_at: -1, updatedAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    res.json({
      success: true,
      count: items.length,
      default_hub_name: orderRules.DEFAULT_COLLECTION_HUB_NAME,
      collection_deadline_days: orderRules.DEFAULT_COLLECTION_DEADLINE_DAYS,
      parcels: items.map(itemPayload)
    });
  } catch (error) {
    res.status(500).json({ success: false, message: "Error fetching collection watch records", error: error.message });
  }
});

router.get("/collection-alerts", async (req, res) => {
  try {
    const { store_id, limit = 50 } = req.query;
    const query = {
      parcel_type: { $in: ["return", "failed_delivery"] },
      collection_action_required: true,
      status_category: { $ne: "cancelled" }
    };
    if (store_id) query.store_id = store_id;

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ collection_deadline_at: 1, hub_arrived_at: -1 })
      .limit(Math.min(Number(limit) || 50, 200))
      .lean();

    const alerts = items.map(itemPayload).filter((item) => ["arrived", "three_days", "one_day", "deadline", "overdue"].includes(item.collection_notification_level));
    res.json({ success: true, count: alerts.length, alerts });
  } catch (error) {
    res.status(500).json({ success: false, message: "Error fetching collection alerts", error: error.message });
  }
});

router.post("/repair-classifications", async (req, res) => {
  try {
    const limit = Math.min(Number(req.body?.limit || 5000), 20000);
    const items = await CentralOrderItem.find({}).populate("order_id", "status status_category").limit(limit);
    let updated = 0;

    for (const item of items) {
      const classification = orderRules.classifyOrderItem({
        status: item.status,
        orderStatus: item.order_id?.status || "",
        returnReason: item.return_reason,
        claimDate: item.claim_date,
        hubArrivedAt: item.hub_arrived_at || item.logistic_facility_at,
        rawPayload: item.raw_payload || {}
      });
      const collectionStatus = orderRules.normalizeCollectionStatus({
        statusCategory: classification.statusCategory,
        parcelType: classification.parcelType,
        hubArrivedAt: item.hub_arrived_at || item.logistic_facility_at,
        existingStatus: item.collection_status
      });
      const deadline = (item.hub_arrived_at || item.logistic_facility_at) ? orderRules.addDays(item.hub_arrived_at || item.logistic_facility_at) : item.collection_deadline_at;
      item.status_category = orderRules.deriveFinalStatusCategory(classification.statusCategory, collectionStatus);
      item.parcel_type = classification.parcelType;
      item.revenue_countable = classification.revenueCountable && item.status_category === "active_sale";
      item.collection_status = collectionStatus;
      item.hub_name = item.hub_name || orderRules.DEFAULT_COLLECTION_HUB_NAME;
      item.hub_arrived_at = item.hub_arrived_at || item.logistic_facility_at || null;
      item.collection_deadline_at = deadline || null;
      item.days_left_to_collect = deadline ? orderRules.daysLeftUntil(deadline) : null;
      item.collection_action_required = orderRules.collectionActionRequired({ parcelType: item.parcel_type, hubArrivedAt: item.hub_arrived_at, collectionStatus });
      item.collection_notification_level = orderRules.collectionNotificationLevel({ collectionStatus, deadline, hubArrivedAt: item.hub_arrived_at });
      if (item.status_category === "cancelled") {
        item.collection_status = "not_required";
        item.collection_action_required = false;
        item.collection_notification_level = "none";
      }
      await item.save();
      updated += 1;
    }

    const orders = await CentralOrder.find({}).limit(limit);
    let ordersUpdated = 0;
    for (const order of orders) {
      const statusCategory = orderRules.classifyOrderStatus(order.status, order.raw_payload || {});
      order.status_category = statusCategory;
      order.revenue_countable = orderRules.shouldCountAsSale(order.status, statusCategory);
      await order.save();
      ordersUpdated += 1;
    }

    res.json({ success: true, message: "Order classifications repaired.", items_updated: updated, orders_updated: ordersUpdated });
  } catch (error) {
    res.status(500).json({ success: false, message: "Error repairing classifications", error: error.message });
  }
});

router.get("/orders-history", async (req, res) => {
  try {
    const { period = "today", store_id, status, start, end, limit = 100 } = req.query;
    const { startDate, endDate } = resolveHistoryWindow({ period, start, end });
    const orderQuery = { order_created_at: { $gte: startDate, $lte: endDate } };
    if (store_id) orderQuery.store_id = store_id;
    if (status) orderQuery.status = normalizeString(status).toLowerCase();

    const orders = await CentralOrder.find(orderQuery)
      .populate("store_id", "name code")
      .sort({ order_created_at: -1, createdAt: -1 })
      .limit(Math.min(Number(limit) || 100, 500))
      .lean();

    const orderIds = orders.map((order) => order._id);
    const items = await CentralOrderItem.find({ order_id: { $in: orderIds } }).lean();
    const orderMap = new Map(orders.map((order) => [String(order._id), order]));
    const saleItems = items.filter((item) => orderRules.itemMatchesSale(item, orderMap.get(String(item.order_id)) || {}));
    const saleOrderIds = new Set(saleItems.map((item) => String(item.order_id)));
    const saleOrders = orders.filter((order) => saleOrderIds.has(String(order._id)) || (order.revenue_countable && order.status_category === "active_sale"));

    const revenue = saleItems.reduce((sum, item) => sum + toNumber(item.unit_price, 0) * toNumber(item.quantity, 1), 0);
    const revenueAvailable = saleItems.some((item) => toNumber(item.unit_price, 0) > 0);
    const totalCost = saleItems.reduce((sum, item) => sum + toNumber(item.cost_price, 0) * toNumber(item.quantity, 1), 0);
    const profitAvailable = saleItems.some((item) => toNumber(item.cost_price, 0) > 0);
    const profit = profitAvailable ? revenue - totalCost : (revenue > 0 ? revenue : 0);
    const profitMargin = (profitAvailable && revenue > 0)
      ? Number((((revenue - totalCost) / revenue) * 100).toFixed(2))
      : (revenue > 0 && totalCost === 0 ? 100 : 0);

    const eventDateQuery = {
      $or: [
        { claim_date: { $gte: startDate, $lte: endDate } },
        { hub_arrived_at: { $gte: startDate, $lte: endDate } },
        { logistic_facility_at: { $gte: startDate, $lte: endDate } },
        { updatedAt: { $gte: startDate, $lte: endDate } },
        { createdAt: { $gte: startDate, $lte: endDate } }
      ]
    };
    const returnCountQuery = { $and: [returnOrClaimQuery(), eventDateQuery] };
    const failedCountQuery = { $and: [failedDeliveryQuery(), eventDateQuery] };
    const cancelledCountQuery = {
      $and: [
        cancelledQuery(),
        {
          $or: [
            { order_created_at: { $gte: startDate, $lte: endDate } },
            { updatedAt: { $gte: startDate, $lte: endDate } },
            { createdAt: { $gte: startDate, $lte: endDate } }
          ]
        }
      ]
    };
    if (store_id) {
      returnCountQuery.store_id = store_id;
      failedCountQuery.store_id = store_id;
      cancelledCountQuery.store_id = store_id;
    }

    const [returns, failedDeliveries, cancelledOrders] = await Promise.all([
      CentralOrderItem.countDocuments(returnCountQuery),
      CentralOrderItem.countDocuments(failedCountQuery),
      CentralOrder.countDocuments(cancelledCountQuery)
    ]);

    const seriesMap = new Map();
    for (const order of saleOrders) {
      const key = new Date(order.order_created_at || order.createdAt).toISOString().slice(0, 10);
      if (!seriesMap.has(key)) seriesMap.set(key, { date: key, orders: 0, revenue: 0, cost: 0, profit: 0, profit_margin: 0 });
      seriesMap.get(key).orders += 1;
    }
    for (const item of saleItems) {
      const order = orderMap.get(String(item.order_id));
      const key = new Date(order?.order_created_at || item.createdAt).toISOString().slice(0, 10);
      if (!seriesMap.has(key)) seriesMap.set(key, { date: key, orders: 0, revenue: 0, cost: 0, profit: 0, profit_margin: 0 });
      const itemRev = toNumber(item.unit_price, 0) * toNumber(item.quantity, 1);
      const itemCost = toNumber(item.cost_price, 0) * toNumber(item.quantity, 1);
      const row = seriesMap.get(key);
      row.revenue += itemRev;
      row.cost += itemCost;
      row.profit += (itemRev - itemCost);
      row.profit_margin = row.revenue > 0 ? Number(((row.profit / row.revenue) * 100).toFixed(2)) : 0;
    }

    const enriched = await Promise.all(saleOrders.map(enrichOrder));

    res.json({
      success: true,
      period,
      start_date: startDate,
      end_date: endDate,
      summary: {
        total_orders: saleOrders.length,
        revenue,
        revenue_available: revenueAvailable,
        total_cost: totalCost,
        profit,
        profit_margin: profitMargin,
        profit_available: profitAvailable,
        returns,
        failed_deliveries: failedDeliveries,
        cancelled_orders: cancelledOrders,
        excluded_cancelled_from_sales: true
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
