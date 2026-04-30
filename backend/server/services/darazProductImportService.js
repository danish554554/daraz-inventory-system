const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const CentralInventory = require("../models/CentralInventory");
const { getProducts } = require("./darazApiService");
const { ensureStoreTokenReadyForSync } = require("./darazService");

function safeString(value) {
  return (value ?? "").toString().trim();
}

function toNumber(value, fallback = 0) {
  if (value === undefined || value === null || value === "") return fallback;
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function pickFirstString(source, keys = []) {
  if (!source || typeof source !== "object") return "";

  for (const key of keys) {
    const direct = safeString(source[key]);
    if (direct) return direct;
  }

  return "";
}

function findFirstArray(source, keys = []) {
  if (!source || typeof source !== "object") return [];

  for (const key of keys) {
    if (Array.isArray(source[key])) return source[key];
  }

  for (const value of Object.values(source)) {
    if (Array.isArray(value)) {
      const first = value[0];
      if (
        first &&
        typeof first === "object" &&
        (
          "seller_sku" in first ||
          "SellerSku" in first ||
          "sku" in first ||
          "SkuId" in first ||
          "stock" in first ||
          "quantity" in first
        )
      ) {
        return value;
      }
    }
  }

  return [];
}

function getProductName(product = {}, sku = {}) {
  return (
    pickFirstString(sku, ["product_name", "name", "item_name", "title"]) ||
    pickFirstString(product, ["product_name", "name", "item_name", "title"]) ||
    pickFirstString(product.attributes, ["name", "product_name", "title"]) ||
    pickFirstString(product.primary_category_name, ["name"]) ||
    ""
  );
}

function getProductId(product = {}) {
  return pickFirstString(product, [
    "product_id",
    "item_id",
    "itemId",
    "id",
    "ProductId",
    "ItemId"
  ]);
}

function getSkuId(sku = {}) {
  return pickFirstString(sku, ["sku_id", "SkuId", "skuId", "id"]);
}

function getSellerSku(source = {}) {
  return pickFirstString(source, [
    "seller_sku",
    "SellerSku",
    "sellerSku",
    "shop_sku",
    "ShopSku",
    "sku",
    "Sku"
  ]);
}

function getSkuStock(source = {}) {
  return toNumber(
    source.stock ??
      source.quantity ??
      source.available_stock ??
      source.sellable_stock ??
      source.stock_available ??
      source.package_content_stock ??
      source.warehouse_stock ??
      source.inventory,
    0
  );
}

function normalizeProductPayloads(products = []) {
  const rows = [];

  for (const product of products) {
    if (!product || typeof product !== "object") continue;

    const productId = getProductId(product);
    const productName = getProductName(product);
    const skuRows = findFirstArray(product, [
      "skus",
      "sku_list",
      "SkuList",
      "skuList",
      "variants",
      "variation",
      "seller_skus"
    ]);

    if (skuRows.length) {
      for (const sku of skuRows) {
        if (!sku || typeof sku !== "object") continue;

        rows.push({
          seller_sku: getSellerSku(sku),
          product_name: getProductName(product, sku) || productName,
          stock: getSkuStock(sku),
          daraz_product_id: productId,
          daraz_item_id:
            pickFirstString(sku, ["item_id", "ItemId", "itemId"]) || productId,
          daraz_sku_id: getSkuId(sku)
        });
      }
      continue;
    }

    rows.push({
      seller_sku: getSellerSku(product),
      product_name: productName,
      stock: getSkuStock(product),
      daraz_product_id: productId,
      daraz_item_id: productId,
      daraz_sku_id: getSkuId(product)
    });
  }

  return rows;
}

async function importProductsForStore(storeId, options = {}) {
  const store = await Store.findById(storeId);
  if (!store) {
    throw new Error("Store not found");
  }

  const tokenReady = await ensureStoreTokenReadyForSync(store._id);
  if (!tokenReady?.ok) {
    throw new Error(tokenReady?.message || "Store access token is missing");
  }

  const storeToken =
    tokenReady.token || (await StoreToken.findOne({ store_id: store._id }));

  if (!storeToken || !safeString(storeToken.access_token)) {
    throw new Error("Store access token is missing");
  }

  const limit = Math.min(Math.max(toNumber(options.limit, 50), 1), 100);
  const maxPages = Math.min(Math.max(toNumber(options.maxPages, 20), 1), 100);
  const filter = safeString(options.filter) || "live";

  let offset = toNumber(options.offset, 0);
  let page = 0;
  let imported = 0;
  let updated = 0;
  let skipped = 0;
  let errors = 0;
  const error_details = [];
  const seenKeys = new Set();

  while (page < maxPages) {
    const response = await getProducts({
      storeToken,
      filter,
      offset,
      limit
    });

    const products = Array.isArray(response)
      ? response
      : response?.products || response?.data || [];

    const rows = normalizeProductPayloads(products);

    for (const row of rows) {
      const sellerSku = safeString(row.seller_sku);

      if (!sellerSku) {
        skipped += 1;
        continue;
      }

      const rowKey = `${String(store._id)}:${sellerSku.toLowerCase()}`;
      if (seenKeys.has(rowKey)) {
        skipped += 1;
        continue;
      }
      seenKeys.add(rowKey);

      try {
        const existing = await CentralInventory.findOne({
          store_id: store._id,
          seller_sku: sellerSku
        });

        const update = {
          store_id: store._id,
          seller_sku: sellerSku,
          product_name: safeString(row.product_name) || sellerSku,
          stock: getSkuStock(row),
          daraz_product_id: safeString(row.daraz_product_id),
          daraz_item_id: safeString(row.daraz_item_id),
          daraz_sku_id: safeString(row.daraz_sku_id),
          last_product_import_at: new Date()
        };

        await CentralInventory.findOneAndUpdate(
          { store_id: store._id, seller_sku: sellerSku },
          {
            $set: update,
            $setOnInsert: {
              reserved_stock: 0,
              low_stock_limit: 5
            }
          },
          {
            upsert: true,
            new: true,
            setDefaultsOnInsert: true
          }
        );

        if (existing) {
          updated += 1;
        } else {
          imported += 1;
        }
      } catch (error) {
        errors += 1;
        error_details.push({
          seller_sku: sellerSku,
          error: error.message
        });
      }
    }

    page += 1;
    offset += limit;

    const hasMore =
      response?.hasMore === true ||
      (products.length === limit &&
        (response?.count === undefined || offset < Number(response.count)));

    if (!hasMore) break;
  }

  await StoreToken.updateOne(
    { store_id: store._id },
    { $set: { last_sync_at: new Date(), last_error: errors ? `${errors} product import errors` : "" } }
  );

  return {
    store_id: store._id,
    store_name: store.name,
    filter,
    imported,
    updated,
    skipped,
    errors,
    error_details
  };
}

module.exports = {
  importProductsForStore,
  normalizeProductPayloads
};
