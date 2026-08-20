const Store = require('../models/Store');
const CentralInventory = require('../models/CentralInventory');
const { resolveStockTarget, updateTargetStock } = require('./inventoryStockTargetService');
const CentralOrder = require('../models/CentralOrder');
const StoreToken = require('../models/StoreToken');
const CentralOrderItem = require('../models/CentralOrderItem');
const InventoryTransaction = require('../models/InventoryTransaction');
const StoreSyncLog = require('../models/StoreSyncLog');
const { getOrders, getOrderItems } = require('./darazApiService');
const { ensureStoreTokenReadyForSync, isLiveApiEnabled } = require('./darazService');
const { upsertOrderItemIssue, resolveIssueByOrderItem, resolveIssueByStoreSku } = require('./syncIssueService');
const orderRules = require('../utils/orderClassification');

let syncInProgress = false;

const STATUS_RANK = {
  created: 1,
  confirmed: 1,
  pending: 1,
  unpaid: 1,
  processing: 2,
  processed: 2,
  packed: 2,
  packed_by_marketplace: 2,
  ready_to_ship_pending: 3,
  ready_to_ship: 3,
  shipped: 4,
  shipped_back: 4,
  delivered: 5,
  completed: 5,
  canceled: -1,
  cancelled: -1,
  failed: -1,
  returned: -2,
  closed: -2,
  return: -2,
  refund: -2,
  failed_delivery: -2,
  delivery_failed: -2,
  undelivered: -2,
  returned_to_shipper: -2,
  return_to_seller: -2
};

function safeString(value) {
  return (value || '').toString().trim();
}

function safeNumber(value, fallback = 0) {
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
  return orderRules.isCancelledStatus(status);
}

function isReturnOrFailedStatus(status, payload = {}) {
  return orderRules.isReturnStatus(status, payload) || orderRules.isFailedDeliveryStatus(status, payload);
}

function isNonDeductibleCategory(category) {
  return ['cancelled', 'return', 'failed_delivery', 'collected', 'scrapped'].includes(normalizeStatus(category));
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
  return safeString(item?.status || item?.order_item_status || orderStatus);
}

function getItemName(item) {
  return safeString(item?.name || item?.product_name || item?.item_name || item?.title);
}

function getItemQuantity(item) {
  return safeNumber(item?.quantity || item?.qty || item?.item_quantity || 1, 1);
}

function getItemPrice(item) {
  return safeNumber(item?.paid_price || item?.unit_price || item?.price || item?.item_price || 0, 0);
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
  return safeString(item?.return_reason || item?.reason || item?.cancel_reason || item?.buyer_note || item?.seller_note);
}

function getClaimDate(item = {}) {
  return toDate(item?.claim_date) || toDate(item?.return_claim_date) || toDate(item?.return_initiated_at) || null;
}

function getLogisticFacilityDate(item = {}) {
  return toDate(item?.hub_arrived_at) ||
    toDate(item?.logistic_facility_at) ||
    toDate(item?.failed_delivery_received_at) ||
    toDate(item?.return_received_at) ||
    toDate(item?.return_arrived_at) ||
    toDate(item?.arrived_at_hub) ||
    toDate(item?.arrived_at_facility) ||
    toDate(item?.return_to_seller_received_at) ||
    toDate(item?.rts_received_at) ||
    toDate(item?.scrap_countdown_started_at) ||
    null;
}

function getHubName(item = {}) {
  return safeString(
    item?.hub_name ||
      item?.return_hub_name ||
      item?.center_name ||
      item?.facility_name ||
      item?.logistic_facility_name ||
      item?.warehouse_name ||
      item?.current_location ||
      item?.dropoff_location
  ) || orderRules.DEFAULT_COLLECTION_HUB_NAME;
}

function makeSyncWindow(lastSyncAt) {
  if (!lastSyncAt) return new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  return new Date(new Date(lastSyncAt).getTime() - 10 * 60 * 1000).toISOString();
}

function statusesForTrigger(triggerSource = '') {
  const source = safeString(triggerSource).toLowerCase();
  if (source.includes('return')) {
    return [null, 'returned', 'return', 'refund', 'shipped_back', 'return_to_seller'];
  }
  if (source.includes('failed')) {
    return [null, 'failed_delivery', 'delivery_failed', 'undelivered', 'return_to_seller', 'returned_to_shipper', 'shipped_back'];
  }
  return [null];
}

function makeStatusScanWindow(triggerSource = '', lastSyncAt = null, historyDays = 30) {
  const source = safeString(triggerSource).toLowerCase();
  if (source.includes('return') || source.includes('failed')) {
    const days = Math.min(Math.max(Number(historyDays) || 30, 1), 180);
    return new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  }
  return makeSyncWindow(lastSyncAt);
}

function syncKindForTrigger(triggerSource = '') {
  const source = safeString(triggerSource).toLowerCase();
  if (source.includes('return')) return 'return_scan';
  if (source.includes('failed')) return 'failed_delivery_scan';
  return 'orders';
}

function buildSuccessMessage(triggerSource, stats) {
  const kind = syncKindForTrigger(triggerSource);
  if (kind === 'return_scan') {
    return `Return scan processed ${stats.orders_upserted} orders and ${stats.items_upserted} items`;
  }
  if (kind === 'failed_delivery_scan') {
    return `Failed-delivery scan processed ${stats.orders_upserted} orders and ${stats.items_upserted} items`;
  }
  return `Processed ${stats.orders_upserted} orders, ${stats.deducted} deductions, ${stats.restored} restores`;
}

function buildStoreSuccessUpdate(triggerSource, startedAt, finishedAt, summaryMessage) {
  const kind = syncKindForTrigger(triggerSource);
  const update = {
    last_sync_attempt_at: startedAt,
    last_sync_status: 'success',
    last_sync_message: summaryMessage
  };

  if (kind === 'return_scan') {
    update.last_return_scan_attempt_at = startedAt;
    update.last_return_scan_at = finishedAt;
  } else if (kind === 'failed_delivery_scan') {
    update.last_failed_delivery_scan_attempt_at = startedAt;
    update.last_failed_delivery_scan_at = finishedAt;
  } else {
    update.last_sync_at = finishedAt;
    update.last_success_sync_at = finishedAt;
  }

  return update;
}

function buildTokenSuccessUpdate(triggerSource, startedAt, finishedAt) {
  const kind = syncKindForTrigger(triggerSource);
  const update = {
    last_sync_attempt_at: startedAt,
    last_error: ''
  };

  if (kind === 'return_scan') {
    update.last_return_scan_attempt_at = startedAt;
    update.last_return_scan_at = finishedAt;
  } else if (kind === 'failed_delivery_scan') {
    update.last_failed_delivery_scan_attempt_at = startedAt;
    update.last_failed_delivery_scan_at = finishedAt;
  } else {
    update.last_sync_at = finishedAt;
    update.last_success_sync_at = finishedAt;
  }

  return update;
}

function buildStoreFailureUpdate(triggerSource, startedAt, error) {
  const kind = syncKindForTrigger(triggerSource);
  const update = {
    last_sync_attempt_at: startedAt,
    last_sync_status: 'failed',
    last_sync_message: error.message
  };

  if (kind === 'return_scan') {
    update.last_return_scan_attempt_at = startedAt;
  } else if (kind === 'failed_delivery_scan') {
    update.last_failed_delivery_scan_attempt_at = startedAt;
  }

  return update;
}

function buildTokenFailureUpdate(triggerSource, startedAt, error) {
  const kind = syncKindForTrigger(triggerSource);
  const update = {
    last_sync_attempt_at: startedAt,
    last_error: error.message
  };

  if (kind === 'return_scan') {
    update.last_return_scan_attempt_at = startedAt;
  } else if (kind === 'failed_delivery_scan') {
    update.last_failed_delivery_scan_attempt_at = startedAt;
  }

  return update;
}

async function resolveCentralInventory({ store, sellerSku, productName = '', displayTitle = '', imageUrl = '', allowCreate = true }) {
  return resolveStockTarget(
    {
      store_id: store._id,
      seller_sku: sellerSku,
      product_name: productName,
      display_title: displayTitle,
      image_url: imageUrl
    },
    { allowCreate }
  );
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
    inventory_id: inventory?.stock_doc_id || inventory?._id || null,
    seller_sku,
    master_sku: inventory?.master_sku || seller_sku,
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
  const effectiveCategory = itemDoc.status_category || orderDoc.status_category || orderRules.classifyOrderStatus(effectiveStatus);
  if (isCanceledStatus(effectiveStatus) || isNonDeductibleCategory(effectiveCategory)) {
    itemDoc.processing_status = 'skipped';
    if (isCanceledStatus(effectiveStatus) || effectiveCategory === 'cancelled') {
      itemDoc.collection_status = 'not_required';
      itemDoc.collection_action_required = false;
      itemDoc.collection_notification_level = 'none';
    }
    await itemDoc.save();
    stats.skipped += 1;
    return { action: 'non_deductible_status' };
  }

  if (!statusReached(effectiveStatus, store.deduct_stage)) {
    itemDoc.processing_status = 'pending';
    await itemDoc.save();
    stats.skipped += 1;
    return { action: 'waiting_stage' };
  }

  const target = await resolveCentralInventory({ store, sellerSku: itemDoc.seller_sku, productName: itemDoc.product_name, displayTitle: itemDoc.display_title, imageUrl: itemDoc.image_url, allowCreate: false });
  const qty = safeNumber(itemDoc.quantity, 1);

  if (!target) {
    itemDoc.mapping_status = 'unmapped';
    itemDoc.processing_status = 'failed';
    itemDoc.error_message = 'SKU is not linked to any internal inventory product';
    await itemDoc.save();

    await upsertOrderItemIssue({
      issueType: 'unmapped_sku',
      store,
      orderDoc,
      itemDoc,
      message: itemDoc.error_message,
      quantityNeeded: qty,
      availableStock: 0
    });
    stats.failed += 1;
    return { action: 'inventory_missing' };
  }

  const update = await updateTargetStock(target, { type: 'decrease', quantity: qty });
  if (!update.ok) {
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
      availableStock: target.stock || 0
    });
    stats.failed += 1;
    return { action: 'insufficient_stock' };
  }

  const refreshed = update.target || target;
  itemDoc.mapping_status = 'mapped';
  itemDoc.stock_deducted = true;
  itemDoc.processing_status = 'deducted';
  itemDoc.deduction_applied_at = new Date();
  itemDoc.error_message = '';
  await itemDoc.save();

  await createInventoryTransaction({
    store_id: store._id,
    inventory: refreshed,
    seller_sku: itemDoc.seller_sku,
    product_name: refreshed.product_name || itemDoc.product_name,
    order_id: orderDoc._id,
    order_item_id: itemDoc._id,
    external_order_id: orderDoc.external_order_id,
    external_order_item_id: itemDoc.external_order_item_id,
    transaction_type: 'order_deduct',
    quantity: qty,
    stock_before: update.stock_before,
    stock_after: update.stock_after,
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
  const isCancelled = isCanceledStatus(itemDoc.status) ||
    isCanceledStatus(orderDoc.status) ||
    itemDoc.status_category === 'cancelled' ||
    orderDoc.status_category === 'cancelled';
  if (!isCancelled) {
    stats.skipped += 1;
    return { action: 'not_canceled' };
  }

  const target = await resolveCentralInventory({ store, sellerSku: itemDoc.seller_sku, productName: itemDoc.product_name, displayTitle: itemDoc.display_title, imageUrl: itemDoc.image_url, allowCreate: false });
  if (!target) {
    itemDoc.processing_status = 'failed';
    itemDoc.error_message = 'Central inventory target not found for restore';
    await itemDoc.save();
    stats.failed += 1;
    return { action: 'inventory_missing' };
  }

  const qty = safeNumber(itemDoc.quantity, 1);
  const update = await updateTargetStock(target, { type: 'increase', quantity: qty });
  if (!update.ok) {
    itemDoc.processing_status = 'failed';
    itemDoc.error_message = 'Central inventory restore failed';
    await itemDoc.save();
    stats.failed += 1;
    return { action: 'restore_failed' };
  }
  const refreshed = update.target || target;

  itemDoc.mapping_status = 'mapped';
  itemDoc.stock_restored = true;
  itemDoc.processing_status = 'restored';
  itemDoc.restoration_applied_at = new Date();
  itemDoc.error_message = '';
  await itemDoc.save();

  await createInventoryTransaction({
    store_id: store._id,
    inventory: refreshed,
    seller_sku: itemDoc.seller_sku,
    product_name: refreshed.product_name || itemDoc.product_name,
    order_id: orderDoc._id,
    order_item_id: itemDoc._id,
    external_order_id: orderDoc.external_order_id,
    external_order_item_id: itemDoc.external_order_item_id,
    transaction_type: 'cancel_restore',
    quantity: qty,
    stock_before: update.stock_before,
    stock_after: update.stock_after,
    note: `Daraz order restore for order ${orderDoc.external_order_id}`
  });

  await resolveIssueByOrderItem(itemDoc._id, 'Stock restored after cancellation');
  stats.restored += 1;
  return { action: 'restored' };
}

async function upsertOrder(store, orderPayload) {
  const externalOrderId = getOrderId(orderPayload);
  if (!externalOrderId) return null;

  const orderStatus = getOrderStatus(orderPayload) || 'pending';
  const statusCategory = orderRules.classifyOrderStatus(orderStatus, orderPayload);
  const update = {
    order_number: getOrderNumber(orderPayload),
    status: orderStatus,
    status_category: statusCategory,
    revenue_countable: orderRules.shouldCountAsSale(orderStatus, statusCategory),
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

    const existingItem = await CentralOrderItem.findOne({
      store_id: store._id,
      external_order_item_id: externalOrderItemId
    }).lean();

    const sellerSku = getItemSellerSku(item);
    const productName = getItemName(item);
    const displayTitle = getItemEnglishTitle(item) || buildDisplayTitle(productName, sellerSku);
    const imageUrl = getItemImage(item) || existingItem?.image_url || '';
    const itemStatus = getItemStatus(item, orderDoc.status) || orderDoc.status || 'pending';
    const returnReason = getReturnReason(item);
    const claimDate = getClaimDate(item);
    const hubArrivedAt = getLogisticFacilityDate(item);
    const hubName = getHubName(item);
    const inventory = sellerSku ? await resolveCentralInventory({ store, sellerSku, productName, displayTitle, imageUrl, allowCreate: false }) : null;

    const classification = orderRules.classifyOrderItem({
      status: itemStatus,
      orderStatus: orderDoc.status,
      returnReason,
      claimDate,
      hubArrivedAt,
      rawPayload: item
    });

    let collectionStatus = orderRules.normalizeCollectionStatus({
      statusCategory: classification.statusCategory,
      parcelType: classification.parcelType,
      hubArrivedAt,
      existingStatus: existingItem?.collection_status || ''
    });

    const collectionDeadlineAt = hubArrivedAt ? orderRules.addDays(hubArrivedAt) : existingItem?.collection_deadline_at || null;
    const daysLeftToCollect = collectionDeadlineAt ? orderRules.daysLeftUntil(collectionDeadlineAt) : null;
    const finalStatusCategory = orderRules.deriveFinalStatusCategory(classification.statusCategory, collectionStatus);
    const collectionAction = orderRules.collectionActionRequired({
      parcelType: classification.parcelType,
      hubArrivedAt,
      collectionStatus
    });
    const notificationLevel = orderRules.collectionNotificationLevel({
      collectionStatus,
      deadline: collectionDeadlineAt,
      hubArrivedAt
    });

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
          status_category: finalStatusCategory,
          parcel_type: classification.parcelType,
          revenue_countable: classification.revenueCountable && finalStatusCategory === 'active_sale',
          return_reason: returnReason,
          claim_date: claimDate,
          logistic_facility_at: hubArrivedAt,
          hub_name: hubName,
          hub_arrived_at: hubArrivedAt,
          collection_deadline_at: collectionDeadlineAt,
          days_left_to_collect: daysLeftToCollect,
          collection_action_required: collectionAction,
          collection_notification_level: notificationLevel,
          collection_status: collectionStatus,
          collected_at: existingItem?.collected_at || null,
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
          error_message: '',
          scrap_warning_sent_at: null,
          collection_notes: ''
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
    const itemIsCancelled = isCanceledStatus(itemDoc.status) ||
      isCanceledStatus(orderDoc.status) ||
      itemDoc.status_category === 'cancelled' ||
      orderDoc.status_category === 'cancelled';
    if (store.restore_on_cancel && itemIsCancelled) {
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
  const warnings = [];

  try {
    const tokenReady = await ensureStoreTokenReadyForSync(store._id);

    if (!tokenReady?.ok) {
      throw new Error(tokenReady?.message || "Store access token is missing");
    }

    const storeToken = tokenReady.token || await StoreToken.findOne({ store_id: store._id });

    if (!storeToken || !storeToken.access_token) {
      throw new Error("Store access token is missing");
    }

    const since = makeStatusScanWindow(triggerSource, store.last_success_sync_at || store.last_sync_at, options.historyDays);
    const limit = Math.min(Math.max(Number(options.limit) || 50, 1), 100);
    const maxPages = Math.min(Math.max(Number(options.maxPages) || 20, 1), 100);
    const statusFilters = statusesForTrigger(triggerSource);
    const seenOrderIds = new Set();

    for (const statusFilter of statusFilters) {
      try {
        let offset = 0;
        let page = 0;
        let hasMore = true;

        while (hasMore && page < maxPages) {
          const ordersResponse = await getOrders({ storeToken, updatedAfter: since, status: statusFilter, offset, limit });
          const orders = Array.isArray(ordersResponse)
            ? ordersResponse
            : ordersResponse?.orders || ordersResponse?.data || [];
          stats.orders_seen += orders.length;

          for (const orderPayload of orders) {
            const externalId = getOrderId(orderPayload);
            if (externalId && seenOrderIds.has(externalId)) continue;
            if (externalId) seenOrderIds.add(externalId);

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

          page += 1;
          offset += limit;
          hasMore = ordersResponse?.hasMore === true && orders.length > 0;
        }
      } catch (error) {
        const statusLabel = statusFilter || 'all statuses';
        const warning = `Skipped ${statusLabel} order scan because Daraz API returned: ${error.message}`;
        warnings.push(warning);
        stats.failed += 1;
        console.warn(`[Daraz Sync] ${warning}`);
      }
    }

    if (stats.orders_seen === 0 && stats.orders_upserted === 0 && warnings.length === statusFilters.length) {
      throw new Error(warnings[0] || 'Daraz API order sync failed for every status filter');
    }

    const finishedAt = new Date();
    const summaryMessage = buildSuccessMessage(triggerSource, stats);
    store.set(buildStoreSuccessUpdate(triggerSource, startedAt, finishedAt, summaryMessage));
    await store.save();
    await StoreToken.updateOne(
      { store_id: store._id },
      { $set: buildTokenSuccessUpdate(triggerSource, startedAt, finishedAt) }
    );

    await writeSyncLog({
      store,
      triggerSource,
      startedAt,
      success: true,
      summaryMessage,
      stats,
      warnings
    });

    return { processed: stats.orders_upserted, ...stats };
  } catch (error) {
    store.set(buildStoreFailureUpdate(triggerSource, startedAt, error));
    await store.save();
    await StoreToken.updateOne(
      { store_id: store._id },
      { $set: buildTokenFailureUpdate(triggerSource, startedAt, error) }
    );

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

async function markOrderItemReceivedBack(orderItemId, { actor = 'admin' } = {}) {
  const itemDoc = await CentralOrderItem.findById(orderItemId);
  if (!itemDoc) throw new Error('Order item not found');

  const [store, orderDoc] = await Promise.all([
    Store.findById(itemDoc.store_id),
    CentralOrder.findById(itemDoc.order_id)
  ]);

  if (!store || !orderDoc) throw new Error('Related store or order not found');

  const parcelType = itemDoc.parcel_type || 'none';
  const statusCategory = itemDoc.status_category || '';
  const effectiveStatus = itemDoc.status || orderDoc.status || '';
  const canCollect = ['return', 'failed_delivery'].includes(parcelType) ||
    ['return', 'failed_delivery', 'collected', 'scrapped'].includes(statusCategory) ||
    isReturnOrFailedStatus(effectiveStatus, itemDoc.raw_payload || {});

  if (!canCollect) {
    throw new Error('Only return or failed delivery parcels can be marked as collected');
  }

  const markCollectedFields = () => {
    itemDoc.collection_status = 'collected';
    itemDoc.status_category = 'collected';
    itemDoc.collection_action_required = false;
    itemDoc.collection_notification_level = 'collected';
    itemDoc.days_left_to_collect = 0;
    itemDoc.collected_at = itemDoc.collected_at || new Date();
    itemDoc.error_message = '';
  };

  if (itemDoc.stock_restored) {
    markCollectedFields();
    await itemDoc.save();
    return { action: 'already_collected', item_id: itemDoc._id, collected_at: itemDoc.collected_at };
  }

  if (!itemDoc.stock_deducted) {
    markCollectedFields();
    itemDoc.processing_status = 'skipped';
    await itemDoc.save();
    return { action: 'collected_no_restore_needed', item_id: itemDoc._id, collected_at: itemDoc.collected_at };
  }

  const target = await resolveCentralInventory({ store, sellerSku: itemDoc.seller_sku, productName: itemDoc.product_name, displayTitle: itemDoc.display_title, imageUrl: itemDoc.image_url, allowCreate: false });
  if (!target) throw new Error('Central inventory target not found for collected parcel');

  const qty = safeNumber(itemDoc.quantity, 1);
  const update = await updateTargetStock(target, { type: 'increase', quantity: qty });
  if (!update.ok) throw new Error('Unable to restore collected parcel stock');
  const refreshed = update.target || target;

  markCollectedFields();
  itemDoc.mapping_status = 'mapped';
  itemDoc.stock_restored = true;
  itemDoc.processing_status = 'restored';
  itemDoc.restoration_applied_at = new Date();
  await itemDoc.save();

  await createInventoryTransaction({
    store_id: store._id,
    inventory: refreshed,
    seller_sku: itemDoc.seller_sku,
    product_name: refreshed.product_name || itemDoc.product_name,
    order_id: orderDoc._id,
    order_item_id: itemDoc._id,
    external_order_id: orderDoc.external_order_id,
    external_order_item_id: itemDoc.external_order_item_id,
    transaction_type: parcelType === 'failed_delivery' ? 'failed_delivery_restore' : 'return_restore',
    quantity: qty,
    stock_before: update.stock_before,
    stock_after: update.stock_after,
    note: `Collected from ${itemDoc.hub_name || orderRules.DEFAULT_COLLECTION_HUB_NAME} by ${actor}`
  });

  return { action: 'collected_and_restored', item_id: itemDoc._id, stock_after: update.stock_after, collected_at: itemDoc.collected_at };
}

async function refreshCollectionWatch() {
  const items = await CentralOrderItem.find({
    parcel_type: { $in: ['return', 'failed_delivery'] },
    collection_status: { $nin: ['collected', 'received', 'scrapped', 'expired'] },
    status_category: { $ne: 'cancelled' }
  });

  const summary = {
    checked: items.length,
    pending_collection: 0,
    due_soon: 0,
    overdue: 0
  };

  for (const item of items) {
    const hubArrivedAt = item.hub_arrived_at || item.logistic_facility_at || null;
    const deadline = item.collection_deadline_at || (hubArrivedAt ? orderRules.addDays(hubArrivedAt) : null);
    const collectionStatus = orderRules.normalizeCollectionStatus({
      statusCategory: item.status_category,
      parcelType: item.parcel_type,
      hubArrivedAt,
      existingStatus: item.collection_status
    });
    const daysLeft = deadline ? orderRules.daysLeftUntil(deadline) : null;
    const notificationLevel = orderRules.collectionNotificationLevel({ collectionStatus, deadline, hubArrivedAt });
    const actionRequired = orderRules.collectionActionRequired({ parcelType: item.parcel_type, hubArrivedAt, collectionStatus });

    item.hub_name = item.hub_name || orderRules.DEFAULT_COLLECTION_HUB_NAME;
    item.hub_arrived_at = hubArrivedAt;
    item.collection_deadline_at = deadline;
    item.days_left_to_collect = daysLeft;
    item.collection_status = collectionStatus;
    item.collection_action_required = actionRequired;
    item.collection_notification_level = notificationLevel;

    if (actionRequired) summary.pending_collection += 1;
    if (['three_days', 'one_day', 'deadline'].includes(notificationLevel)) summary.due_soon += 1;
    if (notificationLevel === 'overdue') summary.overdue += 1;

    await item.save();
  }

  return summary;
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
<<<<<<< HEAD
  if (!isLiveApiEnabled()) {
    throw new Error('Live Daraz API sync is disabled. Set DARAZ_ENABLE_LIVE_API=true in the server environment.');
  }

=======
>>>>>>> eb87ddec782a53736a39d0e420043f9f5e9f6b37
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
  markOrderItemReceivedBack,
  refreshCollectionWatch,
  resolveCentralInventory,
  getSyncLockState
};
