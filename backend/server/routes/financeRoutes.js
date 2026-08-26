const express = require("express");
const router = express.Router();

const FinanceEntry = require("../models/FinanceEntry");
const CentralInventory = require("../models/CentralInventory");
const Product = require("../models/Product");
const ProductSkuMap = require("../models/ProductSkuMap");
const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const CentralOrder = require("../models/CentralOrder");
const CentralOrderItem = require("../models/CentralOrderItem");
const { getTransactionDetails } = require("../services/darazApiService");
const { ensureStoreTokenReadyForSync } = require("../services/darazService");

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
    if (cleaned) {
      candidates.add(cleaned);
      const collapsed = cleaned.replace(/\s+/g, " ");
      if (collapsed) candidates.add(collapsed);
      const noSpace = cleaned.replace(/\s+/g, "");
      if (noSpace) candidates.add(noSpace);
    }
  };

  add(sellerSku);
  add(lazadaSku);

  if (sellerSku.includes("-")) {
    add(sellerSku.split("-")[0].trim());
    add(sellerSku.split("-").slice(0, 2).join("-").trim());
  }
  if (sellerSku.includes("_")) {
    add(sellerSku.split("_")[0].trim());
  }
  if (sellerSku.includes(" ")) {
    add(sellerSku.split(" ")[0].trim());
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
    const orderNumber = (row["Order Number"] || row["Order No"] || row["Order ID"] || "").toString().trim();
    const orderLineId = (row["Order Line ID"] || row["Order Item ID"] || row["Item ID"] || "").toString().trim();
    if (!orderNumber && !orderLineId) continue;

    const lineKey = orderLineId || `${orderNumber}_${row["Seller SKU"] || Date.now()}`;
    const key = `${orderNumber || "unknown"}__${lineKey}`;
    if (!grouped[key]) {
      grouped[key] = [];
    }
    grouped[key].push(row);
  }
  return Object.values(grouped);
}

function detectAdjustmentType(group) {
  const feeNames = group.map((row) =>
    normalizeFeeName((row["Fee Name"] || row["Transaction Type"] || "").toString())
  );
  const comments = group
    .map((row) => (row["Comment"] || row["Reason"] || "").toString().trim().toLowerCase())
    .filter(Boolean);

  const hasSalesComponent = feeNames.some((fee) =>
    [
      "product price paid by buyer",
      "item price credit",
      "product price",
      "item price",
      "shipping fee paid by buyer",
      "shipping fee (paid by buyer)",
      "shipping fee discount",
      "shipping fee discount (seller)"
    ].includes(fee)
  );

  const hasOtherCreditOrDebit = feeNames.some(
    (fee) =>
      fee.includes("other credit") ||
      fee.includes("other debit") ||
      fee.includes("credit") ||
      fee.includes("debit") ||
      fee.includes("reversal") ||
      fee.includes("claim")
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
    "compensation",
    "claim"
  ];

  const hasReversalComment = reversalKeywords.some((keyword) =>
    commentText.includes(keyword)
  );

  const standalonePenalty =
    feeNames.length > 0 &&
    feeNames.every((fee) => fee.includes("penalties") || fee.includes("penalty")) &&
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
      reason: commentText || "Financial-only entry without buyer sale component"
    };
  }

  return {
    entryType: "order",
    reason: ""
  };
}

// Fast in-memory or database cost details matcher
async function findCostDetails(group, storeId = null, preloadedCache = null) {
  const first = group[0] || {};
  const sellerSku = (first["Seller SKU"] || first.seller_sku || "").trim();
  const lazadaSku = (first["Lazada SKU"] || first.lazada_sku || "").trim();
  const productName = (first["Product Name"] || first.product_name || "").trim();

  const skuCandidates = extractSkuCandidates(sellerSku, lazadaSku);

  // If cache is provided, use high-speed in-memory lookup
  if (preloadedCache) {
    const { inventoryList, productList, skuMapList, productMap } = preloadedCache;

    // 1. Check CentralInventory (Stock Section - Primary Source with Restock Costs)
    for (const candidate of skuCandidates) {
      const candidateNorm = candidate.toLowerCase();
      const invItem = inventoryList.find((inv) => {
        if (storeId && String(inv.store_id) !== String(storeId)) return false;
        return (inv.seller_sku || "").toLowerCase() === candidateNorm && (inv.cost_price > 0 || inv.purchase_price > 0);
      });

      if (invItem) {
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

    // 2. Check Product Catalog
    for (const candidate of skuCandidates) {
      const candidateNorm = candidate.toLowerCase();
      const prod = productList.find((p) => (p.sku || "").toLowerCase() === candidateNorm && p.purchase_price > 0);
      if (prod) {
        return {
          cost_price: Number(prod.purchase_price),
          matched_product_id: prod._id,
          matched_product_name: prod.name,
          matched_by: `primary_sku:${candidate}`,
          profit_ready: true
        };
      }

      const skuMap = skuMapList.find((m) => (m.sku || "").toLowerCase() === candidateNorm);
      if (skuMap) {
        const mappedProd = productMap.get(String(skuMap.product_id));
        if (mappedProd && mappedProd.purchase_price > 0) {
          return {
            cost_price: Number(mappedProd.purchase_price),
            matched_product_id: mappedProd._id,
            matched_product_name: mappedProd.name,
            matched_by: `mapped_sku:${candidate}`,
            profit_ready: true
          };
        }
      }
    }

    // 3. Match by exact product name
    if (productName) {
      const nameNorm = productName.toLowerCase();
      const prodExact = productList.find((p) => (p.name || "").toLowerCase() === nameNorm && p.purchase_price > 0);
      if (prodExact) {
        return {
          cost_price: Number(prodExact.purchase_price),
          matched_product_id: prodExact._id,
          matched_product_name: prodExact.name,
          matched_by: "name_exact",
          profit_ready: true
        };
      }

      // 4. Partial product name match
      const prodPartial = productList.find((p) => (p.name || "").toLowerCase().includes(nameNorm) && p.purchase_price > 0);
      if (prodPartial) {
        return {
          cost_price: Number(prodPartial.purchase_price),
          matched_product_id: prodPartial._id,
          matched_product_name: prodPartial.name,
          matched_by: "name_partial",
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

  // Fallback to database queries if no preloaded cache
  for (const candidate of skuCandidates) {
    const invQuery = {
      seller_sku: { $regex: new RegExp(`^${escapeRegex(candidate)}$`, "i") },
      is_archived: { $ne: true },
      is_deleted: { $ne: true }
    };
    if (storeId) invQuery.store_id = storeId;
    const invItem = await CentralInventory.findOne(invQuery).sort({ cost_price: -1, purchase_price: -1 }).lean();
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

  for (const candidate of skuCandidates) {
    let product = await Product.findOne({ sku: { $regex: new RegExp(`^${escapeRegex(candidate)}$`, "i") } }).lean();
    if (product && product.purchase_price > 0) {
      return {
        cost_price: Number(product.purchase_price),
        matched_product_id: product._id,
        matched_product_name: product.name,
        matched_by: `primary_sku:${candidate}`,
        profit_ready: true
      };
    }

    const skuMap = await ProductSkuMap.findOne({ sku: { $regex: new RegExp(`^${escapeRegex(candidate)}$`, "i") } }).lean();
    if (skuMap) {
      product = await Product.findById(skuMap.product_id).lean();
      if (product && product.purchase_price > 0) {
        return {
          cost_price: Number(product.purchase_price),
          matched_product_id: product._id,
          matched_product_name: product.name,
          matched_by: `mapped_sku:${candidate}`,
          profit_ready: true
        };
      }
    }
  }

  if (productName) {
    const product = await Product.findOne({
      name: { $regex: `^${escapeRegex(productName)}$`, $options: "i" },
      purchase_price: { $gt: 0 }
    }).lean();
    if (product) {
      return {
        cost_price: Number(product.purchase_price),
        matched_product_id: product._id,
        matched_product_name: product.name,
        matched_by: "name_exact",
        profit_ready: true
      };
    }

    const partialMatch = await Product.findOne({
      name: { $regex: escapeRegex(productName), $options: "i" },
      purchase_price: { $gt: 0 }
    }).lean();
    if (partialMatch) {
      return {
        cost_price: Number(partialMatch.purchase_price),
        matched_product_id: partialMatch._id,
        matched_product_name: partialMatch.name,
        matched_by: "name_partial",
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

async function buildEntryFromGroup(group, defaultStore = null, preloadedCache = null) {
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
    const feeName = (row["Fee Name"] || row["Transaction Type"] || "").trim();
    const feeNameKey = normalizeFeeName(feeName);

    const amount = toNumber(row["Amount(Include Tax)"] || row["Amount"] || 0);
    const vat = absNumber(row["VAT Amount"] || row["VAT"] || 0);
    const wht = absNumber(row["WHT Amount"] || row["WHT"] || 0);

    netSettlement += amount;
    vatTotal += vat;
    whtAmount += wht;

    feeBreakdown[feeName || "Uncategorized"] = (feeBreakdown[feeName || "Uncategorized"] || 0) + amount;

    switch (feeNameKey) {
      case "product price paid by buyer":
      case "item price credit":
      case "product price":
      case "item price":
        productPrice += amount;
        break;
      case "shipping fee paid by buyer":
      case "shipping fee (paid by buyer)":
        shippingPaidByBuyer += amount;
        break;
      case "shipping fee discount":
      case "shipping fee discount (seller)":
      case "promotional shipping fee discount":
        shippingFeeDiscount += amount;
        break;
      case "commission fee":
      case "commission":
      case "daraz commission":
        commissionFee += absNumber(amount);
        break;
      case "payment fee":
      case "payment handling fee":
      case "payment gateway fee":
        paymentFee += absNumber(amount);
        break;
      case "shipping fee":
      case "shipping fee (charged by lazada)":
      case "shipping fee (charged by daraz)":
      case "shipping fee charged by daraz":
        shippingFee += absNumber(amount);
        break;
      case "handling fee":
      case "order handling fee":
      case "handling charge":
        handlingFee += absNumber(amount);
        break;
      case "free shipping max fee":
      case "free shipping max":
      case "free shipping max promotion fee":
        freeShippingMaxFee += absNumber(amount);
        break;
      case "co-funded voucher max":
      case "co-funded voucher":
      case "cofunded voucher":
      case "voucher subsidy":
        cofundedVoucherFee += absNumber(amount);
        break;
      case "daraz coins discount participation fee":
      case "coins discount fee":
      case "coins fee":
        coinsDiscountFee += absNumber(amount);
        break;
      case "penalties for fulfillment":
      case "penalty":
      case "penalties":
      case "fulfillment penalty":
        penalties += absNumber(amount);
        break;
      case "income tax withholding":
      case "income tax":
      case "withholding income tax":
        incomeTaxWithholding += absNumber(amount);
        break;
      case "sales tax withholding":
      case "sales tax":
      case "withholding sales tax":
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
    costDetails = await findCostDetails(group, defaultStore?._id || null, preloadedCache);
  }

  const totalCost =
    adjustmentMeta.entryType === "order"
      ? (costDetails.cost_price || 0) * quantity
      : 0;

  const netProfit =
    adjustmentMeta.entryType === "order" && quantity > 0 && costDetails.profit_ready
      ? Number((netSettlement - totalCost).toFixed(2))
      : null;

  const orderNum = (first["Order Number"] || first["Order No"] || first["Order ID"] || "").toString().trim();
  const rawLineId = (first["Order Line ID"] || first["Order Item ID"] || first["Item ID"] || "").toString().trim();
  const orderLineId = rawLineId || `${orderNum}_${first["Seller SKU"] || Date.now()}`;
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

    order_number: orderNum,
    order_line_id: orderLineId,

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

  // Deduplicate entries by unique order_line_id to prevent any double counting
  const seenLineIds = new Set();
  const uniqueEntries = [];
  for (const item of entries) {
    const key = item.order_line_id || `${item.order_number}_${item._id}`;
    if (seenLineIds.has(key)) continue;
    seenLineIds.add(key);
    uniqueEntries.push(item);
  }

  for (const item of uniqueEntries) {
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

  for (let i = 0; i < count; i++) {
    const mon = new Date(currentMonday);
    mon.setDate(currentMonday.getDate() - i * 7);

    const sun = new Date(mon);
    sun.setDate(mon.getDate() + 6);

    const periodStr = `${formatDarazDate(mon)} - ${formatDarazDate(sun)}`;
    cycles.push({
      statement_period: periodStr,
      start_date: mon,
      end_date: sun,
      is_current: i === 0
    });
  }

  return cycles;
}

// -----------------------------------------------------------------------------
// ROUTES
// -----------------------------------------------------------------------------

// 1. Get Statement Periods list (Weekly cycles + existing statement periods)
router.get("/periods", async (req, res) => {
  try {
    const weeklyCycles = generateDarazWeeklyCycles(16);
    const existingPeriods = await FinanceEntry.distinct("statement_period", {
      statement_period: { $ne: "" }
    });

    const existingSet = new Set(existingPeriods);
    const periodList = [];

    for (const cycle of weeklyCycles) {
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

// Deduplication cleanup utility to remove duplicate order_line_id records if any exist
async function cleanupDuplicateFinanceEntries() {
  try {
    // Also remove any legacy synthetic entries from old estimated sync runs
    await FinanceEntry.deleteMany({ matched_by: "daraz_api_sync" });

    const duplicates = await FinanceEntry.aggregate([
      { $group: { _id: "$order_line_id", count: { $sum: 1 }, docs: { $push: "$_id" } } },
      { $match: { count: { $gt: 1 } } }
    ]);
    for (const dup of duplicates) {
      const [keepId, ...removeIds] = dup.docs;
      if (removeIds.length > 0) {
        await FinanceEntry.deleteMany({ _id: { $in: removeIds } });
      }
    }
  } catch (e) {
    // Non-critical background cleanup notice
  }
}

// 4. Import Statement CSV / Excel Rows (High-speed batch processing)
router.post("/import-csv", async (req, res) => {
  try {
    const { rows = [], store_id = "" } = req.body;

    if (!Array.isArray(rows) || rows.length === 0) {
      return res.status(400).json({ message: "CSV rows are required" });
    }

    let defaultStore = null;
    if (store_id) {
      defaultStore = await Store.findById(store_id).lean();
    }

    // Pre-load all inventories and products into memory for lightning-fast matching
    const [inventoryList, productList, skuMapList] = await Promise.all([
      CentralInventory.find({ is_archived: { $ne: true }, is_deleted: { $ne: true } }).lean(),
      Product.find().lean(),
      ProductSkuMap.find().lean()
    ]);

    const productMap = new Map(productList.map((p) => [String(p._id), p]));
    const preloadedCache = { inventoryList, productList, skuMapList, productMap };

    const groupedRows = groupRowsByOrder(rows);
    const preparedEntries = [];

    for (const group of groupedRows) {
      const entry = await buildEntryFromGroup(group, defaultStore, preloadedCache);
      preparedEntries.push(entry);
    }

    // Fast bulk write
    if (preparedEntries.length > 0) {
      const bulkOps = preparedEntries.map((entry) => ({
        updateOne: {
          filter: { order_line_id: entry.order_line_id },
          update: { $set: entry },
          upsert: true
        }
      }));
      await FinanceEntry.bulkWrite(bulkOps, { ordered: false });
    }

    await cleanupDuplicateFinanceEntries();

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

// Helper to parse statement period string into Date range
function parsePeriodDates(periodString) {
  if (!periodString || periodString === "all") return null;
  const parts = periodString.split("-").map(p => p.trim());
  if (parts.length < 2) return null;

  const startDate = new Date(parts[0]);
  const endDate = new Date(parts[1]);

  if (Number.isNaN(startDate.getTime()) || Number.isNaN(endDate.getTime())) {
    return null;
  }

  startDate.setHours(0, 0, 0, 0);
  endDate.setHours(23, 59, 59, 999);

  return { startDate, endDate };
}

// 7. Auto-Sync Finance Statement from Daraz API
router.post("/sync", async (req, res) => {
  try {
    const { statement_period, store_id } = req.body;
    let period = statement_period?.trim() || "";

    if (!period || period === "all") {
      const currentCycles = generateDarazWeeklyCycles(1);
      period = currentCycles[0]?.statement_period || "";
    }

    const dateRange = parsePeriodDates(period);

    const storeQuery = { status: "active" };
    if (store_id && store_id !== "all") {
      storeQuery._id = store_id;
    }
    const stores = await Store.find(storeQuery);
    if (!stores.length) {
      return res.status(404).json({ message: "No active connected stores found to sync." });
    }

    let totalImportedOrders = 0;
    let totalImportedAdjustments = 0;

    // Pre-load all inventories and products into memory for lightning-fast matching
    const [inventoryList, productList, skuMapList] = await Promise.all([
      CentralInventory.find({ is_archived: { $ne: true }, is_deleted: { $ne: true } }).lean(),
      Product.find().lean(),
      ProductSkuMap.find().lean()
    ]);

    const productMap = new Map(productList.map((p) => [String(p._id), p]));
    const preloadedCache = { inventoryList, productList, skuMapList, productMap };

    for (const store of stores) {
      let storeToken = null;
      try {
        storeToken = await ensureStoreTokenReadyForSync(store._id);
      } catch (err) {
        storeToken = await StoreToken.findOne({ store_id: store._id });
      }

      let storeImported = 0;

      // 1. Live Daraz Open Platform Transaction Details API
      if (storeToken?.access_token && dateRange) {
        try {
          const startTimeStr = dateRange.startDate.toISOString().split("T")[0];
          const endTimeStr = dateRange.endDate.toISOString().split("T")[0];

          const txRes = await getTransactionDetails({
            storeToken,
            startTime: startTimeStr,
            endTime: endTimeStr,
            limit: 100
          });

          if (txRes.transactions && txRes.transactions.length > 0) {
            const grouped = {};
            for (const tx of txRes.transactions) {
              const orderNum = (tx.order_number || tx.orderNumber || tx.trade_order_id || "").toString().trim();
              const lineId = (tx.order_line_id || tx.orderLineId || tx.order_item_id || orderNum || `tx_${tx.transaction_id || Date.now()}`).toString().trim();
              if (!orderNum) continue;

              const key = `${orderNum}__${lineId}`;
              if (!grouped[key]) grouped[key] = [];

              grouped[key].push({
                "Statement Period": period,
                "Statement Number": tx.statement_number || tx.statementNumber || `STMT-${store.code || store.name}-${period.replace(/\s+/g, '_')}`,
                "Order Number": orderNum,
                "Order Line ID": lineId,
                "Seller SKU": tx.seller_sku || tx.sellerSku || "",
                "Lazada SKU": tx.lazada_sku || tx.lazadaSku || "",
                "Product Name": tx.product_name || tx.productName || tx.item_name || "",
                "Fee Name": tx.fee_name || tx.feeName || tx.transaction_type || "",
                "Amount(Include Tax)": tx.amount || 0,
                "VAT Amount": tx.vat_amount || tx.vatAmount || 0,
                "WHT Amount": tx.wht_amount || tx.whtAmount || 0,
                "Comment": tx.comment || tx.reason || "",
                "Quantity": tx.quantity || 1
              });
            }

            const entries = [];
            for (const group of Object.values(grouped)) {
              const entry = await buildEntryFromGroup(group, store, preloadedCache);
              entry.statement_period = period;
              entries.push(entry);
              if (entry.entry_type === "order") totalImportedOrders++;
              else totalImportedAdjustments++;
              storeImported++;
            }

            if (entries.length > 0) {
              const bulkOps = entries.map((entry) => ({
                updateOne: {
                  filter: { order_line_id: entry.order_line_id },
                  update: { $set: entry },
                  upsert: true
                }
              }));
              await FinanceEntry.bulkWrite(bulkOps, { ordered: false });
            }
          }
        } catch (apiErr) {
          console.warn(`[FinanceSync] Live transaction notice for ${store.name}: ${apiErr.message}`);
        }
      }

      // 2. Fallback to Store Orders (Delivered/Shipped orders for this weekly period)
      if (storeImported === 0 && dateRange) {
        try {
          const CentralOrder = require("../models/CentralOrder");
          const CentralOrderItem = require("../models/CentralOrderItem");

          const orderQuery = {
            store_id: store._id,
            $or: [
              { order_created_at: { $gte: dateRange.startDate, $lte: dateRange.endDate } },
              { order_updated_at: { $gte: dateRange.startDate, $lte: dateRange.endDate } },
              { synced_at: { $gte: dateRange.startDate, $lte: dateRange.endDate } }
            ]
          };

          const centralOrders = await CentralOrder.find(orderQuery).lean();
          const orderIds = centralOrders.map(o => o._id);

          if (orderIds.length > 0) {
            const orderItems = await CentralOrderItem.find({ order_id: { $in: orderIds } }).lean();
            const orderMap = new Map(centralOrders.map(o => [o._id.toString(), o]));
            const fallbackEntries = [];

            for (const item of orderItems) {
              const parentOrder = orderMap.get(item.order_id?.toString()) || {};
              const orderNum = item.order_number || parentOrder.order_number || parentOrder.external_order_id || "";
              const lineId = item.external_order_item_id || `${orderNum}_${item.seller_sku}`;
              if (!orderNum) continue;

              const unitPrice = Number(item.unit_price) || Number(item.item_price) || Number(item.paid_price) || 0;
              const qty = Number(item.quantity) || 1;
              const itemGross = Number((unitPrice * qty).toFixed(2));

              const costDetails = await findCostDetails([{
                "Seller SKU": item.seller_sku,
                "Product Name": item.product_name || item.display_title || ""
              }], store._id, preloadedCache);

              const costPrice = costDetails.cost_price || Number(item.cost_price) || 0;
              const totalCost = Number((costPrice * qty).toFixed(2));
              const statementNumber = `STMT-${store.code || store.name}-${period.replace(/\s+/g, '_')}`;

              const entryData = {
                store_id: store._id,
                store_name: store.name,
                store_code: store.code,
                statement_period: period,
                statement_number: statementNumber,
                order_number: orderNum,
                order_line_id: lineId,
                seller_sku: item.seller_sku || "",
                product_name: item.display_title || item.product_name || "",
                order_status: item.status || parentOrder.status || "delivered",
                entry_type: "order",
                product_price: itemGross,
                gross_amount: itemGross,
                total_fees: 0,
                total_taxes: 0,
                total_deductions: 0,
                net_settlement: itemGross,
                cost_price: costPrice,
                quantity: qty,
                total_cost: totalCost,
                net_profit: costPrice > 0 ? Number((itemGross - totalCost).toFixed(2)) : null,
                matched_product_id: costDetails.matched_product_id,
                matched_product_name: costDetails.matched_product_name || item.product_name,
                matched_by: costDetails.matched_by || "store_order_sync",
                profit_ready: costPrice > 0,
                fee_breakdown: {
                  "Product Price Paid by Buyer": itemGross
                },
                imported_at: new Date()
              };

              fallbackEntries.push(entryData);
              totalImportedOrders++;
            }

            if (fallbackEntries.length > 0) {
              const bulkOps = fallbackEntries.map((entry) => ({
                updateOne: {
                  filter: { order_line_id: entry.order_line_id },
                  update: { $set: entry },
                  upsert: true
                }
              }));
              await FinanceEntry.bulkWrite(bulkOps, { ordered: false });
            }
          }
        } catch (orderErr) {
          console.warn(`[FinanceSync] Store order sync notice: ${orderErr.message}`);
        }
      }
    }

    await cleanupDuplicateFinanceEntries();

    const allEntries = await FinanceEntry.find({ statement_period: period }).lean();
    const totals = buildSummary(allEntries);

    const message = totalImportedOrders > 0 || totalImportedAdjustments > 0
      ? `Successfully imported ${totalImportedOrders} order(s) for "${period}".`
      : `No transactions found for "${period}". Import your Daraz Statement CSV/Excel file for complete details.`;

    res.json({
      success: true,
      message,
      imported_orders: totalImportedOrders,
      imported_adjustments: totalImportedAdjustments,
      totals
    });
  } catch (error) {
    res.status(500).json({ message: "Error syncing finance statements from Daraz", error: error.message });
  }
});

module.exports = router;