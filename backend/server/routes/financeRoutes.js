const express = require("express");
const router = express.Router();

const FinanceEntry = require("../models/FinanceEntry");
const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");

function toNumber(value) {
  if (value === null || value === undefined || value === "") return 0;

  const cleaned = value
    .toString()
    .replace(/,/g, "")
    .replace(/\s+/g, "")
    .replace(/pkr/gi, "")
    .replace(/rs\.?/gi, "");

  const num = Number(cleaned);
  return Number.isNaN(num) ? 0 : num;
}

function absNumber(value) {
  return Math.abs(toNumber(value));
}

function normalizeFeeName(name = "") {
  return name.toString().trim().toLowerCase();
}

function escapeRegex(value = "") {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function extractSkuCandidates(sellerSku = "", lazadaSku = "") {
  const candidates = new Set();

  const add = (value) => {
    const cleaned = value?.toString().trim();
    if (cleaned) candidates.add(cleaned);
  };

  add(sellerSku);
  add(lazadaSku);

  if (sellerSku.includes("-")) {
    add(sellerSku.split("-")[0].trim());
  }

  if (lazadaSku.includes("_")) {
    add(lazadaSku.split("_")[0].trim());
  }

  if (lazadaSku.includes("-")) {
    add(lazadaSku.split("-")[0].trim());
  }

  return Array.from(candidates);
}

function extractQuantity(first = {}) {
  const possibleQty =
    first["Quantity"] ??
    first["Qty"] ??
    first["Item Quantity"] ??
    first["Quantity Ordered"];

  if (possibleQty !== null && possibleQty !== undefined && possibleQty !== "") {
    const parsedQty = Number(possibleQty);
    if (!Number.isNaN(parsedQty) && parsedQty > 0) {
      return parsedQty;
    }
  }

  return 1;
}

function groupRowsByOrder(rows) {
  const grouped = {};

  for (const row of rows) {
    const orderNumber = (row["Order Number"] || "").toString().trim();
    const orderLineId = (row["Order Line ID"] || "").toString().trim();

    if (!orderNumber || !orderLineId) continue;

    const key = `${orderNumber}__${orderLineId}`;

    if (!grouped[key]) {
      grouped[key] = [];
    }

    grouped[key].push(row);
  }

  return Object.values(grouped);
}

function detectAdjustmentType(group) {
  const feeNames = group.map((row) =>
    normalizeFeeName((row["Fee Name"] || "").toString())
  );

  const comments = group
    .map((row) => (row["Comment"] || "").toString().trim().toLowerCase())
    .filter(Boolean);

  const hasSalesComponent = feeNames.some((fee) =>
    [
      "product price paid by buyer",
      "shipping fee paid by buyer",
      "shipping fee discount"
    ].includes(fee)
  );

  const hasOtherCreditOrDebit = feeNames.some(
    (fee) =>
      fee.includes("other credit") ||
      fee.includes("other debit") ||
      fee.includes("credit") ||
      fee.includes("debit")
  );

  const commentText = comments.join(" | ");

  const reversalKeywords = [
    "refund",
    "reversal",
    "reverse",
    "correction",
    "corrected",
    "system error",
    "charged twice",
    "overcharged",
    "refund for",
    "adjustment",
    "compensation"
  ];

  const hasReversalComment = reversalKeywords.some((keyword) =>
    commentText.includes(keyword)
  );

  const standalonePenalty =
    feeNames.length > 0 &&
    feeNames.every((fee) => fee === "penalties for fulfillment") &&
    !hasSalesComponent;

  if (hasOtherCreditOrDebit || hasReversalComment) {
    return {
      entryType: "adjustment",
      reason: commentText || "Financial adjustment / reversal"
    };
  }

  if (standalonePenalty) {
    return {
      entryType: "adjustment",
      reason: "Standalone fulfillment penalty"
    };
  }

  if (!hasSalesComponent) {
    return {
      entryType: "adjustment",
      reason: "Financial-only entry without buyer sale component"
    };
  }

  return {
    entryType: "order",
    reason: ""
  };
}

async function findProductByCandidateSku(candidate) {
  if (!candidate) return null;

  let product = await Product.findOne({ sku: candidate });
  if (product) {
    return {
      product,
      matchedBy: `primary_sku:${candidate}`
    };
  }

  const skuMap = await ProductSkuMap.findOne({ sku: candidate });
  if (skuMap) {
    product = await Product.findById(skuMap.product_id);
    if (product) {
      return {
        product,
        matchedBy: `mapped_sku:${candidate}`
      };
    }
  }

  return null;
}

async function findCostDetails(group) {
  const first = group[0] || {};

  const sellerSku = (first["Seller SKU"] || "").trim();
  const lazadaSku = (first["Lazada SKU"] || "").trim();
  const productName = (first["Product Name"] || "").trim();

  const skuCandidates = extractSkuCandidates(sellerSku, lazadaSku);

  let product = null;
  let matchedBy = "";

  for (const candidate of skuCandidates) {
    const result = await findProductByCandidateSku(candidate);
    if (result?.product) {
      product = result.product;
      matchedBy = result.matchedBy;
      break;
    }
  }

  if (!product && productName) {
    product = await Product.findOne({
      name: {
        $regex: `^${escapeRegex(productName)}$`,
        $options: "i"
      }
    });

    if (product) matchedBy = "name_exact";
  }

  if (!product && productName) {
    product = await Product.findOne({
      name: {
        $regex: escapeRegex(productName),
        $options: "i"
      }
    });

    if (product) matchedBy = "name_partial";
  }

  return {
    cost_price: product ? Number(product.purchase_price) || 0 : 0,
    matched_product_id: product ? product._id : null,
    matched_product_name: product ? product.name : "",
    matched_by: matchedBy,
    profit_ready: !!product
  };
}

async function buildEntryFromGroup(group) {
  const first = group[0] || {};
  const adjustmentMeta = detectAdjustmentType(group);

  let productPrice = 0;
  let shippingPaidByBuyer = 0;
  let shippingFeeDiscount = 0;

  let commissionFee = 0;
  let paymentFee = 0;
  let shippingFee = 0;
  let handlingFee = 0;
  let freeShippingMaxFee = 0;
  let cofundedVoucherFee = 0;
  let coinsDiscountFee = 0;
  let penalties = 0;

  let incomeTaxWithholding = 0;
  let salesTaxWithholding = 0;
  let whtAmount = 0;
  let vatTotal = 0;

  let netSettlement = 0;
  const feeBreakdown = {};

  for (const row of group) {
    const feeName = (row["Fee Name"] || "").trim();
    const feeNameKey = normalizeFeeName(feeName);

    const amount = toNumber(row["Amount(Include Tax)"]);
    const vat = absNumber(row["VAT Amount"]);
    const wht = absNumber(row["WHT Amount"]);

    netSettlement += amount;
    vatTotal += vat;
    whtAmount += wht;

    feeBreakdown[feeName] = (feeBreakdown[feeName] || 0) + amount;

    switch (feeNameKey) {
      case "product price paid by buyer":
        productPrice += amount;
        break;

      case "shipping fee paid by buyer":
        shippingPaidByBuyer += amount;
        break;

      case "shipping fee discount":
        shippingFeeDiscount += amount;
        break;

      case "commission fee":
        commissionFee += absNumber(amount);
        break;

      case "payment fee":
        paymentFee += absNumber(amount);
        break;

      case "shipping fee":
        shippingFee += absNumber(amount);
        break;

      case "handling fee":
        handlingFee += absNumber(amount);
        break;

      case "free shipping max fee":
        freeShippingMaxFee += absNumber(amount);
        break;

      case "co-funded voucher max":
        cofundedVoucherFee += absNumber(amount);
        break;

      case "daraz coins discount participation fee":
        coinsDiscountFee += absNumber(amount);
        break;

      case "penalties for fulfillment":
        penalties += absNumber(amount);
        break;

      case "income tax withholding":
        incomeTaxWithholding += absNumber(amount);
        break;

      case "sales tax withholding":
        salesTaxWithholding += absNumber(amount);
        break;

      default:
        break;
    }
  }

  const grossAmount =
    productPrice + shippingPaidByBuyer + shippingFeeDiscount;

  const totalFees =
    commissionFee +
    paymentFee +
    shippingFee +
    handlingFee +
    freeShippingMaxFee +
    cofundedVoucherFee +
    coinsDiscountFee +
    penalties;

  const totalTaxes =
    incomeTaxWithholding +
    salesTaxWithholding +
    whtAmount;

  const totalDeductions = totalFees + totalTaxes;

  const quantity = adjustmentMeta.entryType === "adjustment" ? 0 : extractQuantity(first);

  let costDetails = {
    cost_price: 0,
    matched_product_id: null,
    matched_product_name: "",
    matched_by: "",
    profit_ready: false
  };

  if (adjustmentMeta.entryType === "order") {
    costDetails = await findCostDetails(group);
  }

  const totalCost =
    adjustmentMeta.entryType === "order"
      ? (costDetails.cost_price || 0) * quantity
      : 0;

  const netProfit =
    adjustmentMeta.entryType === "order" &&
    quantity > 0 &&
    costDetails.profit_ready
      ? netSettlement - totalCost
      : null;

  return {
    statement_period: first["Statement Period"] || "",
    statement_number: first["Statement Number"] || "",
    short_code: first["Short Code"] || "",

    transaction_date: first["Transaction Date"] || "",
    order_creation_date: first["Order Creation Date"] || "",
    release_status: first["Release Status"] || "",
    release_date: first["Release Date"] || "",

    order_number: first["Order Number"] || "",
    order_line_id: first["Order Line ID"] || "",

    seller_sku: first["Seller SKU"] || "",
    lazada_sku: first["Lazada SKU"] || "",
    product_name: first["Product Name"] || "",
    order_status: first["Order Status"] || "",

    entry_type: adjustmentMeta.entryType,
    adjustment_reason: adjustmentMeta.reason,

    product_price: productPrice,
    shipping_paid_by_buyer: shippingPaidByBuyer,
    shipping_fee_discount: shippingFeeDiscount,

    commission_fee: commissionFee,
    payment_fee: paymentFee,
    shipping_fee: shippingFee,
    handling_fee: handlingFee,
    free_shipping_max_fee: freeShippingMaxFee,
    cofunded_voucher_fee: cofundedVoucherFee,
    coins_discount_fee: coinsDiscountFee,
    penalties,

    income_tax_withholding: incomeTaxWithholding,
    sales_tax_withholding: salesTaxWithholding,
    wht_amount: whtAmount,
    vat_total: vatTotal,

    gross_amount: grossAmount,
    total_fees: totalFees,
    total_taxes: totalTaxes,
    total_deductions: totalDeductions,
    net_settlement: netSettlement,

    cost_price: adjustmentMeta.entryType === "order" ? costDetails.cost_price : 0,
    quantity,
    total_cost: totalCost,
    net_profit: netProfit,

    matched_product_id:
      adjustmentMeta.entryType === "order" ? costDetails.matched_product_id : null,
    matched_product_name:
      adjustmentMeta.entryType === "order" ? costDetails.matched_product_name : "",
    matched_by: adjustmentMeta.entryType === "order" ? costDetails.matched_by : "",
    profit_ready:
      adjustmentMeta.entryType === "order" ? costDetails.profit_ready : false,

    fee_breakdown: feeBreakdown,
    imported_at: new Date()
  };
}

function buildSummary(entries = []) {
  let grossAmount = 0;
  let totalFees = 0;
  let totalTaxes = 0;
  let totalDeductions = 0;
  let netSettlement = 0;
  let netProfit = 0;
  let profitReadyOrders = 0;
  let pendingCostOrders = 0;
  let totalOrders = 0;
  let totalAdjustments = 0;
  let adjustmentImpact = 0;

  for (const item of entries) {
    grossAmount += Number(item.gross_amount) || 0;
    totalFees += Number(item.total_fees) || 0;
    totalTaxes += Number(item.total_taxes) || 0;
    totalDeductions += Number(item.total_deductions) || 0;
    netSettlement += Number(item.net_settlement) || 0;

    if (item.entry_type === "adjustment") {
      totalAdjustments += 1;
      adjustmentImpact += Number(item.net_settlement) || 0;
      continue;
    }

    totalOrders += 1;

    if (item.net_profit !== null && item.net_profit !== undefined) {
      netProfit += Number(item.net_profit) || 0;
      profitReadyOrders += 1;
    } else if ((Number(item.product_price) || 0) > 0) {
      pendingCostOrders += 1;
    }
  }

  return {
    total_orders: totalOrders,
    total_adjustments: totalAdjustments,
    gross_amount: grossAmount,
    total_fees: totalFees,
    total_taxes: totalTaxes,
    total_deductions: totalDeductions,
    net_settlement: netSettlement,
    net_profit: netProfit,
    adjustment_impact: adjustmentImpact,
    final_profit_after_adjustments: netProfit + adjustmentImpact,
    profit_ready_orders: profitReadyOrders,
    pending_cost_orders: pendingCostOrders
  };
}

router.post("/import-csv", async (req, res) => {
  try {
    const { rows = [] } = req.body;

    if (!Array.isArray(rows) || rows.length === 0) {
      return res.status(400).json({
        message: "CSV rows are required"
      });
    }

    const groupedRows = groupRowsByOrder(rows);
    const preparedEntries = [];

    for (const group of groupedRows) {
      const entry = await buildEntryFromGroup(group);
      preparedEntries.push(entry);
    }

    for (const entry of preparedEntries) {
      await FinanceEntry.findOneAndUpdate(
        {
          statement_number: entry.statement_number,
          order_line_id: entry.order_line_id
        },
        entry,
        {
          upsert: true,
          new: true,
          setDefaultsOnInsert: true
        }
      );
    }

    const allEntries = await FinanceEntry.find().sort({ transaction_date: -1 });
    const totals = buildSummary(allEntries);

    res.json({
      message: "Finance statement imported successfully",
      imported_orders: preparedEntries.filter((item) => item.entry_type === "order").length,
      imported_adjustments: preparedEntries.filter((item) => item.entry_type === "adjustment").length,
      totals
    });
  } catch (error) {
    res.status(500).json({
      message: "Error importing finance CSV",
      error: error.message
    });
  }
});

router.get("/", async (req, res) => {
  try {
    const entries = await FinanceEntry.find().sort({ createdAt: -1 });
    res.json(entries);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching finance entries",
      error: error.message
    });
  }
});
router.get("/summary", async (req, res) => {
  try {
    const entries = await FinanceEntry.find();
    const summary = buildSummary(entries);
    res.json(summary);
  } catch (error) {
    res.status(500).json({
      message: "Error fetching finance summary",
      error: error.message
    });
  }
});

router.delete("/clear", async (req, res) => {
  try {
    const result = await FinanceEntry.deleteMany({});

    res.json({
      message: "All finance data cleared successfully",
      deleted_count: result.deletedCount || 0
    });
  } catch (error) {
    res.status(500).json({
      message: "Error clearing finance data",
      error: error.message
    });
  }
});


module.exports = router;