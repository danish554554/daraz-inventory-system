const Product = require("../models/Product");
const StockAdjustment = require("../models/StockAdjustment");

exports.adjustStock = async (req, res) => {
  try {
    const { product_id, quantity, type, reason } = req.body;

    if (!product_id || !quantity || !type) {
      return res.status(400).json({
        message: "product_id, quantity and type are required"
      });
    }

    const qty = Number(quantity);

    if (qty <= 0) {
      return res.status(400).json({
        message: "Quantity must be greater than 0"
      });
    }

    if (!["increase", "decrease"].includes(type)) {
      return res.status(400).json({
        message: "Type must be increase or decrease"
      });
    }

    const product = await Product.findById(product_id);

    if (!product) {
      return res.status(404).json({
        message: "Product not found"
      });
    }

    if (type === "decrease" && (product.stock || 0) < qty) {
      return res.status(400).json({
        message: "Not enough stock to decrease"
      });
    }

    if (type === "increase") {
      product.stock = (product.stock || 0) + qty;
    } else {
      product.stock = (product.stock || 0) - qty;
    }

    await product.save();

    const adjustment = await StockAdjustment.create({
      product_id,
      quantity: qty,
      type,
      reason: reason || ""
    });

    res.json({
      message: "Stock adjusted successfully",
      adjustment,
      updatedStock: product.stock
    });
  } catch (error) {
    res.status(500).json({
      message: "Error adjusting stock",
      error: error.message
    });
  }
};

exports.getAdjustmentHistory = async (req, res) => {
  try {
    const adjustments = await StockAdjustment.find()
      .populate("product_id", "name sku stock")
      .sort({ date: -1 });

    res.json(adjustments);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching stock adjustment history",
      error: error.message
    });
  }
};