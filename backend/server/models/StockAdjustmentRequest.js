const mongoose = require('mongoose');

const stockAdjustmentRequestSchema = new mongoose.Schema(
  {
    product_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Product',
      default: null,
      index: true
    },
    inventory_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'CentralInventory',
      default: null,
      index: true
    },
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Store',
      default: null,
      index: true
    },
    seller_sku: {
      type: String,
      default: '',
      trim: true,
      index: true
    },
    product_name: {
      type: String,
      default: '',
      trim: true
    },
    adjustment_type: {
      type: String,
      enum: ['increase', 'decrease'],
      required: true
    },
    quantity: {
      type: Number,
      required: true,
      min: 1
    },
    reason_code: {
      type: String,
      enum: [
        'purchase_correction',
        'damaged_stock',
        'missing_stock',
        'count_adjustment',
        'return_out',
        'other'
      ],
      default: 'other'
    },
    note: {
      type: String,
      default: '',
      trim: true
    },
    requested_by: {
      type: String,
      default: 'admin',
      trim: true
    },
    status: {
      type: String,
      enum: ['pending', 'approved', 'rejected'],
      default: 'pending',
      index: true
    },
    stock_before: {
      type: Number,
      default: 0
    },
    stock_after: {
      type: Number,
      default: null
    },
    decision_note: {
      type: String,
      default: '',
      trim: true
    },
    approved_by: {
      type: String,
      default: '',
      trim: true
    },
    approved_at: {
      type: Date,
      default: null
    }
  },
  { timestamps: true }
);

stockAdjustmentRequestSchema.index({ createdAt: -1 });
stockAdjustmentRequestSchema.index({ status: 1, createdAt: -1 });

module.exports = mongoose.model('StockAdjustmentRequest', stockAdjustmentRequestSchema);
