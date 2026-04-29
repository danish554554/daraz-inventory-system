const mongoose = require("mongoose");

const purchaseSchema = new mongoose.Schema({
  product_id: {
    type: mongoose.Schema.Types.ObjectId,
    ref: "Product",
    required: true
  },
  quantity: {
    type: Number,
    required: true,
    min: 1
  },
  purchase_price: {
    type: Number,
    required: true,
    min: 0
  },
  supplier: {
    type: String,
    default: ""
  },
  note: {
    type: String,
    default: ""
  },
  date: {
    type: Date,
    default: Date.now
  }
});

module.exports = mongoose.model("Purchase", purchaseSchema);