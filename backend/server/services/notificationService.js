const DeviceToken = require("../models/DeviceToken");
const CentralOrder = require("../models/CentralOrder");
const CentralInventory = require("../models/CentralInventory");
const Product = require("../models/Product");

// In-memory alert log history for instant access in Flutter mobile app
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
    const SIX_DAYS_MS = 6 * 24 * 60 * 60 * 1000;
    const FOUR_DAYS_MS = 4 * 24 * 60 * 60 * 1000;

    // Find return/failed orders created in last 7 days that are not marked collected
    const pendingOrders = await CentralOrder.find({
      classification: { $in: ["customer_return", "failed_delivery"] },
      collected_at: null
    }).limit(100);

    const alertsGenerated = [];

    for (const order of pendingOrders) {
      const orderDate = new Date(order.order_date || order.createdAt).getTime();
      const elapsed = now - orderDate;

      if (elapsed >= FOUR_DAYS_MS && elapsed <= SIX_DAYS_MS + 24 * 3600 * 1000) {
        const remainingHours = Math.max(0, Math.round((SIX_DAYS_MS - elapsed) / (1000 * 60 * 60)));
        const title = `🚨 Urgent: 6-Day Scrap Warning (Order #${order.order_number || order.external_order_id})`;
        const body = `Parcel for "${order.product_title || 'Daraz Item'}" is at risk of being scrapped in ~${remainingHours}h. Collect at hub immediately!`;

        const alert = await this.recordAlert({
          type: "scrap_warning",
          title,
          body,
          data: {
            order_id: order._id.toString(),
            order_number: order.order_number,
            store_name: order.store_name,
            remaining_hours: remainingHours
          }
        });

        alertsGenerated.push(alert);
      }
    }

    return alertsGenerated;
  }

  async runLowStockAudit() {
    const products = await Product.find({ is_active: true });
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
