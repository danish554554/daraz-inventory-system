const mongoose = require("mongoose");

const financeEntrySchema = new mongoose.Schema(
  {
    statement_period: { type: String, default: "" },
    statement_number: { type: String, default: "" },
    short_code: { type: String, default: "" },

    transaction_date: { type: String, default: "" },
    order_creation_date: { type: String, default: "" },
    release_status: { type: String, default: "" },
    release_date: { type: String, default: "" },

    order_number: { type: String, required: true },
    order_line_id: { type: String, required: true },

    seller_sku: { type: String, default: "" },
    lazada_sku: { type: String, default: "" },
    product_name: { type: String, default: "" },
    order_status: { type: String, default: "" },

    entry_type: {
      type: String,
      enum: ["order", "adjustment"],
      default: "order"
    },
    adjustment_reason: { type: String, default: "" },

    product_price: { type: Number, default: 0 },
    shipping_paid_by_buyer: { type: Number, default: 0 },
    shipping_fee_discount: { type: Number, default: 0 },

    commission_fee: { type: Number, default: 0 },
    payment_fee: { type: Number, default: 0 },
    shipping_fee: { type: Number, default: 0 },
    handling_fee: { type: Number, default: 0 },
    free_shipping_max_fee: { type: Number, default: 0 },
    cofunded_voucher_fee: { type: Number, default: 0 },
    coins_discount_fee: { type: Number, default: 0 },
    penalties: { type: Number, default: 0 },

    income_tax_withholding: { type: Number, default: 0 },
    sales_tax_withholding: { type: Number, default: 0 },
    wht_amount: { type: Number, default: 0 },
    vat_total: { type: Number, default: 0 },

    gross_amount: { type: Number, default: 0 },
    total_fees: { type: Number, default: 0 },
    total_taxes: { type: Number, default: 0 },
    total_deductions: { type: Number, default: 0 },
    net_settlement: { type: Number, default: 0 },

    cost_price: { type: Number, default: 0 },
    quantity: { type: Number, default: 0 },
    total_cost: { type: Number, default: 0 },
    net_profit: { type: Number, default: null },

    matched_product_id: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Product",
      default: null
    },
    matched_product_name: { type: String, default: "" },
    matched_by: { type: String, default: "" },
    profit_ready: { type: Boolean, default: false },

    fee_breakdown: {
      type: Object,
      default: {}
    },

    imported_at: {
      type: Date,
      default: Date.now
    }
  },
  { timestamps: true }
);

financeEntrySchema.index(
  { statement_number: 1, order_line_id: 1 },
  { unique: true }
);

module.exports = mongoose.model("FinanceEntry", financeEntrySchema);