const mongoose = require('mongoose');

const stockReceiptSchema = new mongoose.Schema(
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
    receipt_type: {
      type: String,
      enum: ['purchase', 'manual_add', 'opening_balance', 'return_in'],
      default: 'purchase'
    },
    quantity: {
      type: Number,
      required: true,
      min: 1
    },
    unit_cost: {
      type: Number,
      default: 0,
      min: 0
    },
    supplier_name: {
      type: String,
      default: '',
      trim: true,
      index: true
    },
    invoice_number: {
      type: String,
      default: '',
      trim: true
    },
    warehouse_note: {
      type: String,
      default: '',
      trim: true
    },
    note: {
      type: String,
      default: '',
      trim: true
    },
    created_by: {
      type: String,
      default: 'admin',
      trim: true
    }
  },
  { timestamps: true }
);

stockReceiptSchema.index({ createdAt: -1 });
stockReceiptSchema.index({ supplier_name: 1, createdAt: -1 });
stockReceiptSchema.index({ receipt_type: 1, createdAt: -1 });

module.exports = mongoose.model('StockReceipt', stockReceiptSchema);
