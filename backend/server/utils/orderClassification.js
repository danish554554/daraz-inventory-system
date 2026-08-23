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

function isCancellationReason(reasonText = '') {
  const normalized = safeString(reasonText).toLowerCase().replace(/[\s-]+/g, '_');
  if (!normalized) return false;
  return normalized.includes('seller_asked_me_to_cancel') ||
    normalized.includes('out_of_stock') ||
    normalized.includes('item_is_out_of_stock') ||
    normalized.includes('buyer_asked_to_cancel') ||
    normalized.includes('cancelled_by_buyer') ||
    normalized.includes('cancelled_by_seller') ||
    normalized.includes('canceled_by_buyer') ||
    normalized.includes('canceled_by_seller') ||
    normalized.includes('duplicate_order') ||
    normalized.includes('sourcing_issue') ||
    normalized.includes('change_of_mind_before_shipping') ||
    normalized.includes('payment_cancelled') ||
    normalized.includes('unpaid') ||
    normalized.includes('cancel');
}

function isFailedDeliveryReason(reasonText = '') {
  const normalized = safeString(reasonText).toLowerCase().replace(/[\s-]+/g, '_');
  if (!normalized) return false;
  return normalized.includes('rejected_at_doorstep') ||
    normalized.includes('customer_rescheduled_outside_of_delivery_sla') ||
    normalized.includes('others_missing_mapping') ||
    normalized.includes('delivery_address_is_wrong') ||
    normalized.includes('delivery_address_wrong') ||
    normalized.includes('address_is_wrong') ||
    normalized.includes('wrong_address') ||
    normalized.includes('address_not_found') ||
    normalized.includes('incorrect_address') ||
    normalized.includes('invalid_address') ||
    normalized.includes('incomplete_address') ||
    normalized.includes('fake_address') ||
    normalized.includes('rescheduled_outside') ||
    normalized.includes('outside_of_delivery_sla') ||
    normalized.includes('delivery_sla') ||
    normalized.includes('doorstep') ||
    normalized.includes('refused_to_accept') ||
    normalized.includes('refused_delivery') ||
    normalized.includes('refused') ||
    normalized.includes('consignee_not_available') ||
    normalized.includes('customer_not_available') ||
    normalized.includes('customer_unreachable') ||
    normalized.includes('unreachable') ||
    normalized.includes('phone_switched_off') ||
    normalized.includes('no_answer') ||
    normalized.includes('premises_closed') ||
    normalized.includes('out_of_delivery_area') ||
    normalized.includes('failed_delivery') ||
    normalized.includes('delivery_failed') ||
    normalized.includes('delivery_attempt_failed') ||
    normalized.includes('unable_to_deliver') ||
    normalized.includes('undelivered');
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
    normalized.includes('incomplete') ||
    isCancellationReason(status);
}

function isReturnStatus(status = '', payload = {}) {
  const statusNorm = normalizeStatus(status);
  const normalized = `${statusNorm} ${payloadText(payload)}`.trim();
  if (!normalized) return false;

  // If reason or status indicates failed delivery reasons or cancellation, it is NOT a customer return
  if (isFailedDeliveryReason(normalized) || isCancellationReason(normalized)) {
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
  const normalized = `${statusNorm} ${payloadText(payload)}`.trim();
  if (!normalized) return false;

  if (isCancellationReason(normalized)) {
    return false;
  }

  if (isFailedDeliveryReason(normalized)) {
    return true;
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
    normalized.includes('arrived_at_hub') ||
    normalized.includes('rejected_at_doorstep') ||
    normalized.includes('outside_of_delivery_sla') ||
    normalized.includes('others_missing_mapping');

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
  const combined = [status, orderStatus, returnReason, payloadText(rawPayload)].join(' ');

  // 1. Check if cancelled or has a cancellation reason (e.g. out of stock / seller asked to cancel)
  if (isCancelledStatus(status) || isCancelledStatus(orderStatus) || isCancellationReason(returnReason)) {
    return { statusCategory: 'cancelled', parcelType: 'none', revenueCountable: false };
  }

  // 2. Check if Failed Delivery (by failed delivery status OR failed delivery reasons like rejected at doorstep, SLA expired, missing mapping)
  if (isFailedDeliveryReason(returnReason) || isFailedDeliveryStatus(combined, rawPayload) || (!isReturnStatus(combined, rawPayload) && hubArrivedAt)) {
    return { statusCategory: 'failed_delivery', parcelType: 'failed_delivery', revenueCountable: false };
  }

  // 3. Genuine Customer Returns (customer claims, defective, wrong item, etc.)
  if (claimDate || isReturnStatus(combined, rawPayload) || (returnReason && !isCancellationReason(returnReason) && !isFailedDeliveryReason(returnReason))) {
    return { statusCategory: 'return', parcelType: 'return', revenueCountable: false };
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
  isCancellationReason,
  isFailedDeliveryReason,
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
