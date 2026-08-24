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
    original_product_name: {
      type: String,
      default: "",
      trim: true
    },
    display_title: {
      type: String,
      default: "",
      trim: true
    },
    image_url: {
      type: String,
      default: "",
      trim: true
    },
    daraz_product_id: {
      type: String,
      default: "",
      trim: true
    },
    daraz_item_id: {
      type: String,
      default: "",
      trim: true
    },
    daraz_sku_id: {
      type: String,
      default: "",
      trim: true
    },
    variation_name: {
      type: String,
      default: "",
      trim: true
    },
    last_product_import_at: {
      type: Date,
      default: null
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
    },
    purchase_price: {
      type: Number,
      default: 0,
      min: 0
    },
    cost_price: {
      type: Number,
      default: 0,
      min: 0
    },
    selling_price: {
      type: Number,
      default: 0,
      min: 0
    },
    profit_margin: {
      type: Number,
      default: 0
    },
    is_archived: {
      type: Boolean,
      default: false,
      index: true
    },
    is_deleted: {
      type: Boolean,
      default: false,
      index: true
    },
    status: {
      type: String,
      default: "active",
      index: true
    }
  },
  { timestamps: true }
);

centralInventorySchema.index(
  { store_id: 1, seller_sku: 1 },
  { unique: true }
);

module.exports = mongoose.model("CentralInventory", centralInventorySchema);