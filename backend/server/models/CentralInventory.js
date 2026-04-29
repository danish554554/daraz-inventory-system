const mongoose = require("mongoose");

const centralInventorySchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true
    },
    seller_sku: {
      type: String,
      required: true,
      trim: true
    },
    product_name: {
      type: String,
      default: "",
      trim: true
    },
    stock: {
      type: Number,
      required: true,
      default: 0
    },
    reserved_stock: {
      type: Number,
      default: 0
    },
    low_stock_limit: {
      type: Number,
      default: 5
    }
  },
  { timestamps: true }
);

centralInventorySchema.index(
  { store_id: 1, seller_sku: 1 },
  { unique: true }
);

module.exports = mongoose.model("CentralInventory", centralInventorySchema);