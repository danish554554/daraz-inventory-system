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
