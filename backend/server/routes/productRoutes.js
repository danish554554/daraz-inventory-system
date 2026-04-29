const express = require("express");
const router = express.Router();
const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");

function normalizeExtraSkus(extraSkus = []) {
  if (!Array.isArray(extraSkus)) return [];

  const cleaned = [];
  const seen = new Set();

  for (const item of extraSkus) {
    const sku = (item?.sku || "").toString().trim();
    const store_name = (item?.store_name || "").toString().trim();

    if (!sku) continue;

    const key = sku.toLowerCase();
    if (seen.has(key)) continue;

    seen.add(key);
    cleaned.push({ sku, store_name });
  }

  return cleaned;
}

async function attachExtraSkusToProducts(products) {
  const productList = Array.isArray(products) ? products : [products];
  const productIds = productList.map((item) => item._id);

  const mappings = await ProductSkuMap.find({
    product_id: { $in: productIds }
  }).sort({ createdAt: 1 });

  const mappingByProductId = {};
  for (const item of mappings) {
    const key = item.product_id.toString();
    if (!mappingByProductId[key]) mappingByProductId[key] = [];
    mappingByProductId[key].push({
      _id: item._id,
      sku: item.sku,
      store_name: item.store_name
    });
  }

  return productList.map((productDoc) => {
    const product = productDoc.toObject ? productDoc.toObject() : productDoc;
    return {
      ...product,
      extra_skus: mappingByProductId[product._id.toString()] || []
    };
  });
}

async function validateSkuUniqueness({
  primarySku,
  extraSkus,
  excludeProductId = null
}) {
  const allSkus = [primarySku, ...extraSkus.map((item) => item.sku)];

  const uniqueCheck = new Set();
  for (const sku of allSkus) {
    const key = sku.toLowerCase();
    if (uniqueCheck.has(key)) {
      return `Duplicate SKU found in submitted data: ${sku}`;
    }
    uniqueCheck.add(key);
  }

  const primaryConflict = await Product.findOne({
    sku: primarySku,
    ...(excludeProductId ? { _id: { $ne: excludeProductId } } : {})
  });

  if (primaryConflict) {
    return `Primary SKU already exists: ${primarySku}`;
  }

  const primaryInMappings = await ProductSkuMap.findOne({ sku: primarySku });
  if (primaryInMappings && primaryInMappings.product_id.toString() !== String(excludeProductId || "")) {
    return `Primary SKU already exists in extra store SKUs: ${primarySku}`;
  }

  for (const item of extraSkus) {
    const productConflict = await Product.findOne({
      sku: item.sku,
      ...(excludeProductId ? { _id: { $ne: excludeProductId } } : {})
    });

    if (productConflict) {
      return `Extra SKU already used as product SKU: ${item.sku}`;
    }

    const mapConflict = await ProductSkuMap.findOne({ sku: item.sku });

    if (
      mapConflict &&
      mapConflict.product_id.toString() !== String(excludeProductId || "")
    ) {
      return `Extra SKU already exists: ${item.sku}`;
    }
  }

  return null;
}

// Low stock route first
router.get("/low-stock", async (req, res) => {
  try {
    const products = await Product.find({
      $expr: { $lte: ["$stock", "$low_stock_limit"] }
    }).sort({ created_at: -1 });

    const enriched = await attachExtraSkusToProducts(products);
    res.json(enriched);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching low stock products",
      error: error.message
    });
  }
});

// Add product
router.post("/add-product", async (req, res) => {
  try {
    const {
      name,
      sku,
      stock = 0,
      purchase_price = 0,
      selling_price = 0,
      low_stock_limit = 5,
      extra_skus = []
    } = req.body;

    if (!name || !sku) {
      return res.status(400).json({
        message: "Name and SKU are required"
      });
    }

    const normalizedPrimarySku = sku.trim();
    const normalizedExtraSkus = normalizeExtraSkus(extra_skus);

    const conflictMessage = await validateSkuUniqueness({
      primarySku: normalizedPrimarySku,
      extraSkus: normalizedExtraSkus
    });

    if (conflictMessage) {
      return res.status(400).json({ message: conflictMessage });
    }

    const product = await Product.create({
      name: name.trim(),
      sku: normalizedPrimarySku,
      stock: Number(stock) || 0,
      purchase_price: Number(purchase_price) || 0,
      selling_price: Number(selling_price) || 0,
      low_stock_limit: Number(low_stock_limit) || 5
    });

    if (normalizedExtraSkus.length) {
      await ProductSkuMap.insertMany(
        normalizedExtraSkus.map((item) => ({
          product_id: product._id,
          sku: item.sku,
          store_name: item.store_name
        }))
      );
    }

    const [enrichedProduct] = await attachExtraSkusToProducts([product]);

    res.json({
      message: "Product added successfully",
      product: enrichedProduct
    });
  } catch (error) {
    res.status(500).json({
      message: "Error adding product",
      error: error.message
    });
  }
});

// Get all products
router.get("/", async (req, res) => {
  try {
    const products = await Product.find().sort({ created_at: -1 });
    const enriched = await attachExtraSkusToProducts(products);
    res.json(enriched);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching products",
      error: error.message
    });
  }
});

// Get single product
router.get("/:id", async (req, res) => {
  try {
    const product = await Product.findById(req.params.id);

    if (!product) {
      return res.status(404).json({
        message: "Product not found"
      });
    }

    const [enrichedProduct] = await attachExtraSkusToProducts([product]);
    res.json(enrichedProduct);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching product",
      error: error.message
    });
  }
});

// Update product
router.put("/:id", async (req, res) => {
  try {
    const {
      name,
      sku,
      stock,
      purchase_price,
      selling_price,
      low_stock_limit,
      extra_skus = []
    } = req.body;

    if (!name || !sku) {
      return res.status(400).json({
        message: "Name and SKU are required"
      });
    }

    const normalizedPrimarySku = sku.trim();
    const normalizedExtraSkus = normalizeExtraSkus(extra_skus);

    const conflictMessage = await validateSkuUniqueness({
      primarySku: normalizedPrimarySku,
      extraSkus: normalizedExtraSkus,
      excludeProductId: req.params.id
    });

    if (conflictMessage) {
      return res.status(400).json({ message: conflictMessage });
    }

    const product = await Product.findByIdAndUpdate(
      req.params.id,
      {
        name: name.trim(),
        sku: normalizedPrimarySku,
        stock: Number(stock) || 0,
        purchase_price: Number(purchase_price) || 0,
        selling_price: Number(selling_price) || 0,
        low_stock_limit: Number(low_stock_limit) || 5
      },
      {
        new: true,
        runValidators: true
      }
    );

    if (!product) {
      return res.status(404).json({
        message: "Product not found"
      });
    }

    await ProductSkuMap.deleteMany({ product_id: product._id });

    if (normalizedExtraSkus.length) {
      await ProductSkuMap.insertMany(
        normalizedExtraSkus.map((item) => ({
          product_id: product._id,
          sku: item.sku,
          store_name: item.store_name
        }))
      );
    }

    const [enrichedProduct] = await attachExtraSkusToProducts([product]);

    res.json({
      message: "Product updated successfully",
      product: enrichedProduct
    });
  } catch (error) {
    res.status(500).json({
      message: "Error updating product",
      error: error.message
    });
  }
});

// Delete product
router.delete("/:id", async (req, res) => {
  try {
    const deletedProduct = await Product.findByIdAndDelete(req.params.id);

    if (!deletedProduct) {
      return res.status(404).json({
        message: "Product not found"
      });
    }

    await ProductSkuMap.deleteMany({ product_id: req.params.id });

    res.json({
      message: "Product deleted successfully"
    });
  } catch (error) {
    res.status(500).json({
      message: "Error deleting product",
      error: error.message
    });
  }
});

module.exports = router;