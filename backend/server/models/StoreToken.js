const mongoose = require("mongoose");

const storeTokenSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true,
      unique: true
    },
    access_token: {
      type: String,
      required: true,
      trim: true
    },
    refresh_token: {
      type: String,
      default: "",
      trim: true
    },
    seller_id: {
      type: String,
      default: "",
      trim: true
    },
    user_id: {
      type: String,
      default: "",
      trim: true
    },
    account: {
      type: String,
      default: "",
      trim: true
    },
    country_code: {
      type: String,
      default: "",
      trim: true
    },
    api_base_url: {
      type: String,
      default: "",
      trim: true
    },
    expires_at: {
      type: Date,
      default: null
    },
    refresh_expires_at: {
      type: Date,
      default: null
    },
    token_status: {
      type: String,
      enum: ["active", "expiring_soon", "invalid", "expired", "not_connected"],
      default: "active"
    },
    token_source: {
      type: String,
      enum: ["manual", "oauth", "refreshed"],
      default: "manual"
    },
    last_sync_at: {
      type: Date,
      default: null
    },
    last_validated_at: {
      type: Date,
      default: null
    },
    last_refreshed_at: {
      type: Date,
      default: null
    },
    last_error: {
      type: String,
      default: "",
      trim: true
    }
  },
  { timestamps: true }
);

module.exports = mongoose.model("StoreToken", storeTokenSchema);