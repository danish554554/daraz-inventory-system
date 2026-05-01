const mongoose = require("mongoose");

const centralOrderItemSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true
    },
    order_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "CentralOrder",
      required: true
    },
    product_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Product",
      default: null
    },
    external_order_item_id: {
      type: String,
      required: true,
      trim: true
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
    quantity: {
      type: Number,
      required: true,
      min: 1
    },
    unit_price: {
      type: Number,
      default: 0
    },
    status: {
      type: String,
      default: "pending",
      trim: true
    },
    return_reason: {
      type: String,
      default: "",
      trim: true
    },
    claim_date: {
      type: Date,
      default: null
    },
    logistic_facility_at: {
      type: Date,
      default: null
    },
    collection_status: {
      type: String,
      default: "pending",
      trim: true
    },
    mapping_status: {
      type: String,
      enum: ["mapped", "unmapped"],
      default: "unmapped"
    },
    stock_deducted: {
      type: Boolean,
      default: false
    },
    stock_restored: {
      type: Boolean,
      default: false
    },
    deduction_applied_at: {
      type: Date,
      default: null
    },
    restoration_applied_at: {
      type: Date,
      default: null
    },
    processing_status: {
      type: String,
      enum: ["pending", "deducted", "restored", "skipped", "failed", "error"],
      default: "pending"
    },
    error_message: {
      type: String,
      default: ""
    },
    raw_payload: {
      type: mongoose.Schema.Types.Mixed,
      default: null
    }
  },
  { timestamps: true }
);

centralOrderItemSchema.index(
  { store_id: 1, external_order_item_id: 1 },
  { unique: true }
);
centralOrderItemSchema.index({ seller_sku: 1 });
centralOrderItemSchema.index({ product_id: 1 });

module.exports = mongoose.model("CentralOrderItem", centralOrderItemSchema);
