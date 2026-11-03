const DeviceToken = require("../models/DeviceToken");
const CentralOrderItem = require("../models/CentralOrderItem");
const Product = require("../models/Product");

// ponytail: in-memory alert history, lost on restart; persist to a model if a client starts reading /notifications/history
const recentAlerts = [];

class NotificationService {
  async registerToken({ token, platform = "android", userId = "admin" }) {
    if (!token || typeof token !== "string") {
      throw new Error("Device token is required.");
    }

    const cleanToken = token.trim();
    const updated = await DeviceToken.findOneAndUpdate(
      { token: cleanToken },
      {
        token: cleanToken,
        platform,
        user_id: userId,
        is_active: true,
        last_active_at: new Date()
      },
      { upsert: true, returnDocument: "after" }
    );

    return updated;
  }

  async recordAlert({ type, title, body, data = {} }) {
    const alertEntry = {
      id: Date.now().toString(),
      type, // 'scrap_warning', 'low_stock', 'order_alert', 'system'
      title,
      body,
      data,
      created_at: new Date().toISOString(),
      read: false
    };

    recentAlerts.unshift(alertEntry);
    if (recentAlerts.length > 50) {
      recentAlerts.pop();
    }

    return alertEntry;
  }

  getAlertHistory() {
    return recentAlerts;
  }

  async runScrapRiskAudit() {
    const now = Date.now();
    const TWO_DAYS_MS = 2 * 24 * 60 * 60 * 1000;

    // Return / failed-delivery parcels waiting at the hub whose collection deadline is within 2 days (or passed)
    const pendingItems = await CentralOrderItem.find({
      parcel_type: { $in: ["return", "failed_delivery"] },
      collection_action_required: true,
      collection_deadline_at: { $ne: null, $lte: new Date(now + TWO_DAYS_MS) }
    })
      .populate("order_id", "order_number external_order_id")
      .populate("store_id", "name")
      .sort({ collection_deadline_at: 1 })
      .limit(100)
      .lean();

    const alertsGenerated = [];

    for (const item of pendingItems) {
      const remainingHours = Math.round((new Date(item.collection_deadline_at).getTime() - now) / (1000 * 60 * 60));
      const orderNumber = item.order_id?.order_number || item.order_id?.external_order_id || "";
      const title = `🚨 Urgent: Scrap Warning (Order #${orderNumber})`;
      const body = remainingHours > 0
        ? `Parcel for "${item.display_title || item.product_name || "Daraz Item"}" is at risk of being scrapped in ~${remainingHours}h. Collect at ${item.hub_name || "the hub"} immediately!`
        : `Parcel for "${item.display_title || item.product_name || "Daraz Item"}" is past its collection deadline at ${item.hub_name || "the hub"}.`;

      const alert = await this.recordAlert({
        type: "scrap_warning",
        title,
        body,
        data: {
          order_item_id: item._id.toString(),
          order_number: orderNumber,
          store_name: item.store_id?.name || "",
          remaining_hours: Math.max(0, remainingHours)
        }
      });

      alertsGenerated.push(alert);
    }

    return alertsGenerated;
  }

  async runLowStockAudit() {
    const products = await Product.find({ is_active: { $ne: false } });
    const alertsGenerated = [];

    for (const prod of products) {
      const lowLimit = prod.low_stock_limit || 5;
      if (prod.stock <= lowLimit) {
        const title = `⚠️ Low Stock Warning: ${prod.sku || prod.name}`;
        const body = `Only ${prod.stock} unit(s) remaining for "${prod.name}". Reorder now to prevent stockouts!`;

        const alert = await this.recordAlert({
          type: "low_stock",
          title,
          body,
          data: {
            product_id: prod._id.toString(),
            sku: prod.sku,
            stock: prod.stock,
            low_limit: lowLimit
          }
        });

        alertsGenerated.push(alert);
      }
    }

    return alertsGenerated;
  }
}

module.exports = new NotificationService();
