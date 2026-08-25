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


function hasNonLatin(text = "") {
  return /[^\u0000-\u007f]/.test(safeString(text));
}

function buildDisplayTitle(title = "", sku = "") {
  const cleanTitle = safeString(title);
  if (cleanTitle && !hasNonLatin(cleanTitle)) return cleanTitle;

  const skuText = safeString(sku)
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  if (skuText) return skuText;
  return cleanTitle || "Daraz Product";
}

function pickEnglishTitle(product = {}, sku = {}) {
  return (
    pickFirstString(sku, ["display_title", "english_title", "title_en", "name_en", "product_name_en"]) ||
    pickFirstString(product, ["display_title", "english_title", "title_en", "name_en", "product_name_en"]) ||
    pickFirstString(product.attributes, ["english_title", "title_en", "name_en", "product_name_en"])
  );
}

function normalizeImageValue(value) {
  if (!value) return "";
  if (typeof value === "string") return safeString(value);
  if (Array.isArray(value)) {
    for (const entry of value) {
      const url = normalizeImageValue(entry);
      if (url) return url;
    }
  }
  if (typeof value === "object") {
    return pickFirstString(value, ["url", "image_url", "image", "src", "main_image", "thumbnail", "large", "medium"]);
  }
  return "";
}

function getVariationName(product = {}, sku = {}) {
  return (
    pickFirstString(sku, [
      "variation_name",
      "variation",
      "variationName",
      "color_family",
      "ColorFamily",
      "size",
      "Size",
      "name"
    ]) ||
    pickFirstString(product, ["variation_name", "variation"]) ||
    pickFirstString(product.attributes, ["variation_name", "variation", "color_family", "size"])
  );
}

function getProductImage(product = {}, sku = {}) {
  const skuImage = normalizeImageValue(
    sku.image_url || sku.image || sku.main_image || sku.thumbnail || sku.Images || sku.images
  );
  if (skuImage) return skuImage;

  return normalizeImageValue(
    product.main_image ||
      product.primary_image ||
      product.image_url ||
      product.image ||
      product.thumbnail ||
      product.Images ||
      product.images ||
      product.product_images ||
      product.ProductImage
  );
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

function getSkuPrice(source = {}) {
  return toNumber(
    source.special_price ??
      source.price ??
      source.package_price ??
      source.sale_price ??
      source.unit_price,
    0
  );
}

function getProductStatus(product = {}, sku = {}) {
  const val =
    pickFirstString(sku, ["status", "Status", "sub_status", "SubStatus", "state", "State"]) ||
    pickFirstString(product, ["status", "Status", "sub_status", "SubStatus", "state", "State"]);
  return val ? val.toLowerCase().trim() : "active";
}

function isInactiveStatus(status = "") {
  const s = String(status || "").toLowerCase().trim();
  return (
    s === "inactive" ||
    s === "deleted" ||
    s === "suspended" ||
    s === "draft" ||
    s === "offline" ||
    s === "deactivated" ||
    s === "unapproved" ||
    s === "rejected" ||
    s === "disabled"
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

        const sellerSku = getSellerSku(sku);
        const originalTitle = getProductName(product, sku) || productName;
        const englishTitle = pickEnglishTitle(product, sku);
        const status = getProductStatus(product, sku);

        rows.push({
          seller_sku: sellerSku,
          product_name: originalTitle,
          original_product_name: originalTitle,
          display_title: englishTitle || buildDisplayTitle(originalTitle, sellerSku),
          image_url: getProductImage(product, sku),
          stock: getSkuStock(sku),
          selling_price: getSkuPrice(sku) || getSkuPrice(product),
          daraz_product_id: productId,
          daraz_item_id:
            pickFirstString(sku, ["item_id", "ItemId", "itemId"]) || productId,
          daraz_sku_id: getSkuId(sku),
          variation_name: getVariationName(product, sku),
          status
        });
      }
      continue;
    }

    const sellerSku = getSellerSku(product);
    const englishTitle = pickEnglishTitle(product, {});
    const status = getProductStatus(product, {});

    rows.push({
      seller_sku: sellerSku,
      product_name: productName,
      original_product_name: productName,
      display_title: englishTitle || buildDisplayTitle(productName, sellerSku),
      image_url: getProductImage(product, {}),
      stock: getSkuStock(product),
      selling_price: getSkuPrice(product),
      daraz_product_id: productId,
      daraz_item_id: productId,
      daraz_sku_id: getSkuId(product),
      variation_name: getVariationName(product, {}),
      status
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
  const filter = safeString(options.filter) || "all";

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
        const skuRegex = new RegExp(`^${sellerSku.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i');

        if (isInactiveStatus(row.status)) {
          // If this product was made inactive from store listing in Daraz,
          // automatically mark it inactive and archived so it disappears from the stock list!
          await CentralInventory.updateMany(
            { seller_sku: { $regex: skuRegex } },
            { $set: { is_archived: true, is_deleted: true, status: 'inactive' } }
          );
          const Product = require('../models/Product');
          await Product.updateMany(
            { sku: { $regex: skuRegex } },
            { $set: { is_active: false, status: 'inactive' } }
          );
          skipped += 1;
          continue;
        }

        // Check if SKU is already present in active central inventory across any store
        const alreadyInInventory = await CentralInventory.findOne({
          seller_sku: { $regex: skuRegex },
          is_archived: { $ne: true },
          is_deleted: { $ne: true },
          status: { $nin: ['archived', 'inactive', 'deleted', 'suspended', 'draft', 'offline', 'disabled', 'rejected'] }
        });

        if (alreadyInInventory) {
          // Product with this SKU is already imported and present in stock list - ignore to prevent duplicate SKUs
          skipped += 1;
          continue;
        }

        // Check if SKU is in an active merge group
        const InventoryMergeGroup = require('../models/InventoryMergeGroup');
        const alreadyInMergeGroup = await InventoryMergeGroup.findOne({
          master_sku: { $regex: skuRegex }
        });
        if (alreadyInMergeGroup) {
          skipped += 1;
          continue;
        }

        // Check if SKU was removed / archived / deleted
        const archivedItem = await CentralInventory.findOne({
          seller_sku: { $regex: skuRegex },
          $or: [{ is_archived: true }, { is_deleted: true }, { status: { $in: ['archived', 'inactive', 'deleted', 'suspended'] } }]
        });
        if (archivedItem) {
          skipped += 1;
          continue;
        }

        const Product = require('../models/Product');
        const existingProduct = await Product.findOne({ sku: { $regex: skuRegex } }).lean();
        if (existingProduct?.is_active === false || existingProduct?.status === 'archived' || existingProduct?.status === 'inactive' || existingProduct?.status === 'deleted') {
          skipped += 1;
          continue;
        }

        const initialStock = existingProduct?.stock > 0 ? existingProduct.stock : 0;
        const initialCost = existingProduct?.purchase_price > 0 ? existingProduct.purchase_price : 0;

        const update = {
          store_id: store._id,
          seller_sku: sellerSku,
          product_name: safeString(row.product_name) || sellerSku,
          original_product_name: safeString(row.original_product_name || row.product_name),
          display_title: safeString(row.display_title) || buildDisplayTitle(row.product_name, sellerSku),
          image_url: safeString(row.image_url),
          daraz_product_id: safeString(row.daraz_product_id),
          daraz_item_id: safeString(row.daraz_item_id),
          daraz_sku_id: safeString(row.daraz_sku_id),
          variation_name: safeString(row.variation_name),
          selling_price: toNumber(row.selling_price, 0),
          last_product_import_at: new Date()
        };

        await CentralInventory.create({
          ...update,
          stock: initialStock,
          purchase_price: initialCost,
          cost_price: initialCost,
          reserved_stock: 0,
          low_stock_limit: existingProduct?.low_stock_limit || 5,
          is_archived: false,
          is_deleted: false,
          status: 'active'
        });

        imported += 1;
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
