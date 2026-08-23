const DEFAULT_COLLECTION_HUB_NAME = process.env.DARAZ_RETURN_HUB_NAME || 'Islamabad I9 Center';
const DEFAULT_COLLECTION_DEADLINE_DAYS = Math.max(Number(process.env.DARAZ_COLLECTION_DEADLINE_DAYS || 6), 1);

function safeString(value) {
  return (value || '').toString().trim();
}

function normalizeStatus(value) {
  return safeString(value).toLowerCase().replace(/[\s-]+/g, '_');
}

function toDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function normalizeDate(value) {
  const date = toDate(value);
  return date ? new Date(date.getTime()) : null;
}

function addDays(date, days = DEFAULT_COLLECTION_DEADLINE_DAYS) {
  const base = normalizeDate(date);
  if (!base) return null;
  return new Date(base.getTime() + Number(days || DEFAULT_COLLECTION_DEADLINE_DAYS) * 24 * 60 * 60 * 1000);
}

function daysLeftUntil(date, now = new Date()) {
  const deadline = normalizeDate(date);
  if (!deadline) return null;
  return Math.ceil((deadline.getTime() - now.getTime()) / (24 * 60 * 60 * 1000));
}

function payloadText(payload = {}) {
  if (!payload || typeof payload !== 'object') return '';
  const parts = [];
  const keys = [
    'status',
    'order_status',
    'order_item_status',
    'shipment_status',
    'delivery_status',
    'reason',
    'return_reason',
    'cancel_reason',
    'logistic_status',
    'tracking_status',
    'package_status',
    'remarks'
  ];
  for (const key of keys) {
    if (payload[key]) parts.push(String(payload[key]));
  }
  return parts.join(' ').toLowerCase().replace(/[\s-]+/g, '_');
}

function isCancelledStatus(status = '') {
  const normalized = normalizeStatus(status);
  if (!normalized) return false;
  return normalized.includes('cancel') ||
    normalized === 'closed' ||
    normalized.includes('closed') ||
    normalized.includes('unpaid') ||
    normalized.includes('payment_failed') ||
    normalized.includes('failed_payment') ||
    normalized.includes('payment_rejected') ||
    normalized.includes('order_rejected') ||
    normalized.includes('customer_not_completed') ||
    normalized.includes('not_completed') ||
    normalized.includes('incomplete');
}

function isEarlyBuyerCancellationReason(reason = '') {
  const norm = safeString(reason).toLowerCase();
  if (!norm) return false;
  const earlyCancelPatterns = [
    'cheaper elsewhere',
    'found cheaper',
    'shipping cost is too high',
    'shipping cost',
    'dont want this order',
    "don't want this order",
    'dont want this item',
    "don't want this item",
    'want to place a new order',
    'place a new order',
    'different items',
    'more/different items',
    'seller asked me to cancel',
    'out of stock',
    'delivery time is too long',
    'delivery time',
    'duplicate order',
    'voucher',
    'forgot to use voucher',
    'change of delivery address',
    'delivery address',
    'change address',
    'decided for alternative product',
    'alternative product',
    'order placed by mistake',
    'buyer cancel',
    'buyer_cancel',
    'change of mind',
    'changed my mind'
  ];
  return earlyCancelPatterns.some((pattern) => norm.includes(pattern));
}

function isReturnStatus(status = '', payload = {}) {
  const statusNorm = normalizeStatus(status);
  const pText = payloadText(payload);
  const normalized = `${statusNorm} ${pText}`.trim();
  if (!normalized) return false;

  // Ignore early pre-fulfillment buyer cancellations
  if (isEarlyBuyerCancellationReason(pText) || isEarlyBuyerCancellationReason(statusNorm) || isEarlyBuyerCancellationReason(payload?.return_reason || payload?.reason || payload?.cancel_reason)) {
    return false;
  }

  if (isCancelledStatus(statusNorm) && !normalized.includes('returned') && !normalized.includes('customer_return')) {
    return false;
  }

  if (statusNorm === 'returned' || statusNorm === 'customer_return' || statusNorm === 'buyer_return') {
    return true;
  }

  const logisticsOnlyReturn = normalized.includes('return_to_seller') ||
    normalized.includes('return_to_origin') ||
    normalized.includes('returned_to_shipper');
  const hasCustomerReturnContext = normalized.includes('refund') ||
    normalized.includes('claim') ||
    normalized.includes('return_reason') ||
    normalized.includes('customer_return') ||
    normalized.includes('buyer_return');

  if (logisticsOnlyReturn && !hasCustomerReturnContext) return false;

  return normalized.includes('customer_return') ||
    normalized.includes('buyer_return') ||
    normalized.includes('return_requested') ||
    normalized.includes('returning') ||
    statusNorm === 'return' ||
    normalized.includes('returned') ||
    normalized.includes('refund') ||
    normalized.includes('claim');
}

function isFailedDeliveryStatus(status = '', payload = {}) {
  const statusNorm = normalizeStatus(status);
  const pText = payloadText(payload);
  const normalized = `${statusNorm} ${pText}`.trim();
  if (!normalized) return false;

  if (isEarlyBuyerCancellationReason(pText) || isEarlyBuyerCancellationReason(statusNorm)) {
    return false;
  }

  if (normalized.includes('payment_failed') || normalized.includes('failed_payment')) {
    return false;
  }

  // In Daraz Open API, 'failed' is the official status code for failed delivery
  if (statusNorm === 'failed' || statusNorm === 'failed_delivery' || statusNorm === 'delivery_failed' || statusNorm === 'undelivered') {
    return true;
  }

  const explicitFailedDelivery = normalized.includes('failed_delivery') ||
    normalized.includes('delivery_failed') ||
    normalized.includes('failed_to_deliver') ||
    normalized.includes('unable_to_deliver') ||
    normalized.includes('undelivered') ||
    normalized.includes('delivery_attempt_failed') ||
    normalized.includes('returned_to_shipper') ||
    normalized.includes('return_to_seller') ||
    normalized.includes('return_to_origin') ||
    normalized.includes('package_scrapped') ||
    normalized.includes('logistic_facility') ||
    normalized.includes('arrived_at_facility') ||
    normalized.includes('arrived_at_hub');

  const genericFailedWithDeliveryContext = normalized.includes('failed') &&
    (normalized.includes('deliver') || normalized.includes('logistic') || normalized.includes('shipment') || normalized.includes('courier') || normalized.includes('package'));

  return explicitFailedDelivery || genericFailedWithDeliveryContext;
}

function isSaleEligibleStatus(status = '') {
  const normalized = normalizeStatus(status);
  if (!normalized) return false;
  if (isCancelledStatus(normalized) || isReturnStatus(normalized) || isFailedDeliveryStatus(normalized)) return false;
  return [
    'confirmed',
    'created',
    'pending',
    'packed',
    'ready_to_ship',
    'ready_to_ship_pending',
    'shipped',
    'delivered',
    'completed',
    'processed'
  ].some((key) => normalized === key || normalized.includes(key));
}

function shouldCountAsSale(status = '', category = '') {
  const cat = normalizeStatus(category);
  if (cat) return cat === 'active_sale' || cat === 'delivered';
  return isSaleEligibleStatus(status);
}

function classifyOrderStatus(status = '', payload = {}) {
  if (isCancelledStatus(status)) return 'cancelled';
  if (isReturnStatus(status, payload)) return 'return';
  if (isFailedDeliveryStatus(status, payload)) return 'failed_delivery';
  if (isSaleEligibleStatus(status)) return 'active_sale';
  return 'pending';
}

function getParcelType(statusCategory) {
  if (statusCategory === 'return') return 'return';
  if (statusCategory === 'failed_delivery') return 'failed_delivery';
  return 'none';
}

function classifyOrderItem({ status = '', orderStatus = '', returnReason = '', claimDate = null, hubArrivedAt = null, rawPayload = {} } = {}) {
  const combined = [status, orderStatus, payloadText(rawPayload)].join(' ');

  if (isCancelledStatus(status) || isCancelledStatus(orderStatus) || isEarlyBuyerCancellationReason(returnReason)) {
    return { statusCategory: 'cancelled', parcelType: 'none', revenueCountable: false };
  }

  if (returnReason || claimDate || isReturnStatus(combined, rawPayload)) {
    return { statusCategory: 'return', parcelType: 'return', revenueCountable: false };
  }

  if (hubArrivedAt || isFailedDeliveryStatus(combined, rawPayload)) {
    return { statusCategory: 'failed_delivery', parcelType: 'failed_delivery', revenueCountable: false };
  }

  if (isSaleEligibleStatus(status) || isSaleEligibleStatus(orderStatus)) {
    return { statusCategory: 'active_sale', parcelType: 'none', revenueCountable: true };
  }

  return { statusCategory: 'pending', parcelType: 'none', revenueCountable: false };
}

function normalizeCollectionStatus({ statusCategory = '', parcelType = 'none', hubArrivedAt = null, existingStatus = '' } = {}) {
  const existing = normalizeStatus(existingStatus);
  if (['collected', 'received', 'scrapped', 'expired'].includes(existing)) {
    return existing === 'received' ? 'collected' : existing;
  }

  if (statusCategory === 'cancelled') return 'not_required';
  if (!['return', 'failed_delivery'].includes(parcelType)) return 'not_required';
  if (hubArrivedAt) return 'needs_collection';
  return parcelType === 'return' ? 'return_in_transit' : 'failed_delivery_tracking';
}

function deriveFinalStatusCategory(statusCategory, collectionStatus = '') {
  const collection = normalizeStatus(collectionStatus);
  if (collection === 'collected' || collection === 'received') return 'collected';
  if (collection === 'scrapped' || collection === 'expired') return 'scrapped';
  return statusCategory;
}

function collectionNotificationLevel({ collectionStatus = '', deadline = null, hubArrivedAt = null, now = new Date() } = {}) {
  const collection = normalizeStatus(collectionStatus);
  if (collection === 'collected' || collection === 'received') return 'collected';
  if (collection === 'scrapped' || collection === 'expired') return 'scrapped';
  if (!hubArrivedAt) return 'none';

  const daysLeft = daysLeftUntil(deadline, now);
  if (daysLeft === null) return 'arrived';
  if (daysLeft < 0) return 'overdue';
  if (daysLeft === 0) return 'deadline';
  if (daysLeft <= 1) return 'one_day';
  if (daysLeft <= 3) return 'three_days';
  return 'arrived';
}

function collectionActionRequired({ parcelType = 'none', hubArrivedAt = null, collectionStatus = '' } = {}) {
  const collection = normalizeStatus(collectionStatus);
  return ['return', 'failed_delivery'].includes(parcelType) &&
    !!hubArrivedAt &&
    !['collected', 'received', 'scrapped', 'expired'].includes(collection);
}

function itemMatchesSale(item = {}, order = {}) {
  const category = item.status_category || order.status_category || '';
  const status = item.status || order.status || '';
  return shouldCountAsSale(status, category) && item.parcel_type !== 'return' && item.parcel_type !== 'failed_delivery';
}

function nonSaleCategories() {
  return ['cancelled', 'return', 'failed_delivery', 'collected', 'scrapped', 'pending'];
}

module.exports = {
  DEFAULT_COLLECTION_HUB_NAME,
  DEFAULT_COLLECTION_DEADLINE_DAYS,
  safeString,
  normalizeStatus,
  toDate,
  addDays,
  daysLeftUntil,
  isCancelledStatus,
  isReturnStatus,
  isFailedDeliveryStatus,
  isSaleEligibleStatus,
  shouldCountAsSale,
  classifyOrderStatus,
  classifyOrderItem,
  getParcelType,
  normalizeCollectionStatus,
  deriveFinalStatusCategory,
  collectionNotificationLevel,
  collectionActionRequired,
  itemMatchesSale,
  nonSaleCategories
};
