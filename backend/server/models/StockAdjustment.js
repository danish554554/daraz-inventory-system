const mongoose = require("mongoose")

const adjustmentSchema = new mongoose.Schema({

  product_id:{
    type: mongoose.Schema.Types.ObjectId,
    ref: "Product",
    required:true
  },

  quantity:{
    type:Number,
    required:true
  },

  type:{
    type:String,
    enum:["increase","decrease"],
    required:true
  },

  reason:{
    type:String
  },

  date:{
    type:Date,
    default:Date.now
  }

})

module.exports = mongoose.model("StockAdjustment",adjustmentSchema)