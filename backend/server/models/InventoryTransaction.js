const mongoose = require('mongoose');

const inventoryTransactionSchema = new mongoose.Schema(
  {
    store_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Store',
      default: null
    },
    product_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Product',
      default: null,
      index: true
    },
    inventory_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'CentralInventory',
      default: null
    },
    seller_sku: {
      type: String,
      default: '',
      trim: true,
      index: true
    },
    master_sku: {
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
    order_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'CentralOrder',
      default: null
    },
    order_item_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'CentralOrderItem',
      default: null
    },
    external_order_id: {
      type: String,
      default: '',
      trim: true
    },
    external_order_item_id: {
      type: String,
      default: '',
      trim: true
    },
    adjustment_request_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'StockAdjustmentRequest',
      default: null
    },
    transaction_type: {
      type: String,
      enum: [
        'opening',
        'manual_add',
        'manual_deduct',
        'order_deduct',
        'cancel_restore',
        'adjustment_approved'
      ],
      required: true,
      index: true
    },
    quantity: {
      type: Number,
      required: true,
      min: 0
    },
    stock_before: {
      type: Number,
      required: true
    },
    stock_after: {
      type: Number,
      required: true
    },
    note: {
      type: String,
      default: '',
      trim: true
    }
  },
  { timestamps: true }
);

inventoryTransactionSchema.index({ createdAt: -1 });

module.exports = mongoose.model('InventoryTransaction', inventoryTransactionSchema);
