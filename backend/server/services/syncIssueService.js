const SyncIssue = require("../models/SyncIssue");

function safeString(value) {
  return String(value || "").trim();
}

function safeNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

async function upsertOrderItemIssue({
  issueType,
  store,
  orderDoc,
  itemDoc,
  product = null,
  message = "",
  quantityNeeded = 0,
  availableStock = 0
}) {
  const sellerSku = safeString(itemDoc?.seller_sku);
  if (!store?._id || !sellerSku || !issueType) return null;

  const now = new Date();
  const update = {
    store_id: store._id,
    order_id: orderDoc?._id || null,
    order_item_id: itemDoc?._id || null,
    product_id: product?._id || itemDoc?.product_id || null,
    issue_type: issueType,
    status: "open",
    seller_sku: sellerSku,
    product_name: safeString(itemDoc?.product_name || product?.name),
    master_sku: safeString(product?.sku),
    external_order_id: safeString(orderDoc?.external_order_id),
    external_order_item_id: safeString(itemDoc?.external_order_item_id),
    quantity_needed: Math.max(0, safeNumber(quantityNeeded, itemDoc?.quantity || 0)),
    available_stock: Math.max(0, safeNumber(availableStock, product?.stock || 0)),
    shortage_qty: Math.max(0, safeNumber(quantityNeeded, itemDoc?.quantity || 0) - safeNumber(availableStock, product?.stock || 0)),
    last_message: safeString(message),
    last_seen_at: now,
    resolved_at: null,
    resolved_note: ""
  };

  const existing = await SyncIssue.findOne({
    store_id: store._id,
    seller_sku: sellerSku,
    issue_type: issueType,
    status: "open"
  });

  if (!existing) {
    return SyncIssue.create({
      ...update,
      first_seen_at: now,
      occurrences: 1
    });
  }

  existing.order_id = update.order_id;
  existing.order_item_id = update.order_item_id;
  existing.product_id = update.product_id;
  existing.product_name = update.product_name;
  existing.master_sku = update.master_sku;
  existing.external_order_id = update.external_order_id;
  existing.external_order_item_id = update.external_order_item_id;
  existing.quantity_needed = update.quantity_needed;
  existing.available_stock = update.available_stock;
  existing.shortage_qty = update.shortage_qty;
  existing.last_message = update.last_message;
  existing.last_seen_at = update.last_seen_at;
  existing.occurrences = safeNumber(existing.occurrences, 1) + 1;
  existing.resolved_at = null;
  existing.resolved_note = "";
  existing.status = "open";
  return existing.save();
}

async function resolveIssueByOrderItem(orderItemId, note = "Auto resolved after retry success") {
  if (!orderItemId) return;

  await SyncIssue.updateMany(
    { order_item_id: orderItemId, status: "open" },
    {
      $set: {
        status: "resolved",
        resolved_at: new Date(),
        resolved_note: safeString(note)
      }
    }
  );
}

async function resolveIssueByStoreSku(storeId, sellerSku, note = "Resolved") {
  if (!storeId || !sellerSku) return;

  await SyncIssue.updateMany(
    { store_id: storeId, seller_sku: safeString(sellerSku), status: "open" },
    {
      $set: {
        status: "resolved",
        resolved_at: new Date(),
        resolved_note: safeString(note)
      }
    }
  );
}

module.exports = {
  upsertOrderItemIssue,
  resolveIssueByOrderItem,
  resolveIssueByStoreSku
};
