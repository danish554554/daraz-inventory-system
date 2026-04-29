const mongoose = require("mongoose");

const inventoryAlertLogSchema = new mongoose.Schema(
  {
    alert_date: {
      type: String,
      required: true,
      trim: true,
      unique: true
    },
    total_low_stock_products: {
      type: Number,
      default: 0
    },
    total_zero_stock_products: {
      type: Number,
      default: 0
    },
    triggered_by: {
      type: String,
      enum: ["scheduler", "manual"],
      default: "scheduler"
    },
    products: [
      {
        product_id: {
          type: mongoose.Schema.Types.ObjectId,
          ref: "Product",
          default: null
        },
        name: {
          type: String,
          default: "",
          trim: true
        },
        sku: {
          type: String,
          default: "",
          trim: true
        },
        stock: {
          type: Number,
          default: 0
        },
        reserved_stock: {
          type: Number,
          default: 0
        },
        low_stock_limit: {
          type: Number,
          default: 0
        },
        mapped_store_count: {
          type: Number,
          default: 0
        },
        mapped_skus: {
          type: [String],
          default: []
        }
      }
    ],
    notes: {
      type: String,
      default: "",
      trim: true
    },
    created_at: {
      type: Date,
      default: Date.now
    }
  },
  { timestamps: true }
);

module.exports = mongoose.model("InventoryAlertLog", inventoryAlertLogSchema);
