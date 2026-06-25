const express = require("express");
const router = express.Router();

const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");
const Order = require("../models/Order");
const orderController = require("../controllers/orderController");

async function findProductBySkuAlias(rawSku = "") {
  const sku = rawSku.toString().trim();
  if (!sku) return null;

  let product = await Product.findOne({ sku });
  if (product) {
    return {
      product,
      matched_sku: sku,
      matched_by: "primary_sku"
    };
  }

  const skuMap = await ProductSkuMap.findOne({ sku });
  if (skuMap) {
    product = await Product.findById(skuMap.product_id);
    if (product) {
      return {
        product,
        matched_sku: sku,
        matched_by: "mapped_sku"
      };
    }
  }

  return null;
}

router.post("/manual-order", orderController.createManualOrder);

// Old compatibility route
router.post("/add-order", async (req, res) => {
  try {
    const {
      product_id,
      sku,
      seller_sku,
      store_sku,
      quantity,
      sale_price = 0
    } = req.body;

    if (!quantity) {
      return res.status(400).json({
        message: "quantity is required"
      });
    }

    const qty = Number(quantity);

    if (qty <= 0) {
      return res.status(400).json({
        message: "Quantity must be greater than 0"
      });
    }

    let product = null;
    let matchedSku = "";
    let matchedBy = "";

    if (product_id) {
      product = await Product.findById(product_id);
      matchedSku = product?.sku || "";
      matchedBy = "product_id";
    } else {
      const skuCandidates = [sku, seller_sku, store_sku]
        .map((item) => (item || "").toString().trim())
        .filter(Boolean);

      for (const candidate of skuCandidates) {
        const result = await findProductBySkuAlias(candidate);
        if (result?.product) {
          product = result.product;
          matchedSku = result.matched_sku;
          matchedBy = result.matched_by;
          break;
        }
      }
    }

    if (!product) {
      return res.status(404).json({
        message: "Product not found by product_id or SKU alias"
      });
    }

    if ((product.stock || 0) < qty) {
      return res.status(400).json({
        message: "Not enough stock"
      });
    }

    const order = await Order.create({
      product_id: product._id,
      matched_sku: matchedSku,
      quantity: qty,
      sale_price: Number(sale_price) || product.selling_price || 0,
      source: "manual",
      status: "Delivered"
    });

    product.stock -= qty;
    await product.save();

    res.json({
      message: "Order added successfully",
      matched_by: matchedBy,
      matched_product: {
        _id: product._id,
        name: product.name,
        sku: product.sku,
        matched_sku: matchedSku
      },
      order
    });
  } catch (error) {
    res.status(500).json({
      message: "Error adding order",
      error: error.message
    });
  }
});

// Get all orders with product details
router.get("/", async (req, res) => {
  try {
    const orders = await Order.find()
      .populate("product_id", "name sku selling_price")
      .sort({ date: -1 });

    res.json(orders);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching orders",
      error: error.message
    });
  }
});

module.exports = router;