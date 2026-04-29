const mongoose = require("mongoose");

const storeSchema = new mongoose.Schema(
  {
    name: {
      type: String,
      required: true,
      trim: true
    },
    code: {
      type: String,
      required: true,
      trim: true,
      unique: true
    },
    platform: {
      type: String,
      default: "daraz",
      trim: true
    },
    country: {
      type: String,
      default: "PK",
      trim: true
    },
    status: {
      type: String,
      enum: ["active", "inactive"],
      default: "active"
    },
    deduct_stage: {
      type: String,
      enum: ["created", "pending", "unpaid", "packed", "ready_to_ship", "shipped", "delivered"],
      default: "ready_to_ship"
    },
    restore_on_cancel: {
      type: Boolean,
      default: true
    },
    sync_interval_minutes: {
      type: Number,
      default: 5,
      min: 1
    },
    notes: {
      type: String,
      default: "",
      trim: true
    },
    last_sync_at: {
      type: Date,
      default: null
    },
    last_sync_status: {
      type: String,
      default: ''
    },
    last_sync_message: {
      type: String,
      default: ''
    }
  },
  { timestamps: true }
);

module.exports = mongoose.model("Store", storeSchema);