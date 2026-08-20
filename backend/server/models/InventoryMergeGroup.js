const mongoose = require('mongoose');

const inventoryMergeGroupSchema = new mongoose.Schema(
  {
    title: {
      type: String,
      required: true,
      trim: true
    },
    image_url: {
      type: String,
      default: '',
      trim: true
    },
    master_sku: {
      type: String,
      default: '',
      trim: true,
      index: true
    },
    stock: {
      type: Number,
      required: true,
      default: 0
    },
    reserved_stock: {
      type: Number,
      default: 0
    },
    low_stock_limit: {
      type: Number,
      default: 5
    },
    inventory_ids: [
      {
        type: mongoose.Schema.Types.ObjectId,
        ref: 'CentralInventory'
      }
    ],
    created_by: {
      type: String,
      default: 'admin',
      trim: true
    }
  },
  { timestamps: true }
);

inventoryMergeGroupSchema.index({ inventory_ids: 1 });

module.exports = mongoose.model('InventoryMergeGroup', inventoryMergeGroupSchema);
