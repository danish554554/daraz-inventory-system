const express = require("express");
const router = express.Router();

const Product = require("../models/Product");
const Purchase = require("../models/Purchase");

// Add purchase and increase stock
router.post("/", async (req, res) => {
  try {
    const {
      product_id,
      quantity,
      purchase_price,
      supplier = "",
      note = ""
    } = req.body;

    if (!product_id || !quantity || purchase_price === undefined) {
      return res.status(400).json({
        message: "product_id, quantity and purchase_price are required"
      });
    }

    const qty = Number(quantity);
    const price = Number(purchase_price);

    if (qty <= 0) {
      return res.status(400).json({
        message: "Quantity must be greater than 0"
      });
    }

    if (price < 0) {
      return res.status(400).json({
        message: "Purchase price cannot be negative"
      });
    }

    const product = await Product.findById(product_id);

    if (!product) {
      return res.status(404).json({
        message: "Product not found"
      });
    }

    const purchase = await Purchase.create({
      product_id,
      quantity: qty,
      purchase_price: price,
      supplier,
      note
    });

    product.stock = (product.stock || 0) + qty;

    if (!product.purchase_price || product.purchase_price === 0) {
      product.purchase_price = price;
    }

    await product.save();

    res.json({
      message: "Purchase added and stock updated successfully",
      purchase,
      updatedStock: product.stock
    });
  } catch (error) {
    res.status(500).json({
      message: "Error creating purchase",
      error: error.message
    });
  }
});

// Get purchase history
router.get("/", async (req, res) => {
  try {
    const purchases = await Purchase.find()
      .populate("product_id", "name sku stock")
      .sort({ date: -1 });

    res.json(purchases);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching purchases",
      error: error.message
    });
  }
});

module.exports = router;