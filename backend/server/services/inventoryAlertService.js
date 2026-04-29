const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");
const InventoryAlertLog = require("../models/InventoryAlertLog");

function safeNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function getDateKey(date = new Date()) {
  const year = date.getFullYear();
  const month = `${date.getMonth() + 1}`.padStart(2, "0");
  const day = `${date.getDate()}`.padStart(2, "0");
  return `${year}-${month}-${day}`;
}

async function buildLowStockSnapshot() {
  const products = await Product.find({
    $expr: { $lte: ["$stock", "$low_stock_limit"] }
  })
    .sort({ stock: 1, updatedAt: -1 })
    .lean();

  if (!products.length) {
    return [];
  }

  const productIds = products.map((item) => item._id);
  const mappings = await ProductSkuMap.find({ product_id: { $in: productIds } })
    .populate("store_id", "name code")
    .lean();

  const mapByProduct = new Map();
  for (const mapping of mappings) {
    const key = String(mapping.product_id);
    if (!mapByProduct.has(key)) {
      mapByProduct.set(key, []);
    }
    mapByProduct.get(key).push(mapping);
  }

  return products.map((product) => {
    const matches = mapByProduct.get(String(product._id)) || [];
    return {
      product_id: product._id,
      name: product.name,
      sku: product.sku,
      stock: safeNumber(product.stock, 0),
      reserved_stock: safeNumber(product.reserved_stock, 0),
      low_stock_limit: safeNumber(product.low_stock_limit, 0),
      mapped_store_count: new Set(
        matches.map((item) => String(item.store_id?._id || item.store_id || item.store_name || "unknown"))
      ).size,
      mapped_skus: Array.from(new Set(matches.map((item) => item.sku).filter(Boolean)))
    };
  });
}

async function createDailyLowStockAlert({ force = false, triggered_by = "scheduler" } = {}) {
  const alert_date = getDateKey(new Date());

  if (!force) {
    const existing = await InventoryAlertLog.findOne({ alert_date }).lean();
    if (existing) {
      return {
        created: false,
        reused: true,
        alert: existing
      };
    }
  }

  const products = await buildLowStockSnapshot();

  const payload = {
    alert_date,
    total_low_stock_products: products.length,
    total_zero_stock_products: products.filter((item) => safeNumber(item.stock, 0) <= 0).length,
    triggered_by,
    products,
    notes: products.length
      ? `Daily low stock snapshot generated for ${products.length} product(s)`
      : "Daily low stock snapshot generated with no low stock products"
  };

  const alert = await InventoryAlertLog.findOneAndUpdate(
    { alert_date },
    { $set: payload },
    { upsert: true, new: true, setDefaultsOnInsert: true }
  );

  console.log(
    `[Inventory Alerts] ${payload.notes}. Zero stock: ${payload.total_zero_stock_products}`
  );

  return {
    created: true,
    reused: false,
    alert
  };
}

async function getLatestLowStockAlert() {
  return InventoryAlertLog.findOne().sort({ alert_date: -1, createdAt: -1 });
}

module.exports = {
  getDateKey,
  buildLowStockSnapshot,
  createDailyLowStockAlert,
  getLatestLowStockAlert
};
