const mongoose = require("mongoose");

const syncIssueSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true,
      index: true
    },
    order_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "CentralOrder",
      default: null
    },
    order_item_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "CentralOrderItem",
      default: null
    },
    product_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Product",
      default: null,
      index: true
    },
    issue_type: {
      type: String,
      enum: ["unmapped_sku", "insufficient_stock", "sync_error"],
      required: true,
      index: true
    },
    status: {
      type: String,
      enum: ["open", "resolved", "ignored"],
      default: "open",
      index: true
    },
    seller_sku: {
      type: String,
      required: true,
      trim: true,
      index: true
    },
    product_name: {
      type: String,
      default: "",
      trim: true
    },
    master_sku: {
      type: String,
      default: "",
      trim: true
    },
    external_order_id: {
      type: String,
      default: "",
      trim: true
    },
    external_order_item_id: {
      type: String,
      default: "",
      trim: true
    },
    quantity_needed: {
      type: Number,
      default: 0,
      min: 0
    },
    available_stock: {
      type: Number,
      default: 0,
      min: 0
    },
    shortage_qty: {
      type: Number,
      default: 0,
      min: 0
    },
    occurrences: {
      type: Number,
      default: 1,
      min: 1
    },
    last_message: {
      type: String,
      default: "",
      trim: true
    },
    first_seen_at: {
      type: Date,
      default: Date.now
    },
    last_seen_at: {
      type: Date,
      default: Date.now
    },
    resolved_at: {
      type: Date,
      default: null
    },
    resolved_note: {
      type: String,
      default: "",
      trim: true
    }
  },
  { timestamps: true }
);

syncIssueSchema.index({ status: 1, issue_type: 1, createdAt: -1 });
syncIssueSchema.index({ store_id: 1, seller_sku: 1, issue_type: 1, status: 1 });

module.exports = mongoose.model("SyncIssue", syncIssueSchema);
