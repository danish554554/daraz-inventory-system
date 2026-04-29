const mongoose = require("mongoose");

const productSkuMapSchema = new mongoose.Schema(
  {
    product_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Product",
      required: true
    },
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      default: null
    },
    sku: {
      type: String,
      required: true,
      trim: true
    },
    store_name: {
      type: String,
      default: "",
      trim: true
    },
    is_primary: {
      type: Boolean,
      default: false
    }
  },
  { timestamps: true }
);

productSkuMapSchema.index({ sku: 1 }, { unique: true });
productSkuMapSchema.index({ product_id: 1, store_id: 1 });

module.exports = mongoose.model("ProductSkuMap", productSkuMapSchema);
