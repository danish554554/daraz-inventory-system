const mongoose = require("mongoose");

const productSchema = new mongoose.Schema(
  {
    name: { type: String, required: true, trim: true },
    sku: { type: String, required: true, trim: true, unique: true },
    low_stock_limit: { type: Number, default: 5, min: 0 },
    purchase_price: { type: Number, default: 0, min: 0 },
    selling_price: { type: Number, default: 0, min: 0 },
    stock: { type: Number, default: 0, min: 0 },
    reserved_stock: { type: Number, default: 0, min: 0 },
    image_url: { type: String, default: "", trim: true },
    source_title: { type: String, default: "", trim: true },
    created_at: { type: Date, default: Date.now }
  },
  { timestamps: true }
);

productSchema.index({ name: 1 });
productSchema.index({ sku: 1 });

module.exports = mongoose.model("Product", productSchema);
