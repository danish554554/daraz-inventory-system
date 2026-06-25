const mongoose = require("mongoose");

const storeConnectionConfigSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Store",
      required: true,
      unique: true,
      index: true
    },

    platform: {
      type: String,
      default: "daraz",
      enum: ["daraz"],
      index: true
    },

    connection_mode: {
      type: String,
      default: "seller_managed_app",
      enum: ["seller_managed_app", "owner_managed_app"]
    },

    app_key: {
      type: String,
      trim: true,
      default: ""
    },

    app_secret: {
      type: String,
      trim: true,
      default: ""
    },

    redirect_uri: {
      type: String,
      trim: true,
      default: ""
    },

    api_region: {
      type: String,
      trim: true,
      default: "pk",
      enum: ["pk", "bd", "lk", "np", "mm"]
    },

    seller_email: {
      type: String,
      trim: true,
      default: ""
    },

    seller_account_name: {
      type: String,
      trim: true,
      default: ""
    },

    auth_state: {
      type: String,
      trim: true,
      default: ""
    },

    auth_status: {
      type: String,
      trim: true,
      default: "not_connected",
      enum: [
        "not_connected",
        "config_saved",
        "auth_url_generated",
        "authorized",
        "token_active",
        "token_expired",
        "token_invalid",
        "disconnected"
      ],
      index: true
    },

    auth_url_last_generated_at: {
      type: Date,
      default: null
    },

    last_connected_at: {
      type: Date,
      default: null
    },

    last_validated_at: {
      type: Date,
      default: null
    },

    last_error_message: {
      type: String,
      trim: true,
      default: ""
    },

    notes: {
      type: String,
      trim: true,
      default: ""
    }
  },
  {
    timestamps: true
  }
);

storeConnectionConfigSchema.index({
  store_id: 1,
  platform: 1
});

module.exports = mongoose.model(
  "StoreConnectionConfig",
  storeConnectionConfigSchema
);