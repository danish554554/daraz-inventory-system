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

function safePayloadString(payload) {
  if (!payload) return '';
  if (typeof payload === 'string') return payload;
  try {
    return JSON.stringify(payload);
  } catch (_) {
    return '';
  }
}

// -----------------------------------------------------------------------------
// CONTROLLED DARAZ OFFICIAL STATUS ENUM & REASON CODE DICTIONARIES
// -----------------------------------------------------------------------------

const DARAZ_OFFICIAL_STATUSES = {
  unpaid: { category: 'cancelled', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Unpaid' },
  pending: { category: 'pending', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Pending' },
  ready_to_ship: { category: 'active_sale', parcelType: 'none', revenueCountable: true, isControlled: true, label: 'Ready To Ship' },
  ready_to_ship_pending: { category: 'active_sale', parcelType: 'none', revenueCountable: true, isControlled: true, label: 'RTS Pending' },
  packed: { category: 'active_sale', parcelType: 'none', revenueCountable: true, isControlled: true, label: 'Packed' },
  shipped: { category: 'active_sale', parcelType: 'none', revenueCountable: true, isControlled: true, label: 'Shipped' },
  delivered: { category: 'active_sale', parcelType: 'none', revenueCountable: true, isControlled: true, label: 'Delivered' },
  canceled: { category: 'cancelled', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Canceled' },
  cancelled: { category: 'cancelled', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Cancelled' },
  failed: { category: 'failed_delivery', parcelType: 'failed_delivery', revenueCountable: false, isControlled: true, label: 'Failed Delivery' },
  failed_delivery: { category: 'failed_delivery', parcelType: 'failed_delivery', revenueCountable: false, isControlled: true, label: 'Failed Delivery' },
  returned: { category: 'return', parcelType: 'return', revenueCountable: false, isControlled: true, label: 'Customer Return' },
  lost_by_3pl: { category: 'cancelled', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Lost by 3PL' },
  damaged_by_3pl: { category: 'cancelled', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Damaged by 3PL' },
  scrapped: { category: 'scrapped', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Scrapped' },
  package_scrapped: { category: 'scrapped', parcelType: 'none', revenueCountable: false, isControlled: true, label: 'Package Scrapped' }
};

const DARAZ_OFFICIAL_COLLECTION_STATUSES = [
  { code: 'PARCEL_RETURNED_COLLECTED', label: 'Parcel Collected by Seller', keywords: ['successfully returned', 'package returned', 'your parcel has been successfully returned', 'delivered to merchant', 'returned to merchant', 'collected by seller', 'handed over to seller', 'merchant collected', 'delivered to shipper', 'delivered to origin', 'package collected', 'item received back'] }
];

const DARAZ_OFFICIAL_CANCELLATION_REASONS = [
  { code: 'SELLER_CANCEL_OUT_OF_STOCK', label: 'Seller Out of Stock', keywords: ['seller_asked_me_to_cancel', 'item_is_out_of_stock', 'out_of_stock', 'seller asked me to cancel'] },
  { code: 'BUYER_CANCEL_REQUEST', label: 'Buyer Cancelled', keywords: ['buyer_asked_to_cancel', 'cancelled_by_buyer', 'canceled_by_buyer', 'buyer requested cancel'] },
  { code: 'SELLER_CANCELLED', label: 'Seller Cancelled', keywords: ['cancelled_by_seller', 'canceled_by_seller', 'seller cancelled'] },
  { code: 'DUPLICATE_ORDER', label: 'Duplicate Order', keywords: ['duplicate_order', 'duplicate order'] },
  { code: 'SOURCING_ISSUE', label: 'Sourcing Issue', keywords: ['sourcing_issue', 'cannot source item'] },
  { code: 'CHANGE_OF_MIND_PRE_SHIP', label: 'Change of Mind (Pre-shipment)', keywords: ['change_of_mind_before_shipping', 'customer changed mind before shipping'] },
  { code: 'PAYMENT_FAILED', label: 'Payment Unsuccessful', keywords: ['payment_cancelled', 'payment_failed', 'failed_payment', 'unpaid', 'payment_timeout'] },
  { code: 'SYSTEM_CANCELLED', label: 'System Cancelled', keywords: ['system_cancelled', 'auto_cancelled_by_daraz', 'timeout_cancelled'] }
];

const DARAZ_OFFICIAL_FAILED_DELIVERY_REASONS = [
  { code: 'REJECTED_AT_DOORSTEP', label: 'Rejected at Doorstep', keywords: ['rejected_at_doorstep', 'rejected at doorstep', 'refused at doorstep'] },
  { code: 'RESCHEDULED_OUTSIDE_SLA', label: 'Rescheduled Outside SLA', keywords: ['customer_rescheduled_outside_of_delivery_sla', 'rescheduled outside of delivery sla', 'outside_of_delivery_sla'] },
  { code: 'OTHERS_MISSING_MAPPING', label: 'Daraz Missing Mapping Code', keywords: ['others_missing_mapping', 'missing mapping'] },
  { code: 'WRONG_DELIVERY_ADDRESS', label: 'Wrong Delivery Address', keywords: ['delivery_address_is_wrong', 'delivery_address_wrong', 'wrong_address', 'address_is_wrong', 'incorrect_address', 'invalid_address', 'address_not_found', 'incomplete_address', 'fake_address'] },
  { code: 'CUSTOMER_UNAVAILABLE', label: 'Customer Not Available', keywords: ['consignee_not_available', 'customer_not_available', 'customer unavailable'] },
  { code: 'CUSTOMER_UNREACHABLE', label: 'Customer Phone Unreachable', keywords: ['customer_unreachable', 'phone_switched_off', 'no_answer', 'unreachable'] },
  { code: 'PREMISES_CLOSED', label: 'Premises / Office Closed', keywords: ['premises_closed', 'office_closed', 'door_locked'] },
  { code: 'OUT_OF_DELIVERY_AREA', label: 'Out of Delivery Area', keywords: ['out_of_delivery_area', 'remote_area', 'non_serviceable_area'] },
  { code: 'CUSTOMER_REFUSED', label: 'Customer Refused Delivery', keywords: ['refused_delivery', 'refused_to_accept', 'refused'] },
  { code: 'DELIVERY_ATTEMPT_FAILED', label: 'Delivery Attempt Failed', keywords: ['failed_delivery', 'delivery_failed', 'delivery_attempt_failed', 'unable_to_deliver', 'undelivered'] }
];

const DARAZ_OFFICIAL_RETURN_REASONS = [
  { code: 'RMA_DEFECTIVE_ITEM', label: 'Defective / Not Working', keywords: ['defective_item', 'item_defective', 'not_working', 'faulty_item', 'defective'] },
  { code: 'RMA_WRONG_ITEM', label: 'Wrong Item Received', keywords: ['wrong_item', 'wrong_product_sent', 'different_from_description', 'incorrect_item'] },
  { code: 'RMA_DAMAGED_ITEM', label: 'Damaged in Transit / Broken', keywords: ['damaged_item', 'damaged_in_transit', 'broken_item'] },
  { code: 'RMA_MISSING_PARTS', label: 'Missing Accessories / Incomplete', keywords: ['missing_items', 'missing_parts', 'incomplete_order', 'items_missing'] },
  { code: 'RMA_COUNTERFEIT', label: 'Counterfeit / Replica Item', keywords: ['counterfeit_item', 'fake_item', 'counterfeit'] },
  { code: 'RMA_POOR_QUALITY', label: 'Quality Not as Expected', keywords: ['quality_not_as_expected', 'poor_quality'] },
  { code: 'RMA_CHANGE_OF_MIND', label: 'Change of Mind (Return Policy)', keywords: ['change_of_mind', 'buyer_change_of_mind'] },
  { code: 'RMA_GENERIC_RETURN', label: 'Customer Return Claim', keywords: ['customer_return', 'buyer_return', 'return_requested', 'returning', 'refund', 'claim', 'daraz_return_claim'] }
];

// -----------------------------------------------------------------------------
// CONTROLLED MATCHING HELPERS
// -----------------------------------------------------------------------------

function matchControlledReason(text, reasonTable) {
  const norm = safeString(text).toLowerCase().replace(/[\s-]+/g, '_');
  if (!norm) return null;
  for (const entry of reasonTable) {
    for (const kw of entry.keywords) {
      const kwNorm = kw.toLowerCase().replace(/[\s-]+/g, '_');
      if (norm.includes(kwNorm) || norm === kwNorm) {
        return entry;
      }
    }
  }
  return null;
}

function matchControlledCollectionStatus(statusText = '', payload = {}) {
  const statusNorm = safeString(statusText).toLowerCase();
  const allText = `${statusNorm} ${safePayloadString(payload)}`.toLowerCase().replace(/[\s\-_\[\]!.,/]+/g, ' ');
  for (const entry of DARAZ_OFFICIAL_COLLECTION_STATUSES) {
    for (const kw of entry.keywords) {
      if (allText.includes(kw)) {
        return entry;
      }
    }
  }
  return null;
}

function isSuccessfullyReturnedToMerchant(status = '', payload = {}) {
  return !!matchControlledCollectionStatus(status, payload);
}

function isCancellationReason(reasonText = '') {
  return !!matchControlledReason(reasonText, DARAZ_OFFICIAL_CANCELLATION_REASONS);
}

function isFailedDeliveryReason(reasonText = '') {
  return !!matchControlledReason(reasonText, DARAZ_OFFICIAL_FAILED_DELIVERY_REASONS);
}

function isReturnReason(reasonText = '') {
  return !!matchControlledReason(reasonText, DARAZ_OFFICIAL_RETURN_REASONS);
}

function isCancelledStatus(status = '') {
  const norm = normalizeStatus(status);
  if (!norm) return false;
  if (DARAZ_OFFICIAL_STATUSES[norm]?.category === 'cancelled') return true;
  return isCancellationReason(status);
}

function isReturnStatus(status = '', payload = {}) {
  const norm = normalizeStatus(status);
  if (!norm && !payload) return false;

  // Controlled cancellation and failed delivery always override return heuristics
  if (isCancellationReason(status) || isFailedDeliveryReason(status)) return false;
  if (DARAZ_OFFICIAL_STATUSES[norm]?.category === 'return') return true;

  return isReturnReason(status) || isReturnReason(safePayloadString(payload));
}

function isFailedDeliveryStatus(status = '', payload = {}) {
  const norm = normalizeStatus(status);
  if (!norm && !payload) return false;

  if (isCancellationReason(status)) return false;
  if (DARAZ_OFFICIAL_STATUSES[norm]?.category === 'failed_delivery') return true;

  return isFailedDeliveryReason(status) || isFailedDeliveryReason(safePayloadString(payload));
}

function isSaleEligibleStatus(status = '') {
  const norm = normalizeStatus(status);
  if (!norm) return false;
  return DARAZ_OFFICIAL_STATUSES[norm]?.category === 'active_sale' || false;
}

function shouldCountAsSale(status = '', category = '') {
  const cat = normalizeStatus(category);
  if (cat) return cat === 'active_sale' || cat === 'delivered';
  return isSaleEligibleStatus(status);
}

function classifyOrderStatus(status = '', payload = {}) {
  const norm = normalizeStatus(status);
  if (DARAZ_OFFICIAL_STATUSES[norm]) {
    return DARAZ_OFFICIAL_STATUSES[norm].category;
  }
  if (isSuccessfullyReturnedToMerchant(status, payload)) return 'collected';
  if (isCancelledStatus(status)) return 'cancelled';
  if (isReturnStatus(status, payload)) return 'return';
  if (isFailedDeliveryStatus(status, payload)) return 'failed_delivery';
  return 'pending';
}

function getParcelType(statusCategory) {
  if (statusCategory === 'return') return 'return';
  if (statusCategory === 'failed_delivery') return 'failed_delivery';
  return 'none';
}

// -----------------------------------------------------------------------------
// CONTROLLED ORDER ITEM CLASSIFICATION WITH REVIEW LABELING
// -----------------------------------------------------------------------------

function classifyOrderItem({
  status = '',
  orderStatus = '',
  returnReason = '',
  claimDate = null,
  hubArrivedAt = null,
  rawPayload = {}
} = {}) {
  const originalStatus = safeString(status);
  const originalReason = safeString(returnReason);
  const normStatus = normalizeStatus(status);
  const normOrderStatus = normalizeStatus(orderStatus);
  const inspectionText = `${originalStatus} ${safeString(orderStatus)} ${originalReason}`;

  // 1. Check if collected / parcel received back by merchant
  const collectionMatch = matchControlledCollectionStatus(inspectionText, rawPayload);
  if (collectionMatch) {
    const isReturn = isReturnStatus(inspectionText, rawPayload);
    return {
      statusCategory: 'collected',
      parcelType: isReturn ? 'return' : 'failed_delivery',
      revenueCountable: false,
      isCollected: true,
      collectionStatus: 'collected',
      reasonCode: collectionMatch.code,
      reasonLabel: collectionMatch.label,
      mappingConfidence: 'mapped',
      needsReview: false,
      reviewReason: '',
      originalStatus,
      originalReason
    };
  }

  // 2. Check if cancelled by official status or known cancellation reason code
  const cancelReasonMatch = matchControlledReason(originalReason || originalStatus, DARAZ_OFFICIAL_CANCELLATION_REASONS);
  if (cancelReasonMatch || isCancelledStatus(originalStatus) || isCancelledStatus(orderStatus)) {
    return {
      statusCategory: 'cancelled',
      parcelType: 'none',
      revenueCountable: false,
      reasonCode: cancelReasonMatch?.code || 'ORDER_CANCELLED',
      reasonLabel: cancelReasonMatch?.label || 'Order Cancelled',
      mappingConfidence: cancelReasonMatch || DARAZ_OFFICIAL_STATUSES[normStatus] ? 'mapped' : 'heuristic',
      needsReview: false,
      reviewReason: '',
      originalStatus,
      originalReason
    };
  }

  // 3. Check if Failed Delivery by official Daraz failed status or known failed delivery reasons
  const failedReasonMatch = matchControlledReason(originalReason || originalStatus, DARAZ_OFFICIAL_FAILED_DELIVERY_REASONS);
  if (failedReasonMatch || normStatus === 'failed' || normStatus === 'failed_delivery' || (!isReturnStatus(inspectionText, rawPayload) && hubArrivedAt)) {
    return {
      statusCategory: 'failed_delivery',
      parcelType: 'failed_delivery',
      revenueCountable: false,
      reasonCode: failedReasonMatch?.code || 'FAILED_DELIVERY_GENERIC',
      reasonLabel: failedReasonMatch?.label || 'Failed Delivery',
      mappingConfidence: failedReasonMatch || DARAZ_OFFICIAL_STATUSES[normStatus] ? 'mapped' : 'heuristic',
      needsReview: false,
      reviewReason: '',
      originalStatus,
      originalReason
    };
  }

  // 4. Check if Customer Return (RMA claim or returned status)
  const returnReasonMatch = matchControlledReason(originalReason || originalStatus, DARAZ_OFFICIAL_RETURN_REASONS);
  if (returnReasonMatch || claimDate || normStatus === 'returned' || (originalReason && !isFailedDeliveryReason(originalReason) && !isCancellationReason(originalReason))) {
    return {
      statusCategory: 'return',
      parcelType: 'return',
      revenueCountable: false,
      reasonCode: returnReasonMatch?.code || 'RMA_GENERIC_RETURN',
      reasonLabel: returnReasonMatch?.label || 'Customer Return Claim',
      mappingConfidence: returnReasonMatch || DARAZ_OFFICIAL_STATUSES[normStatus] || claimDate ? 'mapped' : 'heuristic',
      needsReview: false,
      reviewReason: '',
      originalStatus,
      originalReason
    };
  }

  // 5. Active Sale (Confirmed, RTS, Shipped, Delivered)
  if (DARAZ_OFFICIAL_STATUSES[normStatus]?.category === 'active_sale' || DARAZ_OFFICIAL_STATUSES[normOrderStatus]?.category === 'active_sale') {
    const statusMeta = DARAZ_OFFICIAL_STATUSES[normStatus] || DARAZ_OFFICIAL_STATUSES[normOrderStatus];
    return {
      statusCategory: 'active_sale',
      parcelType: 'none',
      revenueCountable: true,
      reasonCode: 'ACTIVE_SALE',
      reasonLabel: statusMeta?.label || 'Active Sale',
      mappingConfidence: 'mapped',
      needsReview: false,
      reviewReason: '',
      originalStatus,
      originalReason
    };
  }

  // 6. Unknown / Unmapped Status or Reason -> Flag explicitly for review
  const hasNovelText = originalReason.length > 0 || (originalStatus.length > 0 && !DARAZ_OFFICIAL_STATUSES[normStatus]);
  return {
    statusCategory: 'pending',
    parcelType: 'none',
    revenueCountable: false,
    reasonCode: 'UNMAPPED_DARAZ_STATUS',
    reasonLabel: originalReason || originalStatus || 'Unmapped Daraz Status',
    mappingConfidence: hasNovelText ? 'unknown_review_needed' : 'mapped',
    needsReview: hasNovelText,
    reviewReason: hasNovelText ? `Unmapped Daraz status or reason code: "${originalReason || originalStatus}"` : '',
    originalStatus,
    originalReason
  };
}

function normalizeCollectionStatus({ statusCategory = '', parcelType = 'none', hubArrivedAt = null, existingStatus = '' } = {}) {
  const existing = normalizeStatus(existingStatus);
  if (['collected', 'received', 'scrapped', 'expired'].includes(existing) || isSuccessfullyReturnedToMerchant(existingStatus)) {
    return existing === 'received' ? 'collected' : (existing === 'scrapped' || existing === 'expired' ? existing : 'collected');
  }

  if (statusCategory === 'cancelled') return 'not_required';
  if (statusCategory === 'collected') return 'collected';
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
  DARAZ_OFFICIAL_STATUSES,
  DARAZ_OFFICIAL_COLLECTION_STATUSES,
  DARAZ_OFFICIAL_CANCELLATION_REASONS,
  DARAZ_OFFICIAL_FAILED_DELIVERY_REASONS,
  DARAZ_OFFICIAL_RETURN_REASONS,
  safeString,
  normalizeStatus,
  toDate,
  addDays,
  daysLeftUntil,
  isCancellationReason,
  isFailedDeliveryReason,
  isReturnReason,
  isCancelledStatus,
  isReturnStatus,
  isFailedDeliveryStatus,
  isSaleEligibleStatus,
  isSuccessfullyReturnedToMerchant,
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
