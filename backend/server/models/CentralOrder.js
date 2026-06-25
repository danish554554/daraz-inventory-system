const mongoose = require("mongoose");

const centralOrderSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true
    },
    external_order_id: {
      type: String,
      required: true,
      trim: true
    },
    order_number: {
      type: String,
      default: "",
      trim: true
    },
    status: {
      type: String,
      default: "pending",
      trim: true
    },
    status_category: {
      type: String,
      enum: ["pending", "active_sale", "cancelled", "return", "failed_delivery", "collected", "scrapped"],
      default: "pending",
      index: true
    },
    revenue_countable: {
      type: Boolean,
      default: false,
      index: true
    },
    order_created_at: {
      type: Date,
      default: null
    },
    order_updated_at: {
      type: Date,
      default: null
    },
    synced_at: {
      type: Date,
      default: null
    },
    processing_status: {
      type: String,
      enum: ["pending", "processed", "deducted", "restored", "skipped", "failed", "error"],
      default: "pending"
    },
    inventory_processed_at: {
      type: Date,
      default: null
    },
    inventory_restored_at: {
      type: Date,
      default: null
    },
    raw_payload: {
      type: mongoose.Schema.Types.Mixed,
      default: null
    }
  },
  { timestamps: true }
);

centralOrderSchema.index(
  { store_id: 1, external_order_id: 1 },
  { unique: true }
);
centralOrderSchema.index({ status_category: 1, order_created_at: -1 });

module.exports = mongoose.model("CentralOrder", centralOrderSchema);