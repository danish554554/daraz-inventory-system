const express = require("express");
const router = express.Router();

const FinanceEntry = require("../models/FinanceEntry");
const CentralInventory = require("../models/CentralInventory");
const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");
const Store = require("../models/Store");

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

async function findCostDetails(group, storeId = null) {
  const first = group[0] || {};
  const sellerSku = (first["Seller SKU"] || "").trim();
  const lazadaSku = (first["Lazada SKU"] || "").trim();
  const productName = (first["Product Name"] || "").trim();

  const skuCandidates = extractSkuCandidates(sellerSku, lazadaSku);

  // 1. Check CentralInventory (Primary Source of Truth with Restock Costs)
  for (const candidate of skuCandidates) {
    const invQuery = {
      seller_sku: { $regex: new RegExp(`^${escapeRegex(candidate)}$`, "i") },
      is_archived: { $ne: true },
      is_deleted: { $ne: true }
    };
    if (storeId) invQuery.store_id = storeId;
    const invItem = await CentralInventory.findOne(invQuery).sort({ cost_price: -1, purchase_price: -1 });
    if (invItem && (invItem.cost_price > 0 || invItem.purchase_price > 0)) {
      const cost = invItem.cost_price > 0 ? invItem.cost_price : invItem.purchase_price;
      return {
        cost_price: Number(cost),
        matched_product_id: invItem._id,
        matched_product_name: invItem.product_name || invItem.display_title || productName,
        matched_by: `central_inventory:${candidate}`,
        profit_ready: true
      };
    }
  }

  // 2. Check Product table
  for (const candidate of skuCandidates) {
    let product = await Product.findOne({ sku: { $regex: new RegExp(`^${escapeRegex(candidate)}$`, "i") } });
    if (product && product.purchase_price > 0) {
      return {
        cost_price: Number(product.purchase_price),
        matched_product_id: product._id,
        matched_product_name: product.name,
        matched_by: `product_sku:${candidate}`,
        profit_ready: true
      };
    }

    const skuMap = await ProductSkuMap.findOne({ sku: { $regex: new RegExp(`^${escapeRegex(candidate)}$`, "i") } });
    if (skuMap) {
      product = await Product.findById(skuMap.product_id);
      if (product && product.purchase_price > 0) {
        return {
          cost_price: Number(product.purchase_price),
          matched_product_id: product._id,
          matched_product_name: product.name,
          matched_by: `product_sku_map:${candidate}`,
          profit_ready: true
        };
      }
    }
  }

  // 3. Match by name exact
  if (productName) {
    const product = await Product.findOne({
      name: { $regex: `^${escapeRegex(productName)}$`, $options: "i" }
    });
    if (product && product.purchase_price > 0) {
      return {
        cost_price: Number(product.purchase_price),
        matched_product_id: product._id,
        matched_product_name: product.name,
        matched_by: "name_exact",
        profit_ready: true
      };
    }
  }

  return {
    cost_price: 0,
    matched_product_id: null,
    matched_product_name: "",
    matched_by: "",
    profit_ready: false
  };
}

async function buildEntryFromGroup(group, defaultStore = null) {
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

  const grossAmount = productPrice + shippingPaidByBuyer + shippingFeeDiscount;
  const totalFees =
    commissionFee +
    paymentFee +
    shippingFee +
    handlingFee +
    freeShippingMaxFee +
    cofundedVoucherFee +
    coinsDiscountFee +
    penalties;
  const totalTaxes = incomeTaxWithholding + salesTaxWithholding + whtAmount;
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
    costDetails = await findCostDetails(group, defaultStore?._id || null);
  }

  const totalCost =
    adjustmentMeta.entryType === "order"
      ? (costDetails.cost_price || 0) * quantity
      : 0;

  const netProfit =
    adjustmentMeta.entryType === "order" && quantity > 0 && costDetails.profit_ready
      ? Number((netSettlement - totalCost).toFixed(2))
      : null;

  const shortCode = first["Short Code"] || first["Seller Short Code"] || "";

  return {
    store_id: defaultStore?._id || null,
    store_name: defaultStore?.name || "",
    store_code: defaultStore?.code || shortCode,

    statement_period: first["Statement Period"] || "",
    statement_number: first["Statement Number"] || "",
    short_code: shortCode,

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

    gross_amount: Number(grossAmount.toFixed(2)),
    total_fees: Number(totalFees.toFixed(2)),
    total_taxes: Number(totalTaxes.toFixed(2)),
    total_deductions: Number(totalDeductions.toFixed(2)),
    net_settlement: Number(netSettlement.toFixed(2)),

    cost_price: adjustmentMeta.entryType === "order" ? costDetails.cost_price : 0,
    quantity,
    total_cost: Number(totalCost.toFixed(2)),
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
  let totalCost = 0;
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
    totalCost += Number(item.total_cost) || 0;

    if (item.profit_ready && item.net_profit !== null && item.net_profit !== undefined) {
      netProfit += Number(item.net_profit) || 0;
      profitReadyOrders += 1;
    } else if ((Number(item.product_price) || 0) > 0) {
      pendingCostOrders += 1;
    }
  }

  const finalProfit = netProfit + adjustmentImpact;
  const marginPercent = grossAmount > 0 ? Number(((finalProfit / grossAmount) * 100).toFixed(2)) : 0;

  return {
    total_orders: totalOrders,
    total_adjustments: totalAdjustments,
    gross_amount: Number(grossAmount.toFixed(2)),
    total_fees: Number(totalFees.toFixed(2)),
    total_taxes: Number(totalTaxes.toFixed(2)),
    total_deductions: Number(totalDeductions.toFixed(2)),
    total_cost: Number(totalCost.toFixed(2)),
    net_settlement: Number(netSettlement.toFixed(2)),
    net_profit: Number(netProfit.toFixed(2)),
    adjustment_impact: Number(adjustmentImpact.toFixed(2)),
    final_profit_after_adjustments: Number(finalProfit.toFixed(2)),
    margin_percent: marginPercent,
    profit_ready_orders: profitReadyOrders,
    pending_cost_orders: pendingCostOrders
  };
}

// Generate weekly Monday-to-Sunday Daraz Statement Cycles
function generateDarazWeeklyCycles(count = 12) {
  const cycles = [];
  const now = new Date();
  const day = now.getDay(); // 0 is Sunday, 1 is Monday
  const diffToMonday = (day === 0 ? -6 : 1) - day;
  const currentMonday = new Date(now);
  currentMonday.setDate(now.getDate() + diffToMonday);
  currentMonday.setHours(0, 0, 0, 0);

  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  function formatDarazDate(d) {
    const dd = String(d.getDate()).padStart(2, "0");
    const mmm = months[d.getMonth()];
    const yyyy = d.getFullYear();
    return `${dd} ${mmm} ${yyyy}`;
  }

  for (let i = 0; i < count; i += 1) {
    const monday = new Date(currentMonday);
    monday.setDate(currentMonday.getDate() - (i * 7));

    const sunday = new Date(monday);
    sunday.setDate(monday.getDate() + 6);

    const periodString = `${formatDarazDate(monday)} - ${formatDarazDate(sunday)}`;
    cycles.push({
      statement_period: periodString,
      start_date: monday.toISOString(),
      end_date: sunday.toISOString(),
      is_current: i === 0
    });
  }

  return cycles;
}

// -----------------------------------------------------------------------------
// ROUTES
// -----------------------------------------------------------------------------

// 1. Get Weekly Statement Periods
router.get("/periods", async (req, res) => {
  try {
    const distinctPeriods = await FinanceEntry.distinct("statement_period", {
      statement_period: { $exists: true, $nin: ["", null] }
    });

    const generatedCycles = generateDarazWeeklyCycles(16);
    const existingSet = new Set(distinctPeriods.map(p => p.trim()));

    // Combine distinct periods from DB and official calendar cycles
    const periodList = [];
    for (const cycle of generatedCycles) {
      periodList.push({
        statement_period: cycle.statement_period,
        has_data: existingSet.has(cycle.statement_period),
        is_current: cycle.is_current
      });
      existingSet.delete(cycle.statement_period);
    }

    // Add any remaining custom periods from DB
    for (const p of existingSet) {
      if (p) {
        periodList.unshift({
          statement_period: p,
          has_data: true,
          is_current: false
        });
      }
    }

    res.json({
      success: true,
      periods: periodList
    });
  } catch (error) {
    res.status(500).json({ message: "Error fetching statement periods", error: error.message });
  }
});

// 2. Finance Summary
router.get("/summary", async (req, res) => {
  try {
    const { statement_period, store_id, search } = req.query;
    const query = {};

    if (statement_period && statement_period !== "all") {
      query.statement_period = { $regex: new RegExp(`^${escapeRegex(statement_period.trim())}$`, "i") };
    }
    if (store_id && store_id !== "all") {
      query.store_id = store_id;
    }
    if (search?.trim()) {
      const q = search.trim();
      query.$or = [
        { order_number: { $regex: q, $options: "i" } },
        { order_line_id: { $regex: q, $options: "i" } },
        { seller_sku: { $regex: q, $options: "i" } },
        { product_name: { $regex: q, $options: "i" } },
        { adjustment_reason: { $regex: q, $options: "i" } }
      ];
    }

    const entries = await FinanceEntry.find(query).lean();
    const summary = buildSummary(entries);
    res.json(summary);
  } catch (error) {
    res.status(500).json({ message: "Error fetching finance summary", error: error.message });
  }
});

// 3. Finance Entries List
router.get("/", async (req, res) => {
  try {
    const { statement_period, store_id, search, entry_type, profit_ready, limit = 500 } = req.query;
    const query = {};

    if (statement_period && statement_period !== "all") {
      query.statement_period = { $regex: new RegExp(`^${escapeRegex(statement_period.trim())}$`, "i") };
    }
    if (store_id && store_id !== "all") {
      query.store_id = store_id;
    }
    if (entry_type && entry_type !== "all") {
      query.entry_type = entry_type;
    }
    if (profit_ready === "false") {
      query.profit_ready = false;
      query.entry_type = "order";
      query.product_price = { $gt: 0 };
    } else if (profit_ready === "true") {
      query.profit_ready = true;
    }

    if (search?.trim()) {
      const q = search.trim();
      query.$or = [
        { order_number: { $regex: q, $options: "i" } },
        { order_line_id: { $regex: q, $options: "i" } },
        { seller_sku: { $regex: q, $options: "i" } },
        { product_name: { $regex: q, $options: "i" } },
        { adjustment_reason: { $regex: q, $options: "i" } }
      ];
    }

    const entries = await FinanceEntry.find(query)
      .populate("store_id", "name code")
      .sort({ createdAt: -1 })
      .limit(Number(limit) || 500)
      .lean();

    res.json(entries);
  } catch (error) {
    res.status(500).json({ message: "Error fetching finance entries", error: error.message });
  }
});

// 4. Import Statement CSV / Excel Rows
router.post("/import-csv", async (req, res) => {
  try {
    const { rows = [], store_id = "" } = req.body;

    if (!Array.isArray(rows) || rows.length === 0) {
      return res.status(400).json({ message: "CSV rows are required" });
    }

    let defaultStore = null;
    if (store_id) {
      defaultStore = await Store.findById(store_id);
    }

    const groupedRows = groupRowsByOrder(rows);
    const preparedEntries = [];

    for (const group of groupedRows) {
      const entry = await buildEntryFromGroup(group, defaultStore);
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
          returnDocument: 'after',
          setDefaultsOnInsert: true
        }
      );
    }

    const allEntries = await FinanceEntry.find().sort({ transaction_date: -1 }).lean();
    const totals = buildSummary(allEntries);

    res.json({
      success: true,
      message: "Finance statement imported successfully",
      imported_orders: preparedEntries.filter((item) => item.entry_type === "order").length,
      imported_adjustments: preparedEntries.filter((item) => item.entry_type === "adjustment").length,
      totals
    });
  } catch (error) {
    res.status(500).json({ message: "Error importing finance CSV", error: error.message });
  }
});

// 5. 1-Tap Set Cost & Recalculate Profits across all statements
router.post("/set-cost", async (req, res) => {
  try {
    const { seller_sku, cost_price } = req.body;
    const cost = Math.max(0, toNumber(cost_price, 0));
    const sku = String(seller_sku || "").trim();

    if (!sku || cost <= 0) {
      return res.status(400).json({ message: "A valid seller_sku and cost_price are required." });
    }

    // 1. Update Central Inventory
    await CentralInventory.updateMany(
      { seller_sku: { $regex: new RegExp(`^${escapeRegex(sku)}$`, "i") } },
      { $set: { cost_price: cost, purchase_price: cost } }
    );

    // 2. Update Product Catalog
    await Product.updateMany(
      { sku: { $regex: new RegExp(`^${escapeRegex(sku)}$`, "i") } },
      { $set: { purchase_price: cost } }
    );

    // 3. Batch Recalculate Finance Entries matching this SKU
    const matchingEntries = await FinanceEntry.find({
      seller_sku: { $regex: new RegExp(`^${escapeRegex(sku)}$`, "i") },
      entry_type: "order"
    });

    let recalculated = 0;
    for (const entry of matchingEntries) {
      const qty = entry.quantity > 0 ? entry.quantity : 1;
      const totalCost = Number((cost * qty).toFixed(2));
      const netProfit = Number((entry.net_settlement - totalCost).toFixed(2));

      entry.cost_price = cost;
      entry.total_cost = totalCost;
      entry.net_profit = netProfit;
      entry.profit_ready = true;
      entry.matched_by = `user_override:${sku}`;
      await entry.save();
      recalculated += 1;
    }

    res.json({
      success: true,
      message: `Cost price PKR ${cost} saved for SKU "${sku}". ${recalculated} finance order(s) recalculated.`,
      recalculated_count: recalculated
    });
  } catch (error) {
    res.status(500).json({ message: "Error updating cost price and recalculating", error: error.message });
  }
});

// 6. Clear Finance Data (by statement period or all)
router.delete("/clear", async (req, res) => {
  try {
    const { statement_period } = req.query;
    const query = {};
    if (statement_period && statement_period !== "all") {
      query.statement_period = { $regex: new RegExp(`^${escapeRegex(statement_period.trim())}$`, "i") };
    }

    const result = await FinanceEntry.deleteMany(query);
    res.json({
      success: true,
      message: statement_period && statement_period !== "all"
        ? `Finance data for period "${statement_period}" cleared successfully.`
        : "All finance data cleared successfully.",
      deleted_count: result.deletedCount || 0
    });
  } catch (error) {
    res.status(500).json({ message: "Error clearing finance data", error: error.message });
  }
});

module.exports = router;