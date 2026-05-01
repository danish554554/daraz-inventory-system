const Store = require('../models/Store');
const CentralInventory = require('../models/CentralInventory');
const CentralOrder = require('../models/CentralOrder');
const StoreToken = require('../models/StoreToken');
const CentralOrderItem = require('../models/CentralOrderItem');
const InventoryTransaction = require('../models/InventoryTransaction');
const StoreSyncLog = require('../models/StoreSyncLog');
const { getOrders, getOrderItems } = require('./darazApiService');
const { ensureStoreTokenReadyForSync, isLiveApiEnabled } = require('./darazService');
const { upsertOrderItemIssue, resolveIssueByOrderItem, resolveIssueByStoreSku } = require('./syncIssueService');

let syncInProgress = false;

const STATUS_RANK = {
  created: 1,
  pending: 1,
  unpaid: 1,
  packed: 2,
  ready_to_ship: 3,
  shipped: 4,
  delivered: 5,
  completed: 5,
  canceled: -1,
  cancelled: -1,
  failed: -1,
  returned: -2,
  closed: -2
};

function safeString(value) {
  return (value || '').toString().trim();
}

function safeNumber(value, fallback = 0) {
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

function normalizeStatus(value) {
  return safeString(value).toLowerCase().replace(/[\s-]+/g, '_');
}

function statusReached(currentStatus, targetStatus) {
  const current = STATUS_RANK[normalizeStatus(currentStatus)] || 0;
  const target = STATUS_RANK[normalizeStatus(targetStatus)] || 0;
  return current >= target;
}

function isCanceledStatus(status) {
  return ['canceled', 'cancelled', 'failed', 'returned', 'closed'].includes(normalizeStatus(status));
}

function isReturnStatus(status = '') {
  const normalized = normalizeStatus(status);
  return ['return', 'returned', 'returning', 'refund', 'refunded', 'claim', 'claimed'].some((key) => normalized.includes(key));
}

function isFailedDeliveryStatus(status = '') {
  const normalized = normalizeStatus(status);
  return normalized.includes('failed_delivery') ||
    normalized.includes('delivery_failed') ||
    normalized.includes('undelivered') ||
    normalized.includes('returned_to_shipper') ||
    normalized.includes('return_to_shipper') ||
    normalized.includes('return_to_seller') ||
    normalized.includes('failed');
}

function getOrderId(order) {
  return safeString(order?.order_id || order?.orderId || order?.id || order?.order_number);
}

function getOrderStatus(order) {
  return safeString(order?.statuses?.[0] || order?.status || order?.order_status);
}

function getOrderNumber(order) {
  return safeString(order?.order_number || order?.orderNumber || order?.order_id);
}

function getOrderCreatedAt(order) {
  return toDate(order?.created_at) || toDate(order?.created_time) || toDate(order?.date_created) || null;
}

function getOrderUpdatedAt(order) {
  return toDate(order?.updated_at) || toDate(order?.updated_time) || toDate(order?.date_updated) || null;
}

function getOrderItemId(item) {
  return safeString(item?.order_item_id || item?.orderItemId || item?.item_id || item?.id);
}

function getItemSellerSku(item) {
  return safeString(item?.seller_sku || item?.sku || item?.shop_sku || item?.sellerSku);
}

function getItemStatus(item, orderStatus) {
  const status = safeString(
    item?.status ||
      item?.order_item_status ||
      item?.shipment_status ||
      item?.logistics_status ||
      item?.delivery_status ||
      item?.return_status ||
      item?.statuses?.[0] ||
      orderStatus
  );
  return status;
}

function getItemName(item) {
  return safeString(item?.name || item?.product_name || item?.item_name || item?.title);
}

function getItemQuantity(item) {
  return safeNumber(item?.quantity || item?.qty || item?.item_quantity || 1, 1);
}

function getItemPrice(item) {
  const quantity = getItemQuantity(item);
  const unit = safeNumber(
    item?.paid_price ??
      item?.unit_price ??
      item?.item_price ??
      item?.sku_price ??
      item?.price ??
      item?.sale_price ??
      item?.product_price ??
      item?.original_price,
    NaN
  );
  if (Number.isFinite(unit) && unit > 0) return unit;

  const total = safeNumber(
    item?.amount ??
      item?.total_amount ??
      item?.paid_amount ??
      item?.order_amount ??
      item?.item_total ??
      item?.row_total ??
      item?.subtotal,
    0
  );
  return total > 0 && quantity > 0 ? total / quantity : 0;
}


function hasNonLatin(text = '') {
  return /[^\u0000-\u007f]/.test(safeString(text));
}

function buildDisplayTitle(title = '', sku = '') {
  const cleanTitle = safeString(title);
  if (cleanTitle && !hasNonLatin(cleanTitle)) return cleanTitle;
  const skuText = safeString(sku).replace(/[_-]+/g, ' ').replace(/\s+/g, ' ').trim();
  return skuText || cleanTitle || 'Daraz Product';
}

function getItemEnglishTitle(item = {}) {
  return safeString(
    item?.display_title ||
      item?.english_title ||
      item?.title_en ||
      item?.name_en ||
      item?.product_name_en
  );
}

function normalizeImageValue(value) {
  if (!value) return '';
  if (typeof value === 'string') return safeString(value);
  if (Array.isArray(value)) {
    for (const entry of value) {
      const url = normalizeImageValue(entry);
      if (url) return url;
    }
  }
  if (typeof value === 'object') {
    return safeString(value.url || value.image_url || value.image || value.src || value.main_image || value.thumbnail || value.large || value.medium);
  }
  return '';
}

function getItemImage(item = {}) {
  return normalizeImageValue(
    item?.main_image ||
      item?.primary_image ||
      item?.image_url ||
      item?.product_image ||
      item?.image ||
      item?.thumbnail ||
      item?.images ||
      item?.Images ||
      item?.product_images
  );
}

function getReturnReason(item = {}) {
  return safeString(
    item?.return_reason ||
      item?.returnReason ||
      item?.reason ||
      item?.reason_detail ||
      item?.cancel_reason ||
      item?.buyer_note ||
      item?.seller_note
  );
}

function getClaimDate(item = {}) {
  return toDate(item?.claim_date) ||
    toDate(item?.return_claim_date) ||
    toDate(item?.return_initiated_at) ||
    toDate(item?.return_created_at) ||
    toDate(item?.refund_created_at) ||
    toDate(item?.updated_at) ||
    null;
}

function getLogisticFacilityDate(item = {}) {
  return toDate(item?.logistic_facility_at) ||
    toDate(item?.failed_delivery_received_at) ||
    toDate(item?.collection_ready_at) ||
    toDate(item?.returned_to_shipper_at) ||
    toDate(item?.return_to_seller_at) ||
    toDate(item?.updated_at) ||
    null;
}

function makeSyncWindow(lastSyncAt) {
  if (!lastSyncAt) return new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  return new Date(new Date(lastSyncAt).getTime() - 10 * 60 * 1000).toISOString();
}

async function resolveCentralInventory({ store, sellerSku, productName = '', displayTitle = '', imageUrl = '' }) {
  const normalizedSku = safeString(sellerSku);
  if (!normalizedSku) return null;

  const cleanProductName = safeString(productName) || normalizedSku;
  const cleanDisplayTitle = safeString(displayTitle) || buildDisplayTitle(cleanProductName, normalizedSku);
  const setUpdate = {};
  if (cleanProductName) setUpdate.product_name = cleanProductName;
  if (cleanProductName) setUpdate.original_product_name = cleanProductName;
  if (cleanDisplayTitle) setUpdate.display_title = cleanDisplayTitle;
  if (safeString(imageUrl)) setUpdate.image_url = safeString(imageUrl);

  const inventory = await CentralInventory.findOneAndUpdate(
    { store_id: store._id, seller_sku: normalizedSku },
    {
      $setOnInsert: {
        store_id: store._id,
        seller_sku: normalizedSku,
        product_name: cleanProductName,
        original_product_name: cleanProductName,
        display_title: cleanDisplayTitle,
        image_url: safeString(imageUrl),
        stock: 0,
        reserved_stock: 0,
        low_stock_limit: 5
      },
      $set: setUpdate
    },
    { upsert: true, new: true }
  );

  return inventory;
}

async function createInventoryTransaction({
  store_id,
  inventory,
  seller_sku,
  product_name,
  order_id = null,
  order_item_id = null,
  external_order_id = '',
  external_order_item_id = '',
  transaction_type,
  quantity,
  stock_before,
  stock_after,
  note = ''
}) {
  await InventoryTransaction.create({
    store_id,
    inventory_id: inventory?._id || null,
    seller_sku,
    master_sku: seller_sku,
    product_name: product_name || inventory?.product_name || seller_sku,
    order_id,
    order_item_id,
    external_order_id,
    external_order_item_id,
    transaction_type,
    quantity,
    stock_before,
    stock_after,
    note
  });
}

async function deductStockForOrderItem({ store, orderDoc, itemDoc, stats }) {
  if (itemDoc.stock_deducted) {
    itemDoc.processing_status = 'deducted';
    await itemDoc.save();
    await resolveIssueByOrderItem(itemDoc._id, 'Already deducted earlier');
    stats.skipped += 1;
    return { action: 'already_deducted' };
  }

  const effectiveStatus = itemDoc.status || orderDoc.status || '';
  if (!statusReached(effectiveStatus, store.deduct_stage)) {
    itemDoc.processing_status = 'pending';
    await itemDoc.save();
    stats.skipped += 1;
    return { action: 'waiting_stage' };
  }

  if (isCanceledStatus(effectiveStatus)) {
    itemDoc.processing_status = 'skipped';
    await itemDoc.save();
    stats.skipped += 1;
    return { action: 'canceled_skip' };
  }

  const inventory = await resolveCentralInventory({ store, sellerSku: itemDoc.seller_sku, productName: itemDoc.product_name, displayTitle: itemDoc.display_title, imageUrl: itemDoc.image_url });
  const qty = safeNumber(itemDoc.quantity, 1);

  if ((inventory.stock || 0) < qty) {
    itemDoc.mapping_status = 'mapped';
    itemDoc.processing_status = 'failed';
    itemDoc.error_message = 'Insufficient internal central inventory';
    await itemDoc.save();

    await upsertOrderItemIssue({
      issueType: 'insufficient_stock',
      store,
      orderDoc,
      itemDoc,
      message: itemDoc.error_message,
      quantityNeeded: qty,
      availableStock: inventory.stock || 0
    });
    stats.failed += 1;
    return { action: 'insufficient_stock' };
  }

  const stockBefore = inventory.stock || 0;
  inventory.stock = stockBefore - qty;
  await inventory.save();

  itemDoc.mapping_status = 'mapped';
  itemDoc.stock_deducted = true;
  itemDoc.processing_status = 'deducted';
  itemDoc.deduction_applied_at = new Date();
  itemDoc.error_message = '';
  await itemDoc.save();

  await createInventoryTransaction({
    store_id: store._id,
    inventory,
    seller_sku: itemDoc.seller_sku,
    product_name: itemDoc.product_name,
    order_id: orderDoc._id,
    order_item_id: itemDoc._id,
    external_order_id: orderDoc.external_order_id,
    external_order_item_id: itemDoc.external_order_item_id,
    transaction_type: 'order_deduct',
    quantity: qty,
    stock_before: stockBefore,
    stock_after: inventory.stock,
    note: `Daraz order deduction for order ${orderDoc.external_order_id}`
  });

  await resolveIssueByOrderItem(itemDoc._id, 'Deduction completed successfully');
  await resolveIssueByStoreSku(store._id, itemDoc.seller_sku, 'Issue cleared after successful deduction');
  stats.deducted += 1;
  return { action: 'deducted' };
}

async function restoreStockForCanceledItem({ store, orderDoc, itemDoc, stats }) {
  if (!itemDoc.stock_deducted || itemDoc.stock_restored) {
    stats.skipped += 1;
    return { action: 'restore_not_required' };
  }

  const effectiveStatus = itemDoc.status || orderDoc.status || '';
  if (!isCanceledStatus(effectiveStatus)) {
    stats.skipped += 1;
    return { action: 'not_canceled' };
  }

  const inventory = await resolveCentralInventory({ store, sellerSku: itemDoc.seller_sku, productName: itemDoc.product_name, displayTitle: itemDoc.display_title, imageUrl: itemDoc.image_url });
  if (!inventory) {
    itemDoc.processing_status = 'failed';
    itemDoc.error_message = 'Central inventory not found for restore';
    await itemDoc.save();
    stats.failed += 1;
    return { action: 'inventory_missing' };
  }

  const qty = safeNumber(itemDoc.quantity, 1);
  const stockBefore = inventory.stock || 0;
  inventory.stock = stockBefore + qty;
  await inventory.save();

  itemDoc.mapping_status = 'mapped';
  itemDoc.stock_restored = true;
  itemDoc.processing_status = 'restored';
  itemDoc.restoration_applied_at = new Date();
  itemDoc.error_message = '';
  await itemDoc.save();

  await createInventoryTransaction({
    store_id: store._id,
    inventory,
    seller_sku: itemDoc.seller_sku,
    product_name: itemDoc.product_name,
    order_id: orderDoc._id,
    order_item_id: itemDoc._id,
    external_order_id: orderDoc.external_order_id,
    external_order_item_id: itemDoc.external_order_item_id,
    transaction_type: 'cancel_restore',
    quantity: qty,
    stock_before: stockBefore,
    stock_after: inventory.stock,
    note: `Daraz order restore for order ${orderDoc.external_order_id}`
  });

  await resolveIssueByOrderItem(itemDoc._id, 'Restore completed successfully');
  stats.restored += 1;
  return { action: 'restored' };
}

async function upsertOrder(store, orderPayload) {
  const externalOrderId = getOrderId(orderPayload);
  if (!externalOrderId) return null;

  const update = {
    order_number: getOrderNumber(orderPayload),
    status: getOrderStatus(orderPayload) || 'pending',
    order_created_at: getOrderCreatedAt(orderPayload),
    order_updated_at: getOrderUpdatedAt(orderPayload),
    synced_at: new Date(),
    raw_payload: orderPayload
  };

  return CentralOrder.findOneAndUpdate(
    { store_id: store._id, external_order_id: externalOrderId },
    {
      $set: update,
      $setOnInsert: {
        store_id: store._id,
        external_order_id: externalOrderId,
        inventory_processed_at: null,
        inventory_restored_at: null,
        processing_status: 'pending'
      }
    },
    { upsert: true, new: true }
  );
}

async function upsertOrderItems(store, orderDoc, itemsPayload, stats) {
  for (const item of itemsPayload) {
    const externalOrderItemId = getOrderItemId(item);
    if (!externalOrderItemId) continue;

    const sellerSku = getItemSellerSku(item);
    const productName = getItemName(item);
    const displayTitle = getItemEnglishTitle(item) || buildDisplayTitle(productName, sellerSku);
    const imageUrl = getItemImage(item);
    const itemStatus = getItemStatus(item, orderDoc.status) || orderDoc.status || 'pending';
    const returnReason = getReturnReason(item);
    const claimDate = getClaimDate(item);
    const logisticFacilityAt = getLogisticFacilityDate(item);
    const needsCollection = isFailedDeliveryStatus(itemStatus) || normalizeStatus(item?.collection_status).includes('needs_collection') || !!logisticFacilityAt && isFailedDeliveryStatus(itemStatus);
    const inventory = sellerSku ? await resolveCentralInventory({ store, sellerSku, productName, displayTitle, imageUrl }) : null;

    await CentralOrderItem.findOneAndUpdate(
      { store_id: store._id, external_order_item_id: externalOrderItemId },
      {
        $set: {
          order_id: orderDoc._id,
          seller_sku: sellerSku,
          product_name: productName,
          original_product_name: productName,
          display_title: displayTitle,
          image_url: imageUrl,
          quantity: getItemQuantity(item),
          unit_price: getItemPrice(item),
          status: itemStatus,
          return_reason: returnReason,
          claim_date: isReturnStatus(itemStatus) || returnReason ? claimDate : null,
          logistic_facility_at: needsCollection ? logisticFacilityAt : null,
          collection_status: needsCollection ? 'needs_collection' : 'pending',
          raw_payload: item,
          product_id: null,
          mapping_status: inventory ? 'mapped' : 'unmapped'
        },
        $setOnInsert: {
          stock_deducted: false,
          stock_restored: false,
          deduction_applied_at: null,
          restoration_applied_at: null,
          processing_status: 'pending',
          error_message: ''
        }
      },
      { upsert: true, new: true }
    );

    stats.items_upserted += 1;
  }
}

async function processOrderInventory(store, orderDoc, stats) {
  const items = await CentralOrderItem.find({ order_id: orderDoc._id }).sort({ createdAt: 1 });

  let deductedCount = 0;
  let restoredCount = 0;
  let failedCount = 0;

  for (const itemDoc of items) {
    if (store.restore_on_cancel && isCanceledStatus(itemDoc.status || orderDoc.status)) {
      const restoreResult = await restoreStockForCanceledItem({ store, orderDoc, itemDoc, stats });
      if (restoreResult.action === 'restored') restoredCount += 1;
      if (['inventory_missing'].includes(restoreResult.action)) failedCount += 1;
      continue;
    }

    const deductResult = await deductStockForOrderItem({ store, orderDoc, itemDoc, stats });
    if (deductResult.action === 'deducted') deductedCount += 1;
    if (['inventory_missing', 'insufficient_stock'].includes(deductResult.action)) failedCount += 1;
  }

  if (failedCount > 0) {
    orderDoc.processing_status = 'failed';
  } else if (restoredCount > 0) {
    orderDoc.processing_status = 'restored';
    orderDoc.inventory_restored_at = new Date();
  } else if (deductedCount > 0) {
    orderDoc.processing_status = 'deducted';
    orderDoc.inventory_processed_at = new Date();
  } else {
    orderDoc.processing_status = 'pending';
  }

  await orderDoc.save();
}

async function writeSyncLog({ store, triggerSource = 'manual', startedAt, success, summaryMessage, stats, warnings = [], errors = [] }) {
  const finishedAt = new Date();
  await StoreSyncLog.create({
    store_id: store._id,
    trigger_source: triggerSource,
    sync_started_at: startedAt,
    sync_finished_at: finishedAt,
    duration_ms: finishedAt.getTime() - startedAt.getTime(),
    success,
    summary_message: summaryMessage,
    token_ready: success,
    orders_seen: stats.orders_seen,
    orders_upserted: stats.orders_upserted,
    items_seen: stats.items_seen,
    items_upserted: stats.items_upserted,
    deducted: stats.deducted,
    restored: stats.restored,
    skipped: stats.skipped,
    failed: stats.failed,
    warnings,
    errors
  });
}

async function syncStoreOrders(store, options = {}) {
  const startedAt = new Date();
  const triggerSource = options.triggerSource || 'manual';
  const stats = {
    orders_seen: 0,
    orders_upserted: 0,
    items_seen: 0,
    items_upserted: 0,
    deducted: 0,
    restored: 0,
    skipped: 0,
    failed: 0
  };

  try {
    const tokenReady = await ensureStoreTokenReadyForSync(store._id);

    if (!tokenReady?.ok) {
      throw new Error(tokenReady?.message || "Store access token is missing");
    }

    const storeToken = tokenReady.token || await StoreToken.findOne({ store_id: store._id });

    if (!storeToken || !storeToken.access_token) {
      throw new Error("Store access token is missing");
    }

    const since = makeSyncWindow(store.last_sync_at);
    const ordersResponse = await getOrders({ storeToken, updatedAfter: since });
    const orders = Array.isArray(ordersResponse)
      ? ordersResponse
      : ordersResponse?.orders || ordersResponse?.data || [];
    stats.orders_seen = orders.length;

    for (const orderPayload of orders) {
      const orderDoc = await upsertOrder(store, orderPayload);
      if (!orderDoc) continue;
      stats.orders_upserted += 1;

      const orderItemsResponse = await getOrderItems({
        storeToken,
        orderId: orderDoc.external_order_id
      });
      const itemsPayload = Array.isArray(orderItemsResponse)
        ? orderItemsResponse
        : orderItemsResponse?.items || orderItemsResponse?.data || [];
      stats.items_seen += itemsPayload.length;
      await upsertOrderItems(store, orderDoc, itemsPayload, stats);
      await processOrderInventory(store, orderDoc, stats);
    }

    const finishedAt = new Date();
    store.last_sync_at = finishedAt;
    store.last_sync_status = 'success';
    store.last_sync_message = `Processed ${stats.orders_upserted} orders, ${stats.deducted} deductions, ${stats.restored} restores`;
    await store.save();
    await StoreToken.updateOne({ store_id: store._id }, { $set: { last_sync_at: finishedAt, last_error: '' } });

    await writeSyncLog({
      store,
      triggerSource,
      startedAt,
      success: true,
      summaryMessage: store.last_sync_message,
      stats
    });

    return { processed: stats.orders_upserted, ...stats };
  } catch (error) {
    const finishedAt = new Date();
    store.last_sync_at = finishedAt;
    store.last_sync_status = 'failed';
    store.last_sync_message = error.message;
    await store.save();
    await StoreToken.updateOne({ store_id: store._id }, { $set: { last_sync_at: finishedAt, last_error: error.message } });

    await writeSyncLog({
      store,
      triggerSource,
      startedAt,
      success: false,
      summaryMessage: error.message,
      stats,
      errors: [error.message]
    });

    throw error;
  }
}

async function retryFailedOrderItemById(orderItemId) {
  const itemDoc = await CentralOrderItem.findById(orderItemId);
  if (!itemDoc) throw new Error('Order item not found');

  const [store, orderDoc] = await Promise.all([
    Store.findById(itemDoc.store_id),
    CentralOrder.findById(itemDoc.order_id)
  ]);

  if (!store || !orderDoc) throw new Error('Related store or order not found');

  const stats = { deducted: 0, restored: 0, skipped: 0, failed: 0, orders_seen: 0, orders_upserted: 0, items_seen: 0, items_upserted: 0 };

  if (store.restore_on_cancel && isCanceledStatus(itemDoc.status || orderDoc.status)) {
    const result = await restoreStockForCanceledItem({ store, orderDoc, itemDoc, stats });
    return { action: result.action, item_id: itemDoc._id, seller_sku: itemDoc.seller_sku };
  }

  const result = await deductStockForOrderItem({ store, orderDoc, itemDoc, stats });
  return { action: result.action, item_id: itemDoc._id, seller_sku: itemDoc.seller_sku };
}

async function syncStoreById(storeId, options = {}) {
  if (syncInProgress && !options.allowWhileRunning) {
    throw new Error('Sync is already running');
  }

  const store = await Store.findById(storeId);
  if (!store) throw new Error('Store not found');

  syncInProgress = true;
  try {
    return await syncStoreOrders(store, options);
  } finally {
    syncInProgress = false;
  }
}

async function syncAllStores(options = {}) {
  if (syncInProgress) {
    return { skipped: true, message: 'Sync already in progress' };
  }

  if (!isLiveApiEnabled()) {
    return { skipped: true, message: 'Live Daraz API sync is disabled in environment' };
  }

  syncInProgress = true;
  try {
    const stores = await Store.find({ status: 'active' }).sort({ createdAt: 1 });
    const results = [];

    for (const store of stores) {
      try {
        const result = await syncStoreOrders(store, options);
        results.push({ store_id: store._id, store_name: store.name, ...result });
      } catch (error) {
        results.push({ store_id: store._id, store_name: store.name, error: error.message });
      }
    }

    return { skipped: false, results };
  } finally {
    syncInProgress = false;
  }
}

function getSyncLockState() {
  return { syncInProgress };
}

module.exports = {
  syncAllStores,
  syncStoreById,
  retryFailedOrderItemById,
  resolveCentralInventory,
  getSyncLockState
};
