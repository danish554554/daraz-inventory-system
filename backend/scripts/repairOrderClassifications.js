require('dotenv').config();
const mongoose = require('mongoose');
const connectDB = require('../server/config/db');
const CentralOrder = require('../server/models/CentralOrder');
const CentralOrderItem = require('../server/models/CentralOrderItem');
const orderRules = require('../server/utils/orderClassification');

async function repair() {
  await connectDB();
  const limit = Math.min(Number(process.env.REPAIR_LIMIT || 50000), 100000);

  const orders = await CentralOrder.find({}).limit(limit);
  let ordersUpdated = 0;
  for (const order of orders) {
    const category = orderRules.classifyOrderStatus(order.status, order.raw_payload || {});
    order.status_category = category;
    order.revenue_countable = orderRules.shouldCountAsSale(order.status, category);
    await order.save();
    ordersUpdated += 1;
  }

  const items = await CentralOrderItem.find({}).populate('order_id', 'status status_category').limit(limit);
  let itemsUpdated = 0;
  for (const item of items) {
    const hubArrivedAt = item.hub_arrived_at || item.logistic_facility_at || null;
    const classification = orderRules.classifyOrderItem({
      status: item.status,
      orderStatus: item.order_id?.status || '',
      returnReason: item.return_reason,
      claimDate: item.claim_date,
      hubArrivedAt,
      rawPayload: item.raw_payload || {}
    });
    const collectionStatus = orderRules.normalizeCollectionStatus({
      statusCategory: classification.statusCategory,
      parcelType: classification.parcelType,
      hubArrivedAt,
      existingStatus: item.collection_status
    });
    const deadline = hubArrivedAt ? orderRules.addDays(hubArrivedAt) : null;
    item.status_category = orderRules.deriveFinalStatusCategory(classification.statusCategory, collectionStatus);
    item.parcel_type = classification.parcelType;
    item.revenue_countable = classification.revenueCountable && item.status_category === 'active_sale';
    item.hub_name = item.hub_name || orderRules.DEFAULT_COLLECTION_HUB_NAME;
    item.hub_arrived_at = hubArrivedAt;
    item.collection_deadline_at = deadline;
    item.days_left_to_collect = deadline ? orderRules.daysLeftUntil(deadline) : null;
    item.collection_status = item.status_category === 'cancelled' ? 'not_required' : collectionStatus;
    item.collection_action_required = item.status_category === 'cancelled' ? false : orderRules.collectionActionRequired({
      parcelType: item.parcel_type,
      hubArrivedAt,
      collectionStatus: item.collection_status
    });
    item.collection_notification_level = item.status_category === 'cancelled'
      ? 'none'
      : orderRules.collectionNotificationLevel({ collectionStatus: item.collection_status, deadline, hubArrivedAt });
    await item.save();
    itemsUpdated += 1;
  }

  console.log(`Repair completed. Orders updated: ${ordersUpdated}. Items updated: ${itemsUpdated}.`);
  await mongoose.disconnect();
}

repair().catch(async (error) => {
  console.error(error);
  try { await mongoose.disconnect(); } catch (_) {}
  process.exit(1);
});
