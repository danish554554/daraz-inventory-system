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
      enum: ["pending", "processed", "restored", "skipped", "error"],
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

module.exports = mongoose.model("CentralOrder", centralOrderSchema);