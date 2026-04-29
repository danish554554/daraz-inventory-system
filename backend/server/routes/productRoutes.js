const express = require("express");
const router = express.Router();

const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");
const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const CentralInventory = require("../models/CentralInventory");
const InventoryTransaction = require("../models/InventoryTransaction");
const { getProducts } = require("../services/darazApiService");
const { ensureStoreTokenReadyForSync, isLiveApiEnabled } = require("../services/darazService");

function safeString(value) {
  return (value || "").toString().trim();
}

function toNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function cleanProductName(title = "") {
  const raw = safeString(title).replace(/[-_|]+/g, " ").replace(/\s+/g, " ");
  if (!raw) return "Untitled Product";

  const stopWords = new Set([
    "for", "with", "and", "the", "a", "an", "in", "on", "to", "of", "new",
    "best", "original", "premium", "high", "quality", "latest", "free", "delivery"
  ]);

  const words = raw.split(" ").filter(Boolean);
  const selected = [];
  for (const word of words) {
    const normalized = word.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (selected.length >= 5) break;
    if (selected.length >= 3 && stopWords.has(normalized)) continue;
    selected.push(word);
  }

  return (selected.length ? selected : words.slice(0, 5)).join(" ").slice(0, 80);
}

function normalizeSkuRows(rows = []) {
  if (!Array.isArray(rows)) return [];
  const seen = new Set();
  const cleaned = [];

  for (const item of rows) {
    const sku = safeString(item?.sku || item?.seller_sku || item?.SellerSku || item?.SellerSKU);
    if (!sku) continue;
    const key = sku.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    cleaned.push({
      sku,
      store_id: item?.store_id || null,
      store_name: safeString(item?.store_name),
      listing_title: safeString(item?.listing_title || item?.title || item?.name),
      image_url: safeString(item?.image_url || item?.image || item?.main_image),
      store_product_id: safeString(item?.store_product_id || item?.item_id || item?.product_id),
      status: safeString(item?.status || "active")
    });
  }

  return cleaned;
}

async function attachSkuMaps(products) {
  const list = Array.isArray(products) ? products : [products];
  const ids = list.map((item) => item._id);
  const maps = await ProductSkuMap.find({ product_id: { $in: ids } })
    .populate("store_id", "name code")
    .sort({ createdAt: 1 })
    .lean();

  const byProduct = new Map();
  for (const map of maps) {
    const key = String(map.product_id);
    if (!byProduct.has(key)) byProduct.set(key, []);
    byProduct.get(key).push({
      _id: map._id,
      sku: map.sku,
      store_id: map.store_id?._id || map.store_id,
      store_name: map.store_id?.name || map.store_name || "",
      store_code: map.store_id?.code || "",
      listing_title: map.listing_title || "",
      image_url: map.image_url || "",
      store_product_id: map.store_product_id || "",
      status: map.status || "active"
    });
  }

  return list.map((doc) => {
    const product = doc.toObject ? doc.toObject() : doc;
    const linked = byProduct.get(String(product._id)) || [];
    return {
      ...product,
      master_sku: product.sku,
      available_stock: Math.max(toNumber(product.stock) - toNumber(product.reserved_stock), 0),
      linked_skus: linked,
      extra_skus: linked,
      linked_store_count: new Set(linked.map((item) => safeString(item.store_id || item.store_name)).filter(Boolean)).size,
      linked_skus_text: linked.map((item) => `${item.store_name || item.store_code || "Store"}:${item.sku}`).join(", ")
    };
  });
}

async function skuConflictMessage({ masterSku, linkedSkus, excludeProductId = null }) {
  const all = [masterSku, ...linkedSkus.map((item) => item.sku)].filter(Boolean);
  const seen = new Set();

  for (const sku of all) {
    const key = sku.toLowerCase();
    if (seen.has(key)) return `Duplicate SKU in this product: ${sku}`;
    seen.add(key);
  }

  const productConflict = await Product.findOne({
    sku: masterSku,
    ...(excludeProductId ? { _id: { $ne: excludeProductId } } : {})
  });
  if (productConflict) return `Master SKU already exists: ${masterSku}`;

  for (const sku of all) {
    const mapConflict = await ProductSkuMap.findOne({ sku });
    if (mapConflict && String(mapConflict.product_id) !== String(excludeProductId || "")) {
      return `Store SKU already linked to another product: ${sku}`;
    }
  }

  for (const item of linkedSkus) {
    const usedAsMaster = await Product.findOne({
      sku: item.sku,
      ...(excludeProductId ? { _id: { $ne: excludeProductId } } : {})
    });
    if (usedAsMaster) return `Store SKU already used as another product master SKU: ${item.sku}`;
  }

  return null;
}

function productPayload(body = {}) {
  const name = safeString(body.name || body.product_name);
  const sku = safeString(body.master_sku || body.sku);
  return {
    name,
    sku,
    stock: Math.max(0, toNumber(body.stock, 0)),
    reserved_stock: Math.max(0, toNumber(body.reserved_stock, 0)),
    purchase_price: Math.max(0, toNumber(body.purchase_price, 0)),
    selling_price: Math.max(0, toNumber(body.selling_price, 0)),
    low_stock_limit: Math.max(0, toNumber(body.low_stock_limit, 5)),
    image_url: safeString(body.image_url),
    source_title: safeString(body.source_title || body.listing_title)
  };
}

async function saveSkuMaps(productId, linkedSkus = []) {
  await ProductSkuMap.deleteMany({ product_id: productId });
  if (!linkedSkus.length) return;

  await ProductSkuMap.insertMany(linkedSkus.map((item) => ({
    product_id: productId,
    store_id: item.store_id || null,
    sku: item.sku,
    store_name: item.store_name,
    listing_title: item.listing_title,
    image_url: item.image_url,
    store_product_id: item.store_product_id,
    status: item.status || "active"
  })));
}

router.get("/low-stock", async (req, res) => {
  try {
    const products = await Product.find({ $expr: { $lte: ["$stock", "$low_stock_limit"] } }).sort({ updatedAt: -1 });
    res.json(await attachSkuMaps(products));
  } catch (error) {
    res.status(500).json({ message: "Error fetching low stock products", error: error.message });
  }
});

router.get("/", async (req, res) => {
  try {
    const search = safeString(req.query.search);
    const filter = safeString(req.query.filter || "all");
    const query = {};
    if (search) {
      query.$or = [
        { name: { $regex: search, $options: "i" } },
        { sku: { $regex: search, $options: "i" } }
      ];
    }

    let products = await Product.find(query).sort({ updatedAt: -1, created_at: -1 });
    let enriched = await attachSkuMaps(products);

    if (search) {
      const matchingMaps = await ProductSkuMap.find({ sku: { $regex: search, $options: "i" } }).distinct("product_id");
      if (matchingMaps.length) {
        const extra = await Product.find({ _id: { $in: matchingMaps, $nin: products.map((p) => p._id) } });
        enriched = [...enriched, ...(await attachSkuMaps(extra))];
      }
    }

    if (filter === "low") enriched = enriched.filter((item) => item.stock <= item.low_stock_limit && item.stock > 0);
    if (filter === "out") enriched = enriched.filter((item) => item.stock <= 0);
    if (filter === "instock") enriched = enriched.filter((item) => item.stock > item.low_stock_limit);

    res.json(enriched);
  } catch (error) {
    res.status(500).json({ message: "Error fetching products", error: error.message });
  }
});

router.get("/import-preview", async (req, res) => {
  try {
    const storeId = safeString(req.query.store_id);
    if (!storeId) return res.status(400).json({ message: "Store is required" });

    const store = await Store.findById(storeId).lean();
    if (!store) return res.status(404).json({ message: "Store not found" });

    let listings = [];
    let source = "central_inventory";

    if (isLiveApiEnabled()) {
      try {
        const storeToken = await ensureStoreTokenReadyForSync(store._id);
        const result = await getProducts({ storeToken, limit: 100, offset: 0, status: "active" });
        listings = result.products;
        source = "daraz_api";
      } catch (error) {
        source = `central_inventory_fallback: ${error.message}`;
      }
    }

    if (!listings.length) {
      const rows = await CentralInventory.find({ store_id: store._id }).limit(100).lean();
      listings = rows.map((item) => ({
        title: item.product_name || item.seller_sku,
        seller_sku: item.seller_sku,
        sku: item.seller_sku,
        quantity: item.stock,
        image_url: item.image_url || "",
        status: "active"
      }));
    }

    const existingSkus = new Set((await ProductSkuMap.find({ sku: { $in: listings.map((item) => safeString(item.seller_sku || item.sku)).filter(Boolean) } }).distinct("sku")).map((item) => item.toLowerCase()));

    const preview = listings.map((item) => {
      const title = safeString(item.title || item.name || item.product_name || item.item_name);
      const sku = safeString(item.seller_sku || item.sku || item.SellerSku || item.shop_sku);
      const image = safeString(item.image_url || item.image || item.main_image || item.images?.[0]);
      return {
        store_id: store._id,
        store_name: store.name,
        title,
        suggested_name: cleanProductName(title),
        sku,
        stock: toNumber(item.quantity || item.stock || item.available || 0),
        image_url: image,
        store_product_id: safeString(item.item_id || item.product_id || item.id),
        status: safeString(item.status || "active"),
        already_imported: existingSkus.has(sku.toLowerCase())
      };
    }).filter((item) => item.sku);

    res.json({ store, source, count: preview.length, products: preview });
  } catch (error) {
    res.status(500).json({ message: "Error preparing import preview", error: error.message });
  }
});

router.post("/import", async (req, res) => {
  try {
    const storeId = safeString(req.body.store_id);
    const items = Array.isArray(req.body.products) ? req.body.products : [];
    if (!storeId) return res.status(400).json({ message: "Store is required" });
    if (!items.length) return res.status(400).json({ message: "No products selected" });

    const store = await Store.findById(storeId).lean();
    if (!store) return res.status(404).json({ message: "Store not found" });

    const created = [];
    const skipped = [];

    for (const item of items) {
      const sku = safeString(item.sku || item.seller_sku);
      if (!sku) continue;
      const existingMap = await ProductSkuMap.findOne({ sku });
      const existingProduct = await Product.findOne({ sku });
      if (existingMap || existingProduct) {
        skipped.push({ sku, reason: "Already imported or used" });
        continue;
      }

      const title = safeString(item.title || item.name || item.product_name);
      const name = safeString(item.name || item.suggested_name) || cleanProductName(title);
      const product = await Product.create({
        name,
        sku,
        stock: Math.max(0, toNumber(item.stock, 0)),
        purchase_price: Math.max(0, toNumber(item.purchase_price, 0)),
        low_stock_limit: Math.max(0, toNumber(item.low_stock_limit, 5)),
        image_url: safeString(item.image_url),
        source_title: title
      });

      await ProductSkuMap.create({
        product_id: product._id,
        store_id: store._id,
        store_name: store.name,
        sku,
        listing_title: title,
        image_url: safeString(item.image_url),
        store_product_id: safeString(item.store_product_id),
        status: safeString(item.status || "active")
      });
      created.push(product);
    }

    res.json({ message: `Imported ${created.length} product(s)`, created: await attachSkuMaps(created), skipped });
  } catch (error) {
    res.status(500).json({ message: "Error importing products", error: error.message });
  }
});

router.post("/add-product", async (req, res) => {
  try {
    const payload = productPayload(req.body);
    if (!payload.name || !payload.sku) return res.status(400).json({ message: "Product name and master SKU are required" });
    const linkedSkus = normalizeSkuRows(req.body.linked_skus || req.body.extra_skus);
    const conflict = await skuConflictMessage({ masterSku: payload.sku, linkedSkus });
    if (conflict) return res.status(400).json({ message: conflict });

    const product = await Product.create(payload);
    await saveSkuMaps(product._id, linkedSkus);
    const [enriched] = await attachSkuMaps([product]);
    res.json({ message: "Product added successfully", product: enriched });
  } catch (error) {
    res.status(500).json({ message: "Error adding product", error: error.message });
  }
});

router.post("/:id/stock", async (req, res) => {
  try {
    const product = await Product.findById(req.params.id);
    if (!product) return res.status(404).json({ message: "Product not found" });

    const type = safeString(req.body.type || "add");
    const qty = Math.max(1, toNumber(req.body.quantity, 0));
    const before = toNumber(product.stock, 0);
    const after = type === "deduct" ? Math.max(0, before - qty) : before + qty;
    product.stock = after;
    if (req.body.purchase_price !== undefined) product.purchase_price = Math.max(0, toNumber(req.body.purchase_price, product.purchase_price));
    await product.save();

    await InventoryTransaction.create({
      inventory_id: product._id,
      seller_sku: product.sku,
      master_sku: product.sku,
      product_name: product.name,
      transaction_type: type === "deduct" ? "manual_deduct" : "manual_add",
      quantity: type === "deduct" ? -qty : qty,
      stock_before: before,
      stock_after: after,
      note: safeString(req.body.note || "Manual product stock update")
    });

    const [enriched] = await attachSkuMaps([product]);
    res.json({ message: "Stock updated successfully", product: enriched });
  } catch (error) {
    res.status(500).json({ message: "Error updating stock", error: error.message });
  }
});

router.post("/merge", async (req, res) => {
  try {
    const productIds = Array.isArray(req.body.product_ids) ? req.body.product_ids.filter(Boolean) : [];
    const masterProductId = safeString(req.body.master_product_id || productIds[0]);
    if (productIds.length < 2) return res.status(400).json({ message: "Select at least two products to merge" });
    if (!masterProductId) return res.status(400).json({ message: "Master product is required" });

    const products = await Product.find({ _id: { $in: productIds } });
    const master = products.find((item) => String(item._id) === masterProductId);
    if (!master) return res.status(404).json({ message: "Master product not found" });

    const duplicateIds = products.filter((item) => String(item._id) !== masterProductId).map((item) => item._id);
    const duplicateMaps = await ProductSkuMap.find({ product_id: { $in: duplicateIds } }).lean();

    const mapsToAdd = [];
    for (const product of products) {
      if (String(product._id) === masterProductId) continue;
      mapsToAdd.push({
        product_id: master._id,
        sku: product.sku,
        store_name: "Imported product",
        listing_title: product.source_title || product.name,
        image_url: product.image_url || "",
        status: "active"
      });
    }
    for (const map of duplicateMaps) {
      mapsToAdd.push({
        product_id: master._id,
        store_id: map.store_id || null,
        sku: map.sku,
        store_name: map.store_name || "",
        listing_title: map.listing_title || "",
        image_url: map.image_url || "",
        store_product_id: map.store_product_id || "",
        status: map.status || "active"
      });
    }

    master.stock = products.reduce((sum, item) => sum + toNumber(item.stock, 0), 0);
    master.reserved_stock = products.reduce((sum, item) => sum + toNumber(item.reserved_stock, 0), 0);
    master.purchase_price = master.purchase_price || products.find((item) => toNumber(item.purchase_price) > 0)?.purchase_price || 0;
    master.image_url = master.image_url || products.find((item) => safeString(item.image_url))?.image_url || "";
    await master.save();

    await ProductSkuMap.deleteMany({ product_id: { $in: duplicateIds } });
    for (const map of mapsToAdd) {
      await ProductSkuMap.updateOne({ sku: map.sku }, { $set: map }, { upsert: true });
    }
    await Product.deleteMany({ _id: { $in: duplicateIds } });

    const [enriched] = await attachSkuMaps([master]);
    res.json({ message: "Products merged successfully", product: enriched });
  } catch (error) {
    res.status(500).json({ message: "Error merging products", error: error.message });
  }
});

router.get("/:id", async (req, res) => {
  try {
    const product = await Product.findById(req.params.id);
    if (!product) return res.status(404).json({ message: "Product not found" });
    const [enriched] = await attachSkuMaps([product]);
    res.json(enriched);
  } catch (error) {
    res.status(500).json({ message: "Error fetching product", error: error.message });
  }
});

router.put("/:id", async (req, res) => {
  try {
    const payload = productPayload(req.body);
    if (!payload.name || !payload.sku) return res.status(400).json({ message: "Product name and master SKU are required" });
    const linkedSkus = normalizeSkuRows(req.body.linked_skus || req.body.extra_skus);
    const conflict = await skuConflictMessage({ masterSku: payload.sku, linkedSkus, excludeProductId: req.params.id });
    if (conflict) return res.status(400).json({ message: conflict });

    const product = await Product.findByIdAndUpdate(req.params.id, payload, { new: true, runValidators: true });
    if (!product) return res.status(404).json({ message: "Product not found" });
    await saveSkuMaps(product._id, linkedSkus);
    const [enriched] = await attachSkuMaps([product]);
    res.json({ message: "Product updated successfully", product: enriched });
  } catch (error) {
    res.status(500).json({ message: "Error updating product", error: error.message });
  }
});

router.delete("/:id", async (req, res) => {
  try {
    const product = await Product.findByIdAndDelete(req.params.id);
    if (!product) return res.status(404).json({ message: "Product not found" });
    await ProductSkuMap.deleteMany({ product_id: req.params.id });
    res.json({ message: "Product deleted successfully" });
  } catch (error) {
    res.status(500).json({ message: "Error deleting product", error: error.message });
  }
});

module.exports = router;
