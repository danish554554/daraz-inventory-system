
const mongoose = require("mongoose");

const storeSyncLogSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true,
      index: true
    },
    trigger_source: {
      type: String,
      enum: ["scheduler", "manual", "initial", "scheduled"],
      default: "manual",
      index: true
    },
    sync_started_at: {
      type: Date,
      default: Date.now,
      index: true
    },
    sync_finished_at: {
      type: Date,
      default: null
    },
    duration_ms: {
      type: Number,
      default: 0
    },
    success: {
      type: Boolean,
      default: false,
      index: true
    },
    summary_message: {
      type: String,
      default: "",
      trim: true
    },
    token_ready: {
      type: Boolean,
      default: false
    },
    token_refreshed: {
      type: Boolean,
      default: false
    },
    orders_seen: {
      type: Number,
      default: 0
    },
    orders_upserted: {
      type: Number,
      default: 0
    },
    items_seen: {
      type: Number,
      default: 0
    },
    items_upserted: {
      type: Number,
      default: 0
    },
    deducted: {
      type: Number,
      default: 0
    },
    restored: {
      type: Number,
      default: 0
    },
    skipped: {
      type: Number,
      default: 0
    },
    failed: {
      type: Number,
      default: 0
    },
    warnings: {
      type: [String],
      default: []
    },
    errors: {
      type: [String],
      default: []
    }
  },
  { timestamps: true, suppressReservedKeysWarning: true }
);

storeSyncLogSchema.index({ store_id: 1, sync_started_at: -1 });

module.exports = mongoose.model("StoreSyncLog", storeSyncLogSchema);
