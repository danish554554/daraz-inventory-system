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
const XLSX = require("xlsx");

function parseDarazFileToRows(bufferOrText) {
  let workbook;
  if (Buffer.isBuffer(bufferOrText)) {
    workbook = XLSX.read(bufferOrText, { type: "buffer", raw: false });
  } else if (typeof bufferOrText === "string") {
    workbook = XLSX.read(bufferOrText, { type: "string", raw: false });
  } else {
    return [];
  }

  if (!workbook || !workbook.SheetNames || workbook.SheetNames.length === 0) {
    return [];
  }

  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  const rawMatrix = XLSX.utils.sheet_to_json(sheet, { header: 1, defval: "" });
  if (!rawMatrix || rawMatrix.length === 0) return [];

  // Locate the true header row by scanning first 15 rows for known keywords
  let headerRowIndex = -1;
  for (let r = 0; r < Math.min(15, rawMatrix.length); r++) {
    const row = rawMatrix[r] || [];
    const joined = row.map((cell) => String(cell || "").toLowerCase().trim()).join(" ");
    if (
      (joined.includes("order number") || joined.includes("order no") || joined.includes("order id") || joined.includes("statement detail")) &&
      (joined.includes("fee name") || joined.includes("amount") || joined.includes("transaction type") || joined.includes("statement") || joined.includes("released amount") || joined.includes("release status"))
    ) {
      headerRowIndex = r;
      break;
    }
  }

  if (headerRowIndex === -1) {
    headerRowIndex = 0;
  }

  const headerRow = rawMatrix[headerRowIndex] || [];
  const normalizedHeaders = headerRow.map((col) => {
    let clean = String(col || "").replace(/^\uFEFF/, "").trim();
    const lower = clean.toLowerCase();
    if (
      lower === "order no" ||
      lower === "order no." ||
      lower === "order id" ||
      lower === "order_number" ||
      lower === "order no/order id" ||
      lower === "order no / order id" ||
      lower.includes("order no/order id") ||
      lower === "trade order id"
    ) {
      return "Order Number";
    }
    if (
      lower === "order line id" ||
      lower === "order item id" ||
      lower === "order item no" ||
      lower === "order item no." ||
      lower === "order line no" ||
      lower === "item id" ||
      lower === "order line" ||
      lower.includes("order line id")
    ) {
      return "Order Line ID";
    }
    if (lower === "seller sku" || lower === "sellersku") {
      return "Seller SKU";
    }
    if (lower === "lazada sku" || lower === "daraz sku") {
      return "Lazada SKU";
    }
    if (
      lower === "fee name" ||
      lower === "feename" ||
      lower === "transaction type" ||
      lower === "fee details" ||
      lower === "fee type"
    ) {
      return "Fee Name";
    }
    if (
      lower === "amount(include tax)" ||
      lower === "amount (include tax)" ||
      lower === "amount(incl tax)" ||
      lower === "amount (incl tax)" ||
      lower === "amount" ||
      lower === "released amount" ||
      lower === "released amount (pkr)" ||
      lower === "released amount(pkr)" ||
      lower.includes("released amount") ||
      lower === "net amount" ||
      lower === "settlement amount"
    ) {
      return "Amount(Include Tax)";
    }
    if (lower === "vat amount" || lower === "vat" || lower === "vat in amount") {
      return "VAT Amount";
    }
    if (lower === "transaction number" || lower === "transaction no" || lower === "transaction no.") {
      return "Transaction Number";
    }
    if (lower === "statement") {
      return "Statement Number";
    }
    if (lower === "paid status") {
      return "Release Status";
    }
    if (lower === "order item status") {
      return "Order Status";
    }
    if (lower === "wht amount" || lower === "wht") {
      return "WHT Amount";
    }
    if (lower === "statement period" || lower === "period") {
      return "Statement Period";
    }
    if (lower === "statement number" || lower === "statement no") {
      return "Statement Number";
    }
    if (lower === "product name" || lower === "item name") {
      return "Product Name";
    }
    if (lower === "order status" || lower === "status") {
      return "Order Status";
    }
    if (lower === "release status" || lower.includes("release status")) {
      return "Release Status";
    }
    if (lower === "order creation date" || lower.includes("creation date")) {
      return "Order Creation Date";
    }
    if (lower === "details" || lower === "item details") {
      return "Details";
    }
    if (lower === "quantity" || lower === "qty") {
      return "Quantity";
    }
    return clean;
  });

  const parsedRows = [];
  for (let r = headerRowIndex + 1; r < rawMatrix.length; r++) {
    const dataRow = rawMatrix[r] || [];
    if (!dataRow || dataRow.length === 0) continue;
    const rowObj = {};
    let hasData = false;
    for (let c = 0; c < normalizedHeaders.length; c++) {
      const h = normalizedHeaders[c];
      if (!h) continue;
      const val = dataRow[c] !== undefined && dataRow[c] !== null ? String(dataRow[c]).trim() : "";
      if (val) hasData = true;
      rowObj[h] = val;
    }
    if (hasData) {
      // Auto-extract Order Number & Order Line ID if embedded in 'Details' column
      if (rowObj["Details"]) {
        const detailsStr = String(rowObj["Details"]);
        if (!rowObj["Order Number"]) {
          const matchOrder = detailsStr.match(/Order\s*Number\s*[:#]?\s*(\d+)/i) || detailsStr.match(/Order\s*ID\s*[:#]?\s*(\d+)/i);
          if (matchOrder) rowObj["Order Number"] = matchOrder[1];
        }
        if (!rowObj["Order Line ID"]) {
          const matchLine = detailsStr.match(/Order\s*Line\s*ID\s*[:#]?\s*(\d+)/i) || detailsStr.match(/Item\s*ID\s*[:#]?\s*(\d+)/i);
          if (matchLine) rowObj["Order Line ID"] = matchLine[1];
        }
        if (!rowObj["Product Name"]) {
          const prodTitle = detailsStr.split(/Order\s*Number/i)[0].trim();
          if (prodTitle) rowObj["Product Name"] = prodTitle;
        }
      }
      parsedRows.push(rowObj);
    }
  }

  return parsedRows;
}

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

// Precision monetary rounding (2 decimal places)
function roundMoney(num) {
  if (typeof num !== "number" || Number.isNaN(num)) return 0;
  return Math.round((num + Number.EPSILON) * 100) / 100;
}

// Authoritative Daraz Pakistan Handling Fee Tiers
// Tier 1: Package Price < PKR 1,000 -> Base PKR 15.00 + 16% PST = PKR 17.40
// Tier 2: Package Price PKR 1,000 - 1,999.99 -> Base PKR 20.00 + 15% PST = PKR 23.00
// Tier 3: Package Price >= PKR 2,000 -> Base PKR 60.00 + 15% PST = PKR 69.00
function getDarazHandlingFee(packagePrice) {
  const price = Number(packagePrice) || 0;
  if (price >= 2000) {
    return 69.00;
  }
  if (price >= 1000) {
    return 23.00;
  }
  return 17.40;
}

// Category Commission Rules & Tax Rates
const DARAZ_CATEGORY_RULES = {
  cookware: {
    name: "Cookware / Kitchen Appliances",
    baseRate: 0.100003,
    taxRate: 0.15,
    effectiveRate: 0.1150035, // ~11.50% (PKR 160.89 on PKR 1,399.00)
    whtExempt: true           // Section 236V income tax WHT exempt
  },
  beauty: {
    name: "Health & Beauty / Personal Care",
    baseRate: 0.160401,
    taxRate: 0.15,
    effectiveRate: 0.1844612, // ~18.45% (PKR 415.96 on PKR 2,255.00)
    whtExempt: false          // 2.0% Section 236V income tax WHT on >= 1000
  },
  electronics: {
    name: "Mobile Accessories & Electronics",
    baseRate: 0.1450,
    taxRate: 0.16,
    effectiveRate: 0.1682,    // ~16.82% (14.5% base + 16% PST)
    whtExempt: true
  },
  default: {
    name: "General Merchandise",
    baseRate: 0.1500,
    taxRate: 0.16,
    effectiveRate: 0.1740,    // ~17.40%
    whtExempt: false
  }
};

// Whole-word keyword matching (optional plural) so "pan" does not match "panel" or "Japan"
function keywordRegex(words) {
  return new RegExp(`\\b(?:${words.join("|")})(?:e?s)?\\b`, "i");
}

const CATEGORY_KEYWORDS = [
  [keywordRegex(["fryer", "pot", "pan", "kitchen", "cookware", "kettle", "blender", "cooker", "utensil", "chopper"]), "cookware"],
  [keywordRegex(["hair", "remover", "shaver", "callus", "trimmer", "beauty", "derma", "serum", "cream", "epilator"]), "beauty"],
  [keywordRegex(["headphone", "earphone", "earbud", "charger", "cable", "adapter", "speaker", "smart watch", "watch"]), "electronics"]
];

function resolveCategoryRule(titleText = "") {
  const text = titleText || "";
  const match = CATEGORY_KEYWORDS.find(([regex]) => regex.test(text));
  return DARAZ_CATEGORY_RULES[match ? match[1] : "default"];
}

// Store Free Shipping Max (FSM) Enrollment Determination
function isStoreEnrolledInFSM(store = null, storeName = "", storeCode = "") {
  // Explicit Store.fsm_enrolled wins; the name heuristic below is only a fallback for unset stores
  if (store?.fsm_enrolled != null) return Boolean(store.fsm_enrolled);
  if (store?.free_shipping_max != null) return Boolean(store.free_shipping_max);
  const name = (store?.name || store?.store_name || storeName || "").toLowerCase();
  const code = (store?.code || store?.store_code || storeCode || "").toLowerCase();
  if (name.includes("tk") || name.includes("dkart") || name.includes("d-kart") || code.includes("tk") || code.includes("dkart")) {
    return false;
  }
  if (name.includes("accessories") || name.includes("hub") || code.includes("accessories") || code.includes("hub")) {
    return true;
  }
  return false;
}

function normalizeFeeName(name = "") {
  return name.toString().trim().toLowerCase();
}

function escapeRegex(value = "") {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function extractFirstNonEmpty(group = [], ...keys) {
  const rows = Array.isArray(group) ? group : [group];
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    for (const key of keys) {
      const val = (row[key] ?? "").toString().trim();
      if (val) return val;
    }
  }
  return "";
}

function extractEntryLineId(group = []) {
  const rows = Array.isArray(group) ? group : [group];
  const rawLineId = extractFirstNonEmpty(rows, "Order Line ID", "Order Item ID", "Item ID", "order_line_id");
  if (rawLineId) return rawLineId;

  const orderNum = extractFirstNonEmpty(rows, "Order Number", "Order No", "Order ID", "order_number");
  const sku = extractFirstNonEmpty(rows, "Seller SKU", "seller_sku");
  const fee = extractFirstNonEmpty(rows, "Fee Name", "Transaction Type");
  return `${orderNum || "adj"}_${sku || fee || "line"}`;
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
      const hyphenated = cleaned.replace(/\s+/g, "-");
      if (hyphenated) candidates.add(hyphenated);
      const spaced = cleaned.replace(/[-_]+/g, " ");
      if (spaced) candidates.add(spaced);
    }
  };

  add(sellerSku);
  add(lazadaSku);

  const cleanSeller = (sellerSku || "").toString().trim();
  const strippedSuffix = cleanSeller.replace(/[-_\s]\d+$/, "");
  if (strippedSuffix && strippedSuffix !== cleanSeller) {
    add(strippedSuffix);
  }

  const cleanLazada = (lazadaSku || "").toString().trim();
  const strippedLazadaSuffix = cleanLazada.replace(/[-_\s]\d+$/, "");
  if (strippedLazadaSuffix && strippedLazadaSuffix !== cleanLazada) {
    add(strippedLazadaSuffix);
  }

  if (cleanSeller.includes("-")) {
    add(cleanSeller.split("-")[0].trim());
    add(cleanSeller.split("-").slice(0, 2).join("-").trim());
  }
  if (cleanSeller.includes("_")) {
    add(cleanSeller.split("_")[0].trim());
    add(cleanSeller.split("_").slice(0, 2).join("_").trim());
  }
  if (cleanSeller.includes(" ")) {
    add(cleanSeller.split(" ")[0].trim());
    add(cleanSeller.split(" ").slice(0, 2).join(" ").trim());
  }
  if (cleanLazada.includes("_")) {
    add(cleanLazada.split("_")[0].trim());
    add(cleanLazada.split("_").slice(0, 2).join("_").trim());
  }
  if (cleanLazada.includes("-")) {
    add(cleanLazada.split("-")[0].trim());
    add(cleanLazada.split("-").slice(0, 2).join("-").trim());
  }

  return Array.from(candidates);
}

function extractQuantity(group = []) {
  const rows = Array.isArray(group) ? group : [group];
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const possibleQty =
      row["Quantity"] ??
      row["Qty"] ??
      row["Item Quantity"] ??
      row["Quantity Ordered"] ??
      row.quantity;

    if (possibleQty !== null && possibleQty !== undefined && possibleQty !== "") {
      const parsedQty = Number(possibleQty);
      if (!Number.isNaN(parsedQty) && parsedQty > 0) {
        return parsedQty;
      }
    }
  }
  return 1;
}

function groupRowsByOrder(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return [];

  const orders = new Map();
  const adjustments = [];

  for (const row of rows) {
    const orderNumber = (row["Order Number"] || row["Order No"] || row["Order ID"] || "").toString().trim();
    const orderLineId = (row["Order Line ID"] || row["Order Item ID"] || row["Item ID"] || "").toString().trim();

    if (!orderNumber && !orderLineId) {
      const adjKey = (row["Fee Name"] || row["Transaction Type"] || "adjustment").toString().trim();
      const statementNum = (row["Statement Number"] || row["Statement"] || "no_stmt").toString().trim();
      adjustments.push({ ...row, _adjKey: `${statementNum}__${adjKey}` });
      continue;
    }

    const orderKey = orderNumber || `no_order_${orderLineId}`;
    if (!orders.has(orderKey)) {
      orders.set(orderKey, []);
    }
    orders.get(orderKey).push(row);
  }

  const resultGroups = [];

  if (adjustments.length > 0) {
    const adjMap = new Map();
    for (const row of adjustments) {
      const key = row._adjKey;
      delete row._adjKey;
      if (!adjMap.has(key)) adjMap.set(key, []);
      adjMap.get(key).push(row);
    }
    for (const group of adjMap.values()) {
      resultGroups.push(group);
    }
  }

  for (const [orderKey, orderRows] of orders.entries()) {
    const lineIds = new Set();
    for (const row of orderRows) {
      const lineId = (row["Order Line ID"] || row["Order Item ID"] || row["Item ID"] || "").toString().trim();
      if (lineId) lineIds.add(lineId);
    }

    if (lineIds.size <= 1) {
      const targetLineId = lineIds.size === 1 ? Array.from(lineIds)[0] : "";
      const targetSellerSku = extractFirstNonEmpty(orderRows, "Seller SKU", "seller_sku");
      const targetLazadaSku = extractFirstNonEmpty(orderRows, "Lazada SKU", "lazada_sku");
      const targetProdName = extractFirstNonEmpty(orderRows, "Product Name", "product_name");

      for (const row of orderRows) {
        if (targetLineId && !row["Order Line ID"]) {
          row["Order Line ID"] = targetLineId;
        }
        if (targetSellerSku && !row["Seller SKU"] && !row.seller_sku) {
          row["Seller SKU"] = targetSellerSku;
        }
        if (targetLazadaSku && !row["Lazada SKU"] && !row.lazada_sku) {
          row["Lazada SKU"] = targetLazadaSku;
        }
        if (targetProdName && !row["Product Name"] && !row.product_name) {
          row["Product Name"] = targetProdName;
        }
      }
      resultGroups.push(orderRows);
    } else {
      const itemGroups = new Map();
      const orderLevelRows = [];

      for (const lineId of lineIds) {
        itemGroups.set(lineId, []);
      }

      for (const row of orderRows) {
        const lineId = (row["Order Line ID"] || row["Order Item ID"] || row["Item ID"] || "").toString().trim();
        if (lineId && itemGroups.has(lineId)) {
          itemGroups.get(lineId).push(row);
        } else {
          orderLevelRows.push(row);
        }
      }

      if (orderLevelRows.length > 0) {
        const lineIdsArray = Array.from(lineIds);
        const itemPrices = lineIdsArray.map((lid) => {
          const rList = itemGroups.get(lid) || [];
          let sum = 0;
          for (const r of rList) {
            const fee = normalizeFeeName(r["Fee Name"] || r["Transaction Type"] || "");
            if (fee.includes("product price") || fee.includes("item price")) {
              sum += Math.abs(toNumber(r["Amount(Include Tax)"] || r["Amount"] || 0));
            }
          }
          return sum;
        });

        const totalItemPrice = itemPrices.reduce((a, b) => a + b, 0);

        for (const oRow of orderLevelRows) {
          const totalAmount = toNumber(oRow["Amount(Include Tax)"] || oRow["Amount"] || 0);
          const totalVat = toNumber(oRow["VAT Amount"] || oRow["VAT"] || 0);
          const totalWht = toNumber(oRow["WHT Amount"] || oRow["WHT"] || 0);

          let allocatedAmount = 0;
          let allocatedVat = 0;
          let allocatedWht = 0;

          for (let i = 0; i < lineIdsArray.length; i++) {
            const isLast = i === lineIdsArray.length - 1;
            const ratio = totalItemPrice > 0
              ? itemPrices[i] / totalItemPrice
              : 1 / lineIdsArray.length;

            const partAmount = isLast ? roundMoney(totalAmount - allocatedAmount) : roundMoney(totalAmount * ratio);
            const partVat = isLast ? roundMoney(totalVat - allocatedVat) : roundMoney(totalVat * ratio);
            const partWht = isLast ? roundMoney(totalWht - allocatedWht) : roundMoney(totalWht * ratio);

            allocatedAmount += partAmount;
            allocatedVat += partVat;
            allocatedWht += partWht;

            const clonedRow = {
              ...oRow,
              "Order Line ID": lineIdsArray[i],
              "Amount(Include Tax)": partAmount,
              "Amount": partAmount,
              "VAT Amount": partVat,
              "WHT Amount": partWht
            };
            itemGroups.get(lineIdsArray[i]).push(clonedRow);
          }
        }
      }

      for (const group of itemGroups.values()) {
        if (group.length > 0) {
          const targetSellerSku = extractFirstNonEmpty(group, "Seller SKU", "seller_sku");
          const targetLazadaSku = extractFirstNonEmpty(group, "Lazada SKU", "lazada_sku");
          const targetProdName = extractFirstNonEmpty(group, "Product Name", "product_name");
          for (const row of group) {
            if (targetSellerSku && !row["Seller SKU"] && !row.seller_sku) {
              row["Seller SKU"] = targetSellerSku;
            }
            if (targetLazadaSku && !row["Lazada SKU"] && !row.lazada_sku) {
              row["Lazada SKU"] = targetLazadaSku;
            }
            if (targetProdName && !row["Product Name"] && !row.product_name) {
              row["Product Name"] = targetProdName;
            }
          }
          resultGroups.push(group);
        }
      }
    }
  }

  return resultGroups;
}

function entryLineId(target = {}) {
  if (Array.isArray(target)) return extractEntryLineId(target);
  return extractEntryLineId([target]);
}

// Stable identity for one Daraz statement line. Daraz's Transaction Number when present;
// otherwise statement + date + fee + amount, plus an occurrence index so two genuinely identical
// lines in one batch both survive while re-importing the same batch is a no-op.
function tagRowFingerprints(rows = []) {
  const counts = new Map();
  return rows.map((row) => {
    const txn = String(row["Transaction Number"] || "").trim();
    const base = txn
      ? `txn:${txn}`
      : [row["Statement Number"], row["Transaction Date"], row["Fee Name"], toNumber(row["Amount(Include Tax)"])]
          .map((value) => String(value ?? "").trim().toLowerCase())
          .join("|");
    const n = (counts.get(base) || 0) + 1;
    counts.set(base, n);
    return { ...row, _fp: `${base}#${n}` };
  });
}

// Union of previously stored statement lines and newly imported ones, deduplicated by fingerprint
function mergeStatementRows(existingRows = [], newRows = []) {
  const merged = new Map();
  for (const row of [...existingRows, ...newRows]) {
    if (row?._fp && !merged.has(row._fp)) merged.set(row._fp, row);
  }
  return Array.from(merged.values());
}

function detectAdjustmentType(group) {
  const first = group[0] || {};
  const orderNum = extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number") ||
    (first["Order Number"] || first["Order No"] || first["Order ID"] || "").toString().trim();
  const rawStatus = extractFirstNonEmpty(group, "Order Status", "Status", "Release Status", "order_status") ||
    (first["Order Status"] || first["Status"] || first["Release Status"] || "").toString().trim();
  const feeNames = group.map((row) =>
    normalizeFeeName((row["Fee Name"] || row["Transaction Type"] || "").toString())
  );
  const comments = group
    .map((row) => (row["Comment"] || row["Reason"] || "").toString().trim().toLowerCase())
    .filter(Boolean);

  const commentText = comments.join(" | ");
  const feeNamesText = feeNames.join(" | ");

  // If there is a real order number, associate it with that ORDER
  if (orderNum && orderNum !== "0" && orderNum.toLowerCase() !== "null") {
    let reason = rawStatus;
    if (commentText.includes("return") || feeNamesText.includes("return")) {
      reason = "Returned";
    } else if (commentText.includes("penalt") || feeNamesText.includes("penalt") || feeNamesText.includes("fine")) {
      reason = "Order Penalty Charged";
    }
    return {
      entryType: "order",
      reason: reason || rawStatus || "Delivered"
    };
  }

  // Otherwise, it's a standalone account adjustment, penalty, or credit
  return {
    entryType: "adjustment",
    reason: commentText || feeNames.join(", ") || "Financial adjustment"
  };
}

function normAlnum(str) {
  return (str || "").toString().toLowerCase().replace(/[^a-z0-9]/g, "");
}

function fuzzyMatchTitle(nameA, nameB) {
  if (!nameA || !nameB) return false;
  const normA = normAlnum(nameA);
  const normB = normAlnum(nameB);
  if (!normA || !normB) return false;
  if (normA === normB || normA.includes(normB) || normB.includes(normA)) return true;

  // Prefix match of significant length (e.g. first 14+ characters match)
  const minLen = Math.min(normA.length, normB.length);
  const checkPrefixLen = Math.min(18, minLen);
  if (checkPrefixLen >= 12 && normA.slice(0, checkPrefixLen) === normB.slice(0, checkPrefixLen)) {
    return true;
  }

  // Word token overlap (words of length >= 3)
  const extractWords = (str) =>
    (str || "")
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length >= 3);
  const wordsA = new Set(extractWords(nameA));
  const wordsB = new Set(extractWords(nameB));
  if (wordsA.size === 0 || wordsB.size === 0) return false;

  let common = 0;
  for (const w of wordsA) {
    if (wordsB.has(w)) common++;
  }
  const minCount = Math.min(wordsA.size, wordsB.size);
  if (common >= 3 || (minCount >= 2 && common / minCount >= 0.7)) {
    return true;
  }
  return false;
}

// Fast in-memory or database cost details matcher
async function findCostDetails(group, storeId = null, preloadedCache = null) {
  let sellerSku = extractFirstNonEmpty(group, "Seller SKU", "seller_sku");
  let lazadaSku = extractFirstNonEmpty(group, "Lazada SKU", "lazada_sku");
  let productName = extractFirstNonEmpty(group, "Product Name", "product_name");
  const orderNum = extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number");
  const orderLineId = extractEntryLineId(group);

  if ((!sellerSku || !productName) && (orderLineId || orderNum)) {
    try {
      const CentralOrderItem = require("../models/CentralOrderItem");
      const CentralOrder = require("../models/CentralOrder");
      let item = null;
      if (orderLineId) {
        item = await CentralOrderItem.findOne({ external_order_item_id: orderLineId }).lean();
      }
      if (!item && orderNum) {
        const parentOrder = await CentralOrder.findOne({
          $or: [{ order_number: orderNum }, { external_order_id: orderNum }]
        }).select("_id").lean();
        if (parentOrder) {
          item = await CentralOrderItem.findOne({ order_id: parentOrder._id }).lean();
        }
      }
      if (item) {
        if (!sellerSku) sellerSku = item.seller_sku || "";
        if (!productName) productName = item.product_name || item.display_title || item.original_product_name || "";
      }
    } catch (_) {}
  }

  const skuCandidates = extractSkuCandidates(sellerSku, lazadaSku);

  const matchesSkuCandidate = (invSku) => {
    const invNorm = normAlnum(invSku);
    if (!invNorm) return false;
    for (const candidate of skuCandidates) {
      const candNorm = candidate.toLowerCase();
      const candAlnum = normAlnum(candidate);
      if (invSku.toLowerCase() === candNorm || (candAlnum && invNorm === candAlnum)) return true;
      if (candAlnum && candAlnum.length >= 6 && (invNorm.startsWith(candAlnum) || candAlnum.startsWith(invNorm))) return true;
    }
    return false;
  };

  // If cache is provided, use high-speed in-memory lookup
  if (preloadedCache) {
    const { inventoryList, productList, skuMapList, productMap } = preloadedCache;

    // 1a. Check CentralInventory (Stock Section - Primary Source with Restock Costs) for current store
    if (storeId) {
      const storeStr = String(storeId);
      const invItem = inventoryList.find((inv) => {
        if (String(inv.store_id) !== storeStr) return false;
        return matchesSkuCandidate(inv.seller_sku) && (inv.cost_price > 0 || inv.purchase_price > 0);
      });
      if (invItem) {
        const cost = invItem.cost_price > 0 ? invItem.cost_price : invItem.purchase_price;
        return {
          cost_price: Number(cost),
          matched_product_id: invItem._id,
          matched_product_name: invItem.product_name || invItem.display_title || productName,
          matched_by: `central_inventory:${invItem.seller_sku}`,
          profit_ready: true
        };
      }
    }

    // 1b. Check CentralInventory cross-store fallback (warehouse inventory purchased under any store)
    const invCross = inventoryList.find((inv) => matchesSkuCandidate(inv.seller_sku) && (inv.cost_price > 0 || inv.purchase_price > 0));
    if (invCross) {
      const cost = invCross.cost_price > 0 ? invCross.cost_price : invCross.purchase_price;
      return {
        cost_price: Number(cost),
        matched_product_id: invCross._id,
        matched_product_name: invCross.product_name || invCross.display_title || productName,
        matched_by: `central_inventory_cross_store:${invCross.seller_sku}`,
        profit_ready: true
      };
    }

    // 1c. Check CentralInventory by Product Name (current store first, then cross-store)
    if (productName) {
      let invByName = null;
      if (storeId) {
        const storeStr = String(storeId);
        invByName = inventoryList.find((inv) => {
          if (String(inv.store_id) !== storeStr) return false;
          const targetTitle = inv.product_name || inv.display_title || inv.original_product_name || "";
          return fuzzyMatchTitle(targetTitle, productName) && (inv.cost_price > 0 || inv.purchase_price > 0);
        });
      }
      if (!invByName) {
        invByName = inventoryList.find((inv) => {
          const targetTitle = inv.product_name || inv.display_title || inv.original_product_name || "";
          return fuzzyMatchTitle(targetTitle, productName) && (inv.cost_price > 0 || inv.purchase_price > 0);
        });
      }
      if (invByName) {
        const cost = invByName.cost_price > 0 ? invByName.cost_price : invByName.purchase_price;
        return {
          cost_price: Number(cost),
          matched_product_id: invByName._id,
          matched_product_name: invByName.product_name || invByName.display_title || productName,
          matched_by: `central_inventory_name:${invByName.seller_sku}`,
          profit_ready: true
        };
      }
    }

    // 2. Check Product Catalog
    for (const candidate of skuCandidates) {
      const candidateNorm = candidate.toLowerCase();
      const candAlnum = normAlnum(candidate);
      const prod = productList.find((p) => {
        const pSku = (p.sku || "").toLowerCase();
        return (pSku === candidateNorm || (candAlnum && normAlnum(p.sku) === candAlnum)) && p.purchase_price > 0;
      });
      if (prod) {
        return {
          cost_price: Number(prod.purchase_price),
          matched_product_id: prod._id,
          matched_product_name: prod.name,
          matched_by: `primary_sku:${candidate}`,
          profit_ready: true
        };
      }

      const skuMap = skuMapList.find((m) => (m.sku || "").toLowerCase() === candidateNorm || (candAlnum && normAlnum(m.sku) === candAlnum));
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

    // 3. Match Product Catalog by exact product name
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

      // 4. Partial product name match in Product Catalog
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
    let invItem = await CentralInventory.findOne(invQuery).sort({ cost_price: -1, purchase_price: -1 }).lean();
    if ((!invItem || (invItem.cost_price <= 0 && invItem.purchase_price <= 0)) && storeId) {
      delete invQuery.store_id;
      invItem = await CentralInventory.findOne(invQuery).sort({ cost_price: -1, purchase_price: -1 }).lean();
    }
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

  // Check CentralInventory by base ID prefix
  const baseId = (sellerSku || "").split(/[-_\s]/)[0]?.trim();
  if (baseId && baseId.length >= 6) {
    const invBase = await CentralInventory.findOne({
      seller_sku: { $regex: new RegExp(`^${escapeRegex(baseId)}([-_\\s]|$)`, "i") },
      $or: [{ cost_price: { $gt: 0 } }, { purchase_price: { $gt: 0 } }],
      is_archived: { $ne: true },
      is_deleted: { $ne: true }
    }).sort({ cost_price: -1, purchase_price: -1 }).lean();
    if (invBase) {
      const cost = invBase.cost_price > 0 ? invBase.cost_price : invBase.purchase_price;
      return {
        cost_price: Number(cost),
        matched_product_id: invBase._id,
        matched_product_name: invBase.product_name || invBase.display_title || productName,
        matched_by: `central_inventory_base:${baseId}`,
        profit_ready: true
      };
    }
  }

  // Check CentralInventory by Product Name
  if (productName) {
    const baseTitle = productName.split(/[-–—|,(]/)[0]?.trim();
    const nameRegexes = [new RegExp(escapeRegex(productName), "i")];
    if (baseTitle && baseTitle.length >= 6 && baseTitle !== productName) {
      nameRegexes.push(new RegExp(escapeRegex(baseTitle), "i"));
    }
    const nameOrConditions = [];
    nameRegexes.forEach((rgx) => {
      nameOrConditions.push({ product_name: rgx });
      nameOrConditions.push({ display_title: rgx });
      nameOrConditions.push({ original_product_name: rgx });
    });

    const invNameMatch = await CentralInventory.findOne({
      $and: [
        { $or: nameOrConditions },
        { $or: [{ cost_price: { $gt: 0 } }, { purchase_price: { $gt: 0 } }] }
      ],
      is_archived: { $ne: true },
      is_deleted: { $ne: true }
    }).sort({ cost_price: -1, purchase_price: -1 }).lean();
    if (invNameMatch) {
      const cost = invNameMatch.cost_price > 0 ? invNameMatch.cost_price : invNameMatch.purchase_price;
      return {
        cost_price: Number(cost),
        matched_product_id: invNameMatch._id,
        matched_product_name: invNameMatch.product_name || invNameMatch.display_title || productName,
        matched_by: `central_inventory_name:${invNameMatch.seller_sku}`,
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

async function buildEntryFromGroup(group = [], defaultStore = null, preloadedCache = null) {
  if (!Array.isArray(group) || group.length === 0) return null;
  const first = group[0] || {};
  const adjustmentMeta = detectAdjustmentType(group);

  let productPrice = 0;
  let shippingPaidByBuyer = 0;
  let shippingFeeDiscount = 0;
  let otherCredits = 0;

  let commissionFee = 0;
  let paymentFee = 0;
  let shippingFee = 0;
  let handlingFee = 0;
  let freeShippingMaxFee = 0;
  let cofundedVoucherFee = 0;
  let coinsDiscountFee = 0;
  let penalties = 0;
  let penaltiesRefunded = 0;
  let otherFees = 0;

  let incomeTaxWithholding = 0;
  let salesTaxWithholding = 0;
  let otherTaxes = 0;
  let whtAmount = 0;
  let vatTotal = 0;

  // The official signed sum from Daraz statement
  let rawSignedSum = 0;
  const feeBreakdown = {};

  for (const row of group) {
    const rawFeeName = (row["Fee Name"] || row["Transaction Type"] || "").trim();
    const feeNameKey = normalizeFeeName(rawFeeName);

    const amount = toNumber(row["Amount(Include Tax)"] || row["Amount"] || 0);
    const vat = absNumber(row["VAT Amount"] || row["VAT"] || 0);
    const wht = absNumber(row["WHT Amount"] || row["WHT"] || 0);

    // Sum every signed transaction amount from Daraz official statement
    rawSignedSum += amount;
    vatTotal += vat;
    whtAmount += wht;

    feeBreakdown[rawFeeName || "Uncategorized"] = roundMoney((feeBreakdown[rawFeeName || "Uncategorized"] || 0) + amount);

    const isPenaltyReversal =
      feeNameKey.includes("reversal") ||
      feeNameKey.includes("refund") ||
      feeNameKey.includes("reimburse") ||
      feeNameKey.includes("compensation") ||
      (feeNameKey.includes("penalt") && amount > 0);

    // 1. Taxes (Explicit statement lines only)
    if (
      feeNameKey.includes("income tax") ||
      feeNameKey.includes("withholding income tax") ||
      feeNameKey.includes("236v") ||
      feeNameKey.includes("wht")
    ) {
      incomeTaxWithholding += absNumber(amount);
    } else if (
      feeNameKey.includes("sales tax") ||
      feeNameKey.includes("withholding sales tax")
    ) {
      salesTaxWithholding += absNumber(amount);
    } else if (
      feeNameKey.includes("tax") && !feeNameKey.includes("include tax") && !feeNameKey.includes("incl tax")
    ) {
      otherTaxes += absNumber(amount);
    }
    // 2. Credits & Buyer Payments
    else if (
      feeNameKey.includes("product price") ||
      feeNameKey.includes("item price") ||
      feeNameKey.includes("item credit")
    ) {
      productPrice += amount;
    } else if (
      feeNameKey.includes("shipping fee paid by buyer") ||
      feeNameKey.includes("shipping fee (paid by buyer)") ||
      feeNameKey.includes("buyer shipping")
    ) {
      shippingPaidByBuyer += amount;
    } else if (
      feeNameKey.includes("shipping fee discount") ||
      feeNameKey.includes("shipping discount")
    ) {
      shippingFeeDiscount += amount;
    }
    // 3. Platform Fees & Deductions
    else if (feeNameKey.includes("commission")) {
      commissionFee += absNumber(amount);
    } else if (
      feeNameKey.includes("payment fee") ||
      feeNameKey.includes("payment handling") ||
      feeNameKey.includes("payment gateway") ||
      feeNameKey.includes("cash payment")
    ) {
      paymentFee += absNumber(amount);
    } else if (
      feeNameKey.includes("handling fee") ||
      feeNameKey.includes("order handling")
    ) {
      handlingFee += absNumber(amount);
    } else if (
      feeNameKey.includes("voucher") ||
      feeNameKey.includes("seller discount") ||
      feeNameKey.includes("subsidy")
    ) {
      cofundedVoucherFee += absNumber(amount);
    } else if (
      feeNameKey.includes("free shipping max") ||
      feeNameKey.includes("free shipping promotion") ||
      feeNameKey.includes("fsm")
    ) {
      freeShippingMaxFee += absNumber(amount);
    } else if (
      feeNameKey.includes("shipping fee") ||
      feeNameKey.includes("shipping charge") ||
      feeNameKey.includes("freight")
    ) {
      shippingFee += amount;
    } else if (feeNameKey.includes("coin")) {
      if (amount < 0) {
        coinsDiscountFee += absNumber(amount);
      } else {
        otherCredits += amount;
      }
    } else if (
      feeNameKey.includes("penalt") ||
      feeNameKey.includes("fine") ||
      feeNameKey.includes("fulfillment penalty") ||
      feeNameKey.includes("cancellation fee") ||
      feeNameKey.includes("lost & damaged")
    ) {
      if (isPenaltyReversal || amount > 0) {
        penaltiesRefunded += absNumber(amount);
        otherCredits += absNumber(amount);
      } else {
        penalties += absNumber(amount);
      }
    } else if (amount < 0) {
      otherFees += absNumber(amount);
    } else if (amount > 0) {
      otherCredits += amount;
    }
  }

  // Authoritative official Daraz net settlement = exact sum of all signed transaction rows
  const netSettlement = roundMoney(rawSignedSum);

  // Carrier shipping fee (negative deduction in statement) and Daraz subsidy credit
  const carrierCost = Math.abs(shippingFee);
  const discountCoverage = Math.abs(shippingFeeDiscount);

  // Gross credited to seller: product price + buyer-paid shipping + shipping discount subsidy + credits
  let finalGrossAmount = roundMoney(productPrice + shippingPaidByBuyer + discountCoverage + otherCredits);

  // Platform fees
  let totalFees = roundMoney(
    commissionFee +
    paymentFee +
    carrierCost +
    handlingFee +
    freeShippingMaxFee +
    cofundedVoucherFee +
    coinsDiscountFee +
    penalties +
    otherFees
  );

  const totalTaxes = roundMoney(incomeTaxWithholding + salesTaxWithholding + otherTaxes);
  let totalDeductions = roundMoney(totalFees + totalTaxes);

  // Exact balance reconciliation: ensure gross - deductions matches netSettlement with 0.00 drift
  if (finalGrossAmount > 0) {
    const drift = roundMoney(finalGrossAmount - totalDeductions - netSettlement);
    if (drift > 0) {
      otherFees = roundMoney(otherFees + drift);
      totalFees = roundMoney(totalFees + drift);
      totalDeductions = roundMoney(totalFees + totalTaxes);
    } else if (drift < 0) {
      otherCredits = roundMoney(otherCredits + Math.abs(drift));
      finalGrossAmount = roundMoney(finalGrossAmount + Math.abs(drift));
    }
  }

  const rawStatus = (first["Order Status"] || first["Status"] || first["Release Status"] || "").trim();
  const feeNamesText = Object.keys(feeBreakdown).join(" ").toLowerCase();
  const commentText = group.map((r) => ((r["Comment"] || r["Reason"] || "") + "").toLowerCase()).join(" ");

  const isReturnedOrCancelled =
    rawStatus.toLowerCase().includes("return") ||
    rawStatus.toLowerCase().includes("cancel") ||
    rawStatus.toLowerCase().includes("refund") ||
    feeNamesText.includes("return") ||
    commentText.includes("return") ||
    commentText.includes("refund");

  const isPenaltyCharged =
    penalties > 0 ||
    (netSettlement < 0 && (feeNamesText.includes("penalt") || feeNamesText.includes("fine") || commentText.includes("penalt")));

  const isPenaltyReturned =
    penaltiesRefunded > 0 ||
    (netSettlement > 0 && (feeNamesText.includes("reversal") || feeNamesText.includes("penalty return") || commentText.includes("reversal")));

  if (isPenaltyCharged && penalties === 0) {
    penalties = Math.abs(netSettlement);
  }

  let effectiveGross = finalGrossAmount;
  if (effectiveGross === 0 && netSettlement > 0) {
    effectiveGross = roundMoney(netSettlement + totalDeductions);
  }

  const finalStatus = isPenaltyCharged
    ? "Penalty Charged"
    : (isPenaltyReturned
        ? "Penalty Refunded"
        : (isReturnedOrCancelled
            ? (rawStatus.toLowerCase().includes("cancel") ? "Cancelled" : "Returned")
            : (rawStatus || "Delivered")));

  const quantity = (adjustmentMeta.entryType === "adjustment" || isPenaltyCharged) ? 0 : extractQuantity(group);

  let costDetails = {
    cost_price: 0,
    matched_product_id: null,
    matched_product_name: "",
    matched_by: "",
    profit_ready: false
  };

  if (adjustmentMeta.entryType === "order" && !isPenaltyCharged) {
    costDetails = await findCostDetails(group, defaultStore?._id || null, preloadedCache);
  }

  // If order was a penalty or returned/cancelled, inventory was returned to stock -> COGS = 0
  // If order was delivered, inventory was sold -> COGS = cost_price * quantity
  const totalCost =
    (adjustmentMeta.entryType === "order" && !isReturnedOrCancelled && !isPenaltyCharged && !isPenaltyReturned)
      ? roundMoney((costDetails.cost_price || 0) * quantity)
      : 0;

  const netProfit =
    (isReturnedOrCancelled || isPenaltyCharged || isPenaltyReturned)
      ? netSettlement
      : (adjustmentMeta.entryType === "order"
          ? (costDetails.profit_ready && quantity > 0
              ? roundMoney(netSettlement - totalCost)
              : null)
          : null);

  const profitReady =
    (isReturnedOrCancelled || isPenaltyCharged || isPenaltyReturned)
      ? true
      : (adjustmentMeta.entryType === "order" ? costDetails.profit_ready : false);

  const orderNum = extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number") ||
    (first["Order Number"] || first["Order No"] || first["Order ID"] || "").toString().trim();
  const orderLineId = extractEntryLineId(group) || entryLineId(first);
  const shortCode = extractFirstNonEmpty(group, "Short Code", "Seller Short Code", "short_code") ||
    first["Short Code"] || first["Seller Short Code"] || "";

  let sellerSku = extractFirstNonEmpty(group, "Seller SKU", "seller_sku");
  let lazadaSku = extractFirstNonEmpty(group, "Lazada SKU", "lazada_sku");
  let productName = extractFirstNonEmpty(group, "Product Name", "product_name");

  if ((!sellerSku || !productName) && orderNum) {
    try {
      const CentralOrderItem = require("../models/CentralOrderItem");
      const orderItem = await CentralOrderItem.findOne({
        $or: [{ order_number: orderNum }, { external_order_id: orderNum }]
      }).lean();
      if (orderItem) {
        if (!sellerSku) sellerSku = orderItem.sku || orderItem.seller_sku || "";
        if (!productName) productName = orderItem.name || orderItem.product_name || "";
      }
    } catch (_) {}
  }

  return {
    store_id: defaultStore?._id || null,
    store_name: defaultStore?.name || "",
    store_code: defaultStore?.code || shortCode,

    statement_period: extractFirstNonEmpty(group, "Statement Period", "statement_period") || first["Statement Period"] || "",
    statement_number: extractFirstNonEmpty(group, "Statement Number", "statement_number") || first["Statement Number"] || "",
    short_code: shortCode,

    transaction_date: extractFirstNonEmpty(group, "Transaction Date", "transaction_date") || first["Transaction Date"] || "",
    order_creation_date: extractFirstNonEmpty(group, "Order Creation Date", "order_creation_date") || first["Order Creation Date"] || "",
    release_status: extractFirstNonEmpty(group, "Release Status", "release_status") || first["Release Status"] || "",
    release_date: extractFirstNonEmpty(group, "Release Date", "release_date") || first["Release Date"] || "",

    order_number: orderNum,
    order_line_id: orderLineId,

    seller_sku: sellerSku,
    lazada_sku: lazadaSku,
    product_name: productName || costDetails.matched_product_name || "",
    order_status: finalStatus,

    entry_type: adjustmentMeta.entryType,
    adjustment_reason: isPenaltyCharged
      ? "Daraz Fine / Penalty Charged"
      : (isPenaltyReturned
          ? "Daraz Penalty Refund / Credit"
          : (isReturnedOrCancelled ? "Returned / Restocked" : adjustmentMeta.reason)),

    product_price: productPrice,
    shipping_paid_by_buyer: shippingPaidByBuyer,
    shipping_fee_discount: discountCoverage,

    commission_fee: commissionFee,
    payment_fee: paymentFee,
    shipping_fee: carrierCost,
    handling_fee: handlingFee,
    free_shipping_max_fee: freeShippingMaxFee,
    cofunded_voucher_fee: cofundedVoucherFee,
    coins_discount_fee: coinsDiscountFee,
    penalties: roundMoney(penalties + otherFees),
    penalties_refunded: roundMoney(penaltiesRefunded),
    is_penalty: isPenaltyCharged,
    is_penalty_refund: isPenaltyReturned,

    income_tax_withholding: incomeTaxWithholding,
    sales_tax_withholding: salesTaxWithholding + otherTaxes,
    wht_amount: whtAmount,
    vat_total: vatTotal,

    gross_amount: effectiveGross,
    total_fees: totalFees,
    total_taxes: totalTaxes,
    total_deductions: totalDeductions,
    net_settlement: netSettlement,

    cost_price: (isPenaltyCharged || isPenaltyReturned) ? 0 : Number(costDetails.cost_price || 0),
    quantity,
    total_cost: isReturnedOrCancelled ? 0 : totalCost,
    net_profit: isReturnedOrCancelled ? netSettlement : netProfit,

    matched_product_id:
      adjustmentMeta.entryType === "order" ? costDetails.matched_product_id : null,
    matched_product_name:
      adjustmentMeta.entryType === "order" ? costDetails.matched_product_name : "",
    cost_match_type: costDetails.matched_by || "none",
    matched_by: isReturnedOrCancelled ? "returned_restocked" : "file_imported",
    source: "statement_file",
    profit_ready: profitReady,
    is_estimate: false,

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

  let totalPenaltiesCharged = 0;
  let totalPenaltiesRefunded = 0;
  let estimatedEntries = 0;
  let estimatedNetSettlement = 0;

  for (const item of uniqueEntries) {
    grossAmount += Number(item.gross_amount) || 0;
    totalFees += Number(item.total_fees) || 0;
    totalTaxes += Number(item.total_taxes) || 0;
    totalDeductions += Number(item.total_deductions) || 0;
    netSettlement += Number(item.net_settlement) || 0;
    totalPenaltiesCharged += Number(item.penalties) || 0;
    totalPenaltiesRefunded += Number(item.penalties_refunded) || 0;
    if (item.source === "store_order_sync") {
      estimatedEntries += 1;
      estimatedNetSettlement += Number(item.net_settlement) || 0;
    }

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
    total_penalties_charged: Number(totalPenaltiesCharged.toFixed(2)),
    total_penalties_refunded: Number(totalPenaltiesRefunded.toFixed(2)),
    total_cost: Number(totalCost.toFixed(2)),
    net_settlement: Number(netSettlement.toFixed(2)),
    net_profit: Number(netProfit.toFixed(2)),
    adjustment_impact: Number(adjustmentImpact.toFixed(2)),
    final_profit_after_adjustments: Number(finalProfit.toFixed(2)),
    margin_percent: marginPercent,
    profit_ready_orders: profitReadyOrders,
    pending_cost_orders: pendingCostOrders,
    // Entries still computed from fee rules (no Daraz statement/API lines yet) - not exact
    estimated_entries: estimatedEntries,
    estimated_net_settlement: Number(estimatedNetSettlement.toFixed(2)),
    exact_net_settlement: Number((netSettlement - estimatedNetSettlement).toFixed(2))
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
    await autoMatchUncostedFinanceEntries();
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

    const entries = await FinanceEntry.find(query).select("-raw_rows -fee_breakdown").lean();
    const summary = buildSummary(entries);
    res.json(summary);
  } catch (error) {
    res.status(500).json({ message: "Error fetching finance summary", error: error.message });
  }
});

// 3. Finance Entries List

// Automatic generic healing of outdated estimated finance entries
let _autoHealRun = false;
async function autoHealFinanceEntries(force = false) {
  if (_autoHealRun && !force) return;
  _autoHealRun = true;

  try {
    const CentralOrderItem = require("../models/CentralOrderItem");
    const CentralOrder = require("../models/CentralOrder");

    // Heal any API estimated entries whose calculations do not match current engine
    const estimatedEntries = await FinanceEntry.find({ source: "store_order_sync" });
    if (estimatedEntries.length > 0) {
      const orderNums = [...new Set(estimatedEntries.map((e) => e.order_number).filter(Boolean))];
      const lineIds = [...new Set(estimatedEntries.map((e) => e.order_line_id).filter(Boolean))];

      const [itemsByLine, ordersByNum] = await Promise.all([
        CentralOrderItem.find({ external_order_item_id: { $in: lineIds } }).lean(),
        CentralOrder.find({ order_number: { $in: orderNums } }).lean()
      ]);

      const itemMap = new Map(itemsByLine.map((i) => [i.external_order_item_id, i]));
      const orderMap = new Map(ordersByNum.map((o) => [o.order_number, o]));

      for (const entry of estimatedEntries) {
        const item = itemMap.get(entry.order_line_id) || {
          unit_price: entry.product_price || 0,
          quantity: entry.quantity || 1,
          name: entry.product_name,
          seller_sku: entry.seller_sku,
          store_name: entry.store_name,
          store_code: entry.store_code
        };
        const parentOrder = orderMap.get(entry.order_number) || {};
        const calc = calculateDarazSettlementForOrderItem(item, parentOrder, entry);

        if (Math.abs((entry.net_settlement || 0) - calc.netSettlement) > 0.05) {
          const qty = entry.quantity > 0 ? entry.quantity : 1;
          const costPrice = entry.cost_price || 0;
          const totalCost = roundMoney(costPrice * qty);
          const netProfit = entry.profit_ready && costPrice > 0
            ? roundMoney(calc.netSettlement - totalCost)
            : entry.net_profit;

          await FinanceEntry.updateOne(
            { _id: entry._id },
            {
              $set: {
                product_price: calc.itemGross,
                shipping_paid_by_buyer: calc.buyerShipping,
                shipping_fee_discount: calc.shippingFeeDiscount,
                gross_amount: calc.grossAmount,
                commission_fee: calc.commissionFee,
                payment_fee: calc.paymentFee,
                handling_fee: calc.handlingFee,
                free_shipping_max_fee: calc.freeShippingMaxFee,
                cofunded_voucher_fee: calc.cofundedVoucherFee,
                coins_discount_fee: calc.coinsDiscountFee,
                shipping_fee: calc.carrierShipping,
                income_tax_withholding: calc.incomeTaxWithholding,
                sales_tax_withholding: calc.salesTaxWithholding,
                wht_amount: calc.incomeTaxWithholding,
                vat_total: calc.salesTaxWithholding,
                total_fees: calc.totalFees,
                total_taxes: calc.totalTaxes,
                total_deductions: calc.totalDeductions,
                net_settlement: calc.netSettlement,
                total_cost: totalCost,
                net_profit: netProfit,
                is_estimate: true,
                fee_breakdown: {
                  "Product Price Paid by Buyer": calc.itemGross,
                  ...(calc.buyerShipping > 0 ? { "Shipping Fee Paid by Buyer": calc.buyerShipping } : {}),
                  ...(calc.shippingFeeDiscount > 0 ? { "Shipping Fee Discount": calc.shippingFeeDiscount } : {}),
                  "Commission Fee": -calc.commissionFee,
                  "Payment Fee": -calc.paymentFee,
                  ...(calc.carrierShipping > 0 ? { "Shipping Fee": -calc.carrierShipping } : {}),
                  ...(calc.freeShippingMaxFee > 0 ? { "Free Shipping Max Fee": -calc.freeShippingMaxFee } : {}),
                  ...(calc.cofundedVoucherFee > 0 ? { "Co-funded Voucher Max": -calc.cofundedVoucherFee } : {}),
                  "Handling Fee": -calc.handlingFee,
                  ...(calc.coinsDiscountFee > 0 ? { "Daraz Coins Discount": -calc.coinsDiscountFee } : {}),
                  "Income Tax Withholding": -calc.incomeTaxWithholding,
                  ...(calc.salesTaxWithholding > 0 ? { "Sales Tax Withholding": -calc.salesTaxWithholding } : {})
                }
              }
            }
          );
        }
      }
    }

    // 2. Reconcile and heal orphaned order-level fees (such as Handling Fee) where product_price <= 0
    // but a main order entry exists for the same order_number
    const allOrderEntries = await FinanceEntry.find({
      entry_type: "order",
      product_price: { $gt: 0 },
      order_number: { $exists: true, $ne: "" }
    }).lean();

    if (allOrderEntries.length > 0) {
      const orderNums = [...new Set(allOrderEntries.map((e) => e.order_number).filter(Boolean))];
      const orphans = await FinanceEntry.find({
        order_number: { $in: orderNums },
        product_price: { $lte: 0 },
        net_settlement: { $lt: 0 }
      }).lean();

      if (orphans.length > 0) {
        const orphansByOrder = new Map();
        for (const orphan of orphans) {
          if (!orphansByOrder.has(orphan.order_number)) orphansByOrder.set(orphan.order_number, []);
          orphansByOrder.get(orphan.order_number).push(orphan);
        }

        const parentByOrder = new Map();
        for (const parent of allOrderEntries) {
          if (!parentByOrder.has(parent.order_number)) parentByOrder.set(parent.order_number, []);
          parentByOrder.get(parent.order_number).push(parent);
        }

        const orphanIdsToDelete = [];

        for (const [orderNum, orphanList] of orphansByOrder.entries()) {
          const parents = parentByOrder.get(orderNum);
          if (!parents || parents.length === 0) continue;

          for (const orphan of orphanList) {
            const orphanDeduction = Math.abs(orphan.net_settlement || 0);
            const orphanHandling = orphan.handling_fee > 0
              ? orphan.handling_fee
              : (String(orphan.adjustment_reason || "").toLowerCase().includes("handling") ? orphanDeduction : 0);
            const orphanRows = orphan.raw_rows || [];

            const totalParentPrice = parents.reduce((sum, p) => sum + (p.product_price || 0), 0);

            for (let i = 0; i < parents.length; i++) {
              const parent = parents[i];
              const ratio = parents.length === 1 || totalParentPrice <= 0 ? 1 : (parent.product_price || 0) / totalParentPrice;
              const partDeduction = roundMoney(orphanDeduction * ratio);
              const partHandling = roundMoney(orphanHandling * ratio);

              const newNet = roundMoney((parent.net_settlement || 0) - partDeduction);
              const newHandling = roundMoney((parent.handling_fee || 0) + partHandling);
              const newTotalFees = roundMoney((parent.total_fees || 0) + partDeduction);
              const newTotalDeductions = roundMoney((parent.total_deductions || 0) + partDeduction);

              const feeBreakdown = { ...(parent.fee_breakdown || {}) };
              if (partHandling > 0) {
                feeBreakdown["Handling Fee"] = roundMoney((feeBreakdown["Handling Fee"] || 0) - partHandling);
              } else {
                const feeKey = orphan.adjustment_reason || "Marketplace Fee";
                feeBreakdown[feeKey] = roundMoney((feeBreakdown[feeKey] || 0) - partDeduction);
              }

              const mergedRows = mergeStatementRows(parent.raw_rows || [], orphanRows);

              const updateDoc = {
                net_settlement: newNet,
                handling_fee: newHandling,
                total_fees: newTotalFees,
                total_deductions: newTotalDeductions,
                fee_breakdown: feeBreakdown,
                raw_rows: mergedRows
              };

              if (parent.profit_ready && parent.cost_price > 0) {
                updateDoc.net_profit = roundMoney(newNet - (parent.total_cost || 0));
              }

              await FinanceEntry.updateOne({ _id: parent._id }, { $set: updateDoc });
            }

            orphanIdsToDelete.push(orphan._id);
          }
        }

        if (orphanIdsToDelete.length > 0) {
          await FinanceEntry.deleteMany({ _id: { $in: orphanIdsToDelete } });
        }
      }
    }
  } catch (err) {
    // Non-blocking auto-heal notice
  }
}

// Automatically match uncosted finance orders against Central Inventory & Product catalog
async function autoMatchUncostedFinanceEntries(limit = 1000, forceAll = false) {
  try {
    const baseQuery = {
      entry_type: "order",
      is_penalty: { $ne: true },
      is_penalty_refund: { $ne: true }
    };

    // forceAll = re-examine every order entry regardless of profit_ready status
    // normal run = only entries that look uncosted or incomplete
    const uncostedEntries = await FinanceEntry.find(
      forceAll
        ? baseQuery
        : {
            ...baseQuery,
            $or: [
              { cost_price: { $not: { $gt: 0 } } }, // catches null, missing, 0, negative
              { profit_ready: { $ne: true } },
              { seller_sku: "" },
              { seller_sku: null },
              { product_name: "" },
              { product_name: null }
            ]
          }
    ).limit(limit);

    if (uncostedEntries.length === 0) return;

    const invItems = await CentralInventory.find({
      $or: [{ cost_price: { $gt: 0 } }, { purchase_price: { $gt: 0 } }]
    }).select("seller_sku store_id cost_price purchase_price product_name display_title original_product_name").lean();

    const productCatalog = await Product.find({ purchase_price: { $gt: 0 } }).select("sku purchase_price name").lean();

    const StockReceipt = require("../models/StockReceipt");
    const stockReceipts = await StockReceipt.find({ unit_cost: { $gt: 0 } })
      .select("seller_sku unit_cost product_name")
      .sort({ createdAt: -1 })
      .lean();

    const CentralOrderItem = require("../models/CentralOrderItem");
    const CentralOrder = require("../models/CentralOrder");

    for (const entry of uncostedEntries) {
      let currentSku = (entry.seller_sku || "").trim();
      let currentName = (entry.product_name || "").trim();
      let currentLazadaSku = (entry.lazada_sku || "").trim();

      // Recover missing SKU and Product Name from raw_rows or CentralOrderItem
      if ((!currentSku || !currentName) && Array.isArray(entry.raw_rows) && entry.raw_rows.length > 0) {
        for (const row of entry.raw_rows) {
          if (!currentSku) currentSku = (row["Seller SKU"] || row.seller_sku || "").toString().trim();
          if (!currentName) currentName = (row["Product Name"] || row.product_name || "").toString().trim();
          if (!currentLazadaSku) currentLazadaSku = (row["Lazada SKU"] || row.lazada_sku || "").toString().trim();
        }
      }

      if ((!currentSku || !currentName) && (entry.order_line_id || entry.order_number)) {
        try {
          let item = null;
          if (entry.order_line_id) {
            item = await CentralOrderItem.findOne({ external_order_item_id: entry.order_line_id }).lean();
          }
          if (!item && entry.order_number) {
            const parentOrder = await CentralOrder.findOne({
              $or: [{ order_number: entry.order_number }, { external_order_id: entry.order_number }]
            }).select("_id").lean();
            if (parentOrder) {
              item = await CentralOrderItem.findOne({ order_id: parentOrder._id }).lean();
            }
          }
          if (item) {
            if (!currentSku) currentSku = (item.seller_sku || "").toString().trim();
            if (!currentName) currentName = (item.product_name || item.display_title || item.original_product_name || "").toString().trim();
          }
        } catch (_) {}
      }

      const candidates = extractSkuCandidates(currentSku, currentLazadaSku);
      let matchedCost = 0;
      let matchedName = "";

      // Helper to check SKU matches (exact, alnum, or prefix)
      const matchesSku = (invSku) => {
        const invNorm = normAlnum(invSku);
        if (!invNorm) return false;
        if (candidates.some((c) => normAlnum(c) === invNorm)) return true;
        return candidates.some((c) => {
          const cn = normAlnum(c);
          return (cn.length >= 6 && invNorm.startsWith(cn)) || (invNorm.length >= 6 && cn.startsWith(invNorm));
        });
      };

      // 1. Check CentralInventory with storeId first by SKU
      if (entry.store_id) {
        const storeStr = String(entry.store_id);
        const match = invItems.find((inv) => {
          if (String(inv.store_id) !== storeStr) return false;
          return matchesSku(inv.seller_sku);
        });
        if (match) {
          matchedCost = match.cost_price > 0 ? match.cost_price : match.purchase_price;
          matchedName = match.product_name || match.display_title || currentName;
        }
      }

      // 2. Cross-store CentralInventory fallback by SKU
      if (matchedCost <= 0) {
        const match = invItems.find((inv) => matchesSku(inv.seller_sku));
        if (match) {
          matchedCost = match.cost_price > 0 ? match.cost_price : match.purchase_price;
          matchedName = match.product_name || match.display_title || currentName;
        }
      }

      // 3. Match CentralInventory by Product Name (fuzzy matching)
      if (matchedCost <= 0 && currentName) {
        let nameMatch = null;
        if (entry.store_id) {
          const storeStr = String(entry.store_id);
          nameMatch = invItems.find((inv) => {
            if (String(inv.store_id) !== storeStr) return false;
            const targetTitle = inv.product_name || inv.display_title || inv.original_product_name || "";
            return fuzzyMatchTitle(targetTitle, currentName);
          });
        }
        if (!nameMatch) {
          nameMatch = invItems.find((inv) => {
            const targetTitle = inv.product_name || inv.display_title || inv.original_product_name || "";
            return fuzzyMatchTitle(targetTitle, currentName);
          });
        }
        if (nameMatch) {
          matchedCost = nameMatch.cost_price > 0 ? nameMatch.cost_price : nameMatch.purchase_price;
          matchedName = nameMatch.product_name || nameMatch.display_title || currentName;
        }
      }

      // 4. Product Catalog fallback (by SKU or Name)
      if (matchedCost <= 0) {
        const prodMatch = productCatalog.find((p) => {
          const pNorm = normAlnum(p.sku);
          if (candidates.some((c) => normAlnum(c) === pNorm)) return true;
          if (currentName && (normAlnum(p.name) === normAlnum(currentName) || fuzzyMatchTitle(p.name, currentName))) return true;
          return false;
        });
        if (prodMatch) {
          matchedCost = prodMatch.purchase_price;
          matchedName = prodMatch.name || currentName;
        }
      }

      // 5. StockReceipt fallback (unit cost recorded on stock receipts)
      if (matchedCost <= 0 && stockReceipts.length > 0) {
        const receiptMatch = stockReceipts.find(
          (r) => matchesSku(r.seller_sku) || (currentName && fuzzyMatchTitle(r.product_name, currentName))
        );
        if (receiptMatch && receiptMatch.unit_cost > 0) {
          matchedCost = receiptMatch.unit_cost;
          matchedName = receiptMatch.product_name || currentName;
        }
      }

      const isReturn = /return|cancel/i.test(entry.order_status || "");
      const qty = entry.quantity > 0 ? entry.quantity : 1;

      if (matchedCost > 0) {
        const totalCost = isReturn ? 0 : Number((matchedCost * qty).toFixed(2));
        const netProfit = isReturn
          ? Number((entry.net_settlement || 0).toFixed(2))
          : Number(((entry.net_settlement || 0) - totalCost).toFixed(2));

        await FinanceEntry.updateOne(
          { _id: entry._id },
          {
            $set: {
              seller_sku: currentSku || entry.seller_sku,
              product_name: currentName || matchedName || entry.product_name,
              lazada_sku: currentLazadaSku || entry.lazada_sku,
              cost_price: matchedCost,
              total_cost: totalCost,
              net_profit: netProfit,
              profit_ready: true,
              matched_by: `auto_matched_central_inventory:${currentSku || currentName}`,
              matched_product_name: matchedName || currentName || entry.product_name
            }
          }
        );
      } else if (currentSku !== (entry.seller_sku || "") || currentName !== (entry.product_name || "")) {
        const updateDoc = {
          seller_sku: currentSku || entry.seller_sku,
          product_name: currentName || entry.product_name,
          lazada_sku: currentLazadaSku || entry.lazada_sku
        };
        if (isReturn) {
          updateDoc.profit_ready = true;
          updateDoc.total_cost = 0;
          updateDoc.net_profit = Number((entry.net_settlement || 0).toFixed(2));
        }
        await FinanceEntry.updateOne({ _id: entry._id }, { $set: updateDoc });
      } else if (isReturn && !entry.profit_ready) {
        await FinanceEntry.updateOne(
          { _id: entry._id },
          {
            $set: {
              profit_ready: true,
              total_cost: 0,
              net_profit: Number((entry.net_settlement || 0).toFixed(2))
            }
          }
        );
      }
    }
  } catch (err) {
    console.warn("[Finance] Non-blocking notice in autoMatchUncostedFinanceEntries:", err.message);
  }
}

router.get("/", async (req, res) => {
    if (!_autoHealRun) { await autoHealFinanceEntries(); }
    await autoMatchUncostedFinanceEntries();
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
      .select("-raw_rows")
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
    let { rows = [], file_base64 = "", store_id = "" } = req.body;

    if (file_base64) {
      const buffer = Buffer.from(file_base64, "base64");
      rows = parseDarazFileToRows(buffer);
    } else if (typeof rows === "string") {
      rows = parseDarazFileToRows(rows);
    }

    if (!Array.isArray(rows) || rows.length === 0) {
      return res.status(400).json({ message: "No valid rows found in file. Please ensure it is a valid Daraz statement." });
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

    const groupedRows = groupRowsByOrder(rows).map(tagRowFingerprints);
    const preparedEntries = [];

    // Lines for one order can arrive across several weekly statements: merge with lines already imported
    const lineIds = groupedRows.map((group) => extractEntryLineId(group));
    const orderNums = groupedRows.map((group) => extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number")).filter(Boolean);

    const existingFileEntries = await FinanceEntry.find({
      $or: [
        { order_line_id: { $in: lineIds } },
        { order_number: { $in: orderNums }, entry_type: "order" }
      ],
      source: "statement_file"
    }).select("order_number order_line_id raw_rows").lean();

    const existingRowsByLine = new Map();
    const existingByOrder = new Map();
    for (const item of existingFileEntries) {
      if (item.order_line_id) existingRowsByLine.set(item.order_line_id, item.raw_rows || []);
      if (item.order_number) {
        if (!existingByOrder.has(item.order_number)) existingByOrder.set(item.order_number, []);
        existingByOrder.get(item.order_number).push(item);
      }
    }

    for (const group of groupedRows) {
      const lineId = extractEntryLineId(group);
      const orderNum = extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number");
      const rawLineId = extractFirstNonEmpty(group, "Order Line ID", "Order Item ID", "Item ID", "order_line_id");

      let baseRows = existingRowsByLine.get(lineId);
      if (!baseRows && !rawLineId && orderNum) {
        const parents = existingByOrder.get(orderNum);
        if (parents && parents.length > 0) {
          baseRows = parents[0].raw_rows || [];
          for (const r of group) {
            r["Order Line ID"] = parents[0].order_line_id;
          }
        }
      }

      const mergedRows = mergeStatementRows(baseRows, group);
      const entry = await buildEntryFromGroup(mergedRows, defaultStore, preloadedCache);
      if (entry) {
        entry.raw_rows = mergedRows;
        preparedEntries.push(entry);
      }
    }

    // Fast bulk write
    if (preparedEntries.length > 0) {
      // Delete any old sync-estimated entries for orders that are now being imported from real CSV data
      const orderNumbers = [...new Set(preparedEntries.map(e => e.order_number).filter(Boolean))];
      if (orderNumbers.length > 0) {
        await FinanceEntry.deleteMany({
          order_number: { $in: orderNumbers },
          $or: [
            { source: { $ne: "statement_file" } },
            { statement_number: { $regex: /^STMT-/i } }
          ]
        });
      }

      const bulkOps = preparedEntries.map((entry) => ({
        updateOne: {
          filter: { order_line_id: entry.order_line_id },
          update: { $set: entry },
          upsert: true
        }
      }));
      await FinanceEntry.bulkWrite(bulkOps, { ordered: false });
      await autoMatchUncostedFinanceEntries();
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
    const { seller_sku, cost_price, product_name } = req.body;
    const cost = Math.max(0, toNumber(cost_price, 0));
    const sku = String(seller_sku || "").trim();
    const cleanName = String(product_name || "").trim();

    if ((!sku && !cleanName) || cost <= 0) {
      return res.status(400).json({ message: "A valid seller_sku or product_name, and cost_price are required." });
    }

    const skuCandidates = extractSkuCandidates(sku);
    const regexList = skuCandidates.map((s) => new RegExp(`^${escapeRegex(s)}$`, "i"));
    const orQueries = regexList.map((rgx) => ({ seller_sku: rgx }));
    regexList.forEach((rgx) => {
      orQueries.push({ lazada_sku: rgx });
    });

    // Prefix matching for base ID (e.g. 923171376 matching 923171376-1782364893283-0)
    const baseId = sku.split(/[-_\s]/)[0]?.trim();
    if (baseId && baseId.length >= 6) {
      orQueries.push({ seller_sku: new RegExp(`^${escapeRegex(baseId)}([-_\\s]|$)`, 'i') });
      orQueries.push({ lazada_sku: new RegExp(`^${escapeRegex(baseId)}([-_\\s]|$)`, 'i') });
    }

    if (cleanName && cleanName.length >= 4) {
      orQueries.push({ product_name: new RegExp(`^${escapeRegex(cleanName)}$`, 'i') });
      orQueries.push({ product_name: new RegExp(escapeRegex(cleanName), 'i') });
      orQueries.push({ display_title: new RegExp(escapeRegex(cleanName), 'i') });
      const baseTitle = cleanName.split(/[-–—|,(]/)[0]?.trim();
      if (baseTitle && baseTitle.length >= 6 && baseTitle !== cleanName) {
        orQueries.push({ product_name: new RegExp(escapeRegex(baseTitle), 'i') });
        orQueries.push({ display_title: new RegExp(escapeRegex(baseTitle), 'i') });
      }
    }

    // 1. Update Central Inventory
    await CentralInventory.updateMany(
      { $or: orQueries },
      { $set: { cost_price: cost, purchase_price: cost } }
    );

    // 2. Update Product Catalog
    const prodOr = regexList.map((rgx) => ({ sku: rgx }));
    if (cleanName && cleanName.length >= 4) {
      prodOr.push({ name: new RegExp(`^${escapeRegex(cleanName)}$`, 'i') });
    }
    if (prodOr.length > 0) {
      await Product.updateMany({ $or: prodOr }, { $set: { purchase_price: cost } });
    }

    // 3. Update CentralOrderItem
    const CentralOrderItem = require("../models/CentralOrderItem");
    const orderItems = await CentralOrderItem.find({ $or: orQueries });
    for (const orderItem of orderItems) {
      const itemUnitPrice = toNumber(orderItem.unit_price, 0);
      const itemQty = toNumber(orderItem.quantity, 1);
      const itemRev = itemUnitPrice * itemQty;
      const itemCost = cost * itemQty;
      orderItem.cost_price = cost;
      orderItem.profit = itemRev - itemCost;
      orderItem.profit_margin = itemRev > 0 ? Number((((itemRev - itemCost) / itemRev) * 100).toFixed(2)) : 0;
      orderItem.profit_ready = true;
      await orderItem.save();
    }

    // 4. Batch Recalculate Finance Entries matching this SKU
    const matchingEntries = await FinanceEntry.find({
      $or: orQueries,
      entry_type: "order"
    });

    let recalculated = 0;
    for (const entry of matchingEntries) {
      if (entry.is_penalty || entry.is_penalty_refund) continue;
      const isReturn = /return|cancel/i.test(entry.order_status || "");
      const qty = entry.quantity > 0 ? entry.quantity : 1;
      const totalCost = isReturn ? 0 : Number((cost * qty).toFixed(2));
      const netProfit = isReturn
        ? Number((entry.net_settlement || 0).toFixed(2))
        : Number(((entry.net_settlement || 0) - totalCost).toFixed(2));

      entry.cost_price = cost;
      entry.total_cost = totalCost;
      entry.net_profit = netProfit;
      entry.profit_ready = true;
      entry.matched_by = `user_override:${sku || cleanName}`;
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

// 6a. Force Rematch All Orders (re-apply stock costs to all existing finance entries)
router.post("/rematch-all", async (req, res) => {
  try {
    // Reset profit_ready=false for ALL order entries so they get re-examined
    const resetResult = await FinanceEntry.updateMany(
      {
        entry_type: "order",
        is_penalty: { $ne: true },
        is_penalty_refund: { $ne: true }
      },
      { $set: { profit_ready: false } }
    );

    // Now run the full auto-match sweep in forceAll mode
    await autoMatchUncostedFinanceEntries(5000, true);

    // Count how many are now costed
    const costedCount = await FinanceEntry.countDocuments({ entry_type: "order", profit_ready: true });
    const totalCount = await FinanceEntry.countDocuments({ entry_type: "order" });

    res.json({
      success: true,
      message: `Rematch complete. ${costedCount} of ${totalCount} orders now have purchase cost matched.`,
      costed: costedCount,
      total: totalCount
    });
  } catch (error) {
    res.status(500).json({ message: "Error during rematch-all", error: error.message });
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

// Helper to calculate estimated Daraz settlement for an order item (when official statement is not yet released)
function calculateDarazSettlementForOrderItem(item, parentOrder = {}, store = null) {
  const raw = item.raw_payload || {};

  // 1. Base Item Price
  const itemPrice = Number(raw.item_price) || Number(item.item_price) || Number(item.unit_price) || 0;
  const sellerVoucher = Number(raw.voucher_seller) || Number(raw.seller_discount) || 0;
  let sellerBasePrice = 0;
  if (itemPrice > 0) {
    sellerBasePrice = Math.max(0, itemPrice - sellerVoucher);
  } else {
    const paidPrice = Number(raw.paid_price) || Number(item.paid_price) || Number(item.unit_price) || 0;
    const platformVoucher = Number(raw.voucher_platform) || Number(raw.daraz_discount) || 0;
    sellerBasePrice = paidPrice + platformVoucher;
  }
  if (sellerBasePrice <= 0) {
    sellerBasePrice = Number(item.unit_price) || Number(item.paid_price) || Number(item.product_price) || 0;
  }

  const qty = Number(item.quantity) || 1;
  const itemGross = roundMoney(sellerBasePrice * qty);

  // Store identity & FSM enrollment check
  const storeName = (store?.name || store?.store_name || item.store_name || parentOrder.store_name || parentOrder.seller_name || "").toString();
  const storeCode = (store?.code || store?.store_code || item.store_code || parentOrder.store_code || "").toString();
  const isFsm = isStoreEnrolledInFSM(store, storeName, storeCode);

  // Category identification & Commission Rule
  const titleText = (item.name || item.product_name || item.display_title || raw.product_name || raw.name || raw.title || item.seller_sku || "").toString();
  const categoryRule = resolveCategoryRule(titleText);

  // 1. Commission Fee
  const commissionFee = roundMoney(itemGross * categoryRule.effectiveRate);

  // 2. Payment Fee (2.25% base + 15% PST = 2.5875%)
  const paymentFee = roundMoney(itemGross * 0.025875);

  // 3. Handling Fee (Strict Dynamic Tiers: <1000 => 17.40, 1000-1999 => 23.00, >=2000 => 69.00)
  const handlingFee = getDarazHandlingFee(itemGross);

  // 4. Free Shipping Max (FSM) Fee: ~6.9002% on gross for FSM enrolled stores; 0.00 for non-FSM stores
  const freeShippingMaxFee = isFsm ? roundMoney(itemGross * 0.069002) : 0.00;

  // 5. Shipping calculations
  const carrierShipping = Number(raw.carrier_shipping_fee) || 230.00;
  let buyerShipping = 0;
  let shippingFeeDiscount = 0;

  if (raw.shipping_paid_by_buyer !== undefined) {
    buyerShipping = Number(raw.shipping_paid_by_buyer) || 0;
  } else if (raw.shipping_fee !== undefined) {
    buyerShipping = Number(raw.shipping_fee) || 0;
  } else if (item.shipping_paid_by_buyer !== undefined && item.shipping_paid_by_buyer > 0) {
    buyerShipping = Number(item.shipping_paid_by_buyer);
  } else {
    buyerShipping = isFsm ? 49.00 : 200.00;
  }

  if (raw.shipping_fee_discount !== undefined && Number(raw.shipping_fee_discount) > 0) {
    shippingFeeDiscount = Number(raw.shipping_fee_discount);
  } else if (isFsm && buyerShipping < 100) {
    // Under FSM, Daraz subsidizes the carrier shipping difference when buyer receives promotional shipping (~49 PKR)
    shippingFeeDiscount = Math.max(0, roundMoney(carrierShipping - buyerShipping - 7.35));
  } else {
    shippingFeeDiscount = 0.00;
  }

  const grossAmount = roundMoney(itemGross + buyerShipping + shippingFeeDiscount);

  // 6. Co-funded Voucher Fee (3% for participating stores on orders >= 1000)
  const hasCofunded = raw.cofunded_voucher !== undefined
    ? Boolean(raw.cofunded_voucher)
    : (isFsm && itemGross >= 1000);
  const cofundedVoucherFee = hasCofunded ? roundMoney(itemGross * 0.0300) : 0.00;

  // 7. Daraz Coins Discount Fee
  let coinsDiscountFee = 0.00;
  if (raw.coins !== undefined || raw.coin_discount !== undefined) {
    coinsDiscountFee = roundMoney(Number(raw.coin_discount || raw.coins || 0));
  } else if (itemGross >= 1000) {
    coinsDiscountFee = 9.20;
  } else if (itemGross >= 800) {
    coinsDiscountFee = 9.28;
  }

  // 8. Section 236V Income Tax Withholding & Sales Tax Withholding
  let incomeTaxWithholding = 0.00;
  let salesTaxWithholding = 0.00;
  if (!categoryRule.whtExempt && itemGross >= 1000) {
    const whtRate = raw.wht_rate !== undefined ? Number(raw.wht_rate) : (raw.is_active_filer ? 0.01 : 0.02);
    incomeTaxWithholding = roundMoney(itemGross * whtRate);
    salesTaxWithholding = roundMoney(itemGross * 0.02);
  }

  const totalFees = roundMoney(commissionFee + paymentFee + handlingFee + carrierShipping + coinsDiscountFee + freeShippingMaxFee + cofundedVoucherFee);
  const totalTaxes = roundMoney(incomeTaxWithholding + salesTaxWithholding);
  const totalDeductions = roundMoney(totalFees + totalTaxes);
  const netSettlement = Math.max(0, roundMoney(grossAmount - totalDeductions));

  return {
    is_estimate: true,
    itemGross,
    buyerShipping,
    shippingFeeDiscount,
    carrierShipping,
    grossAmount,
    commissionFee,
    paymentFee,
    freeShippingMaxFee,
    cofundedVoucherFee,
    handlingFee,
    coinsDiscountFee,
    incomeTaxWithholding,
    salesTaxWithholding,
    totalFees,
    totalTaxes,
    totalDeductions,
    netSettlement
  };
}

// 6b. Recalculate Finance Entries (respecting statement precedence)
router.post("/recalculate", async (req, res) => {
  try {
    const { statement_period } = req.body;
    const query = { entry_type: "order" };
    if (statement_period && statement_period !== "all") {
      query.statement_period = { $regex: new RegExp(`^${escapeRegex(statement_period.trim())}$`, "i") };
    }

    const CentralOrderItem = require("../models/CentralOrderItem");
    const CentralOrder = require("../models/CentralOrder");
    const entries = await FinanceEntry.find(query);
    let updated = 0;

    for (const entry of entries) {
      // Anything built from official Daraz lines (file or live API) is never re-estimated
      const isFileImported =
        entry.source === "statement_file" ||
        entry.source === "live_api_transaction" ||
        entry.matched_by === "file_imported";

      // PRECEDENCE RULE: If imported from an official statement file, DO NOT recalculate or override official Daraz fees!
      // Only recalculate totalCost and netProfit if product cost changed.
      if (isFileImported) {
        const isReturn = /return|cancel/i.test(entry.order_status || "");
        const qty = entry.quantity > 0 ? entry.quantity : 1;
        const costPrice = entry.cost_price || 0;
        const totalCost = isReturn ? 0 : roundMoney(costPrice * qty);
        // Returns / penalties carry no COGS and already store net_profit = net_settlement; keep it
        const netProfit = isReturn
          ? entry.net_settlement
          : (entry.profit_ready && costPrice > 0
              ? roundMoney(entry.net_settlement - totalCost)
              : entry.net_profit);

        await FinanceEntry.updateOne(
          { _id: entry._id },
          {
            $set: {
              total_cost: totalCost,
              net_profit: netProfit
            }
          }
        );
        updated += 1;
        continue;
      }

      // For API estimated orders (source: "store_order_sync"):
      let orderItem = null;
      if (entry.order_line_id) {
        orderItem = await CentralOrderItem.findOne({ external_order_item_id: entry.order_line_id }).lean();
      }
      if (!orderItem && entry.order_number) {
        orderItem = await CentralOrderItem.findOne({ order_number: entry.order_number }).lean();
      }

      let parentOrder = {};
      if (orderItem?.order_id) {
        parentOrder = (await CentralOrder.findById(orderItem.order_id).lean()) || {};
      }

      const itemRef = orderItem || {
        unit_price: entry.product_price || entry.gross_amount || 0,
        quantity: entry.quantity || 1,
        name: entry.product_name || "",
        seller_sku: entry.seller_sku || "",
        shipping_paid_by_buyer: entry.shipping_paid_by_buyer || 0,
        store_name: entry.store_name || "",
        store_code: entry.store_code || ""
      };

      const calc = calculateDarazSettlementForOrderItem(itemRef, parentOrder, entry);
      const isReturn = /return|cancel/i.test(entry.order_status || "");
      const qty = entry.quantity > 0 ? entry.quantity : 1;
      const costPrice = entry.cost_price || 0;
      const totalCost = isReturn ? 0 : roundMoney(costPrice * qty);
      const netProfit = isReturn
        ? calc.netSettlement
        : (entry.profit_ready && costPrice > 0
            ? roundMoney(calc.netSettlement - totalCost)
            : null);

      await FinanceEntry.updateOne(
        { _id: entry._id },
        {
          $set: {
            product_price: calc.itemGross,
            shipping_paid_by_buyer: calc.buyerShipping,
            shipping_fee_discount: calc.shippingFeeDiscount,
            gross_amount: calc.grossAmount,
            commission_fee: calc.commissionFee,
            payment_fee: calc.paymentFee,
            handling_fee: calc.handlingFee,
            cofunded_voucher_fee: calc.cofundedVoucherFee,
            free_shipping_max_fee: calc.freeShippingMaxFee,
            coins_discount_fee: calc.coinsDiscountFee,
            shipping_fee: calc.carrierShipping,
            income_tax_withholding: calc.incomeTaxWithholding,
            sales_tax_withholding: calc.salesTaxWithholding,
            wht_amount: calc.incomeTaxWithholding,
            vat_total: calc.salesTaxWithholding,
            total_fees: calc.totalFees,
            total_taxes: calc.totalTaxes,
            total_deductions: calc.totalDeductions,
            net_settlement: calc.netSettlement,
            total_cost: totalCost,
            net_profit: netProfit,
            is_estimate: true,
            fee_breakdown: {
              "Product Price Paid by Buyer": calc.itemGross,
              ...(calc.buyerShipping > 0 ? { "Shipping Fee Paid by Buyer": calc.buyerShipping } : {}),
              ...(calc.shippingFeeDiscount > 0 ? { "Shipping Fee Discount": calc.shippingFeeDiscount } : {}),
              "Commission Fee": -calc.commissionFee,
              "Payment Fee": -calc.paymentFee,
              ...(calc.carrierShipping > 0 ? { "Shipping Fee": -calc.carrierShipping } : {}),
              ...(calc.freeShippingMaxFee > 0 ? { "Free Shipping Max Fee": -calc.freeShippingMaxFee } : {}),
              ...(calc.cofundedVoucherFee > 0 ? { "Co-funded Voucher Max": -calc.cofundedVoucherFee } : {}),
              "Handling Fee": -calc.handlingFee,
              ...(calc.coinsDiscountFee > 0 ? { "Daraz Coins Discount": -calc.coinsDiscountFee } : {}),
              "Income Tax Withholding": -calc.incomeTaxWithholding,
              ...(calc.salesTaxWithholding > 0 ? { "Sales Tax Withholding": -calc.salesTaxWithholding } : {})
            }
          }
        }
      );
      updated += 1;
    }

    res.json({
      success: true,
      message: `Recalculated ${updated} finance order record(s).`,
      updated_count: updated
    });
  } catch (error) {
    res.status(500).json({ message: "Error recalculating finance entries", error: error.message });
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
        const tokenReady = await ensureStoreTokenReadyForSync(store._id);
        storeToken = tokenReady?.ok ? tokenReady.token : null;
      } catch (err) {
        storeToken = await StoreToken.findOne({ store_id: store._id });
      }

      let storeImported = 0;

      // 1. Live Daraz Open Platform Transaction Details API (official per-line amounts, all pages)
      if (storeToken?.access_token && dateRange) {
        try {
          const startTimeStr = dateRange.startDate.toISOString().split("T")[0];
          const endTimeStr = dateRange.endDate.toISOString().split("T")[0];
          const pick = (tx, keys) => {
            for (const key of keys) {
              if (tx[key] !== undefined && tx[key] !== null && String(tx[key]).trim() !== "") return tx[key];
            }
            return "";
          };

          const transactions = [];
          const pageSize = 500;
          // ponytail: 40-page cap (20k lines/week/store); raise if a store exceeds it
          for (let page = 0, offset = 0; page < 40; page += 1, offset += pageSize) {
            const txRes = await getTransactionDetails({
              storeToken,
              startTime: startTimeStr,
              endTime: endTimeStr,
              offset,
              limit: pageSize
            });
            transactions.push(...(txRes.transactions || []));
            if (!txRes.hasMore) break;
          }

          const normalizedRows = transactions.map((tx) => {
            const orderNum = String(pick(tx, ["order_no", "order_number", "orderNumber", "trade_order_id"])).trim();
            const rawLineId = String(pick(tx, ["orderItem_no", "order_item_no", "order_line_id", "orderLineId", "order_item_id"])).trim();
            return {
              "Statement Period": period,
              "Statement Number": pick(tx, ["statement", "statement_number", "statementNumber"]) || `STMT-${store.code || store.name}-${period.replace(/\s+/g, "_")}`,
              "Transaction Number": pick(tx, ["transaction_number", "transactionNumber", "transaction_id"]),
              "Transaction Date": pick(tx, ["transaction_date", "transactionDate"]),
              "Release Status": pick(tx, ["paid_status", "paidStatus"]),
              "Order Status": pick(tx, ["orderItem_status", "order_item_status"]),
              "Order Number": orderNum,
              "Order Line ID": rawLineId,
              "Seller SKU": pick(tx, ["seller_sku", "sellerSku"]),
              "Lazada SKU": pick(tx, ["lazada_sku", "lazadaSku"]),
              "Product Name": pick(tx, ["details", "product_name", "productName", "item_name"]),
              "Fee Name": pick(tx, ["fee_name", "feeName", "transaction_type"]),
              "Amount(Include Tax)": pick(tx, ["amount"]) || 0,
              "VAT Amount": pick(tx, ["VAT_in_amount", "vat_in_amount", "vat_amount", "vatAmount"]) || 0,
              "WHT Amount": pick(tx, ["WHT_amount", "wht_amount", "whtAmount"]) || 0,
              "Comment": pick(tx, ["comment", "reason"]),
              "Quantity": pick(tx, ["quantity"]) || 1
            };
          }).filter((r) => r["Order Number"] || r["Order Line ID"] || r["Fee Name"]);

          const groups = groupRowsByOrder(normalizedRows).map(tagRowFingerprints);
          const lineIds = groups.map((group) => extractEntryLineId(group));
          const orderNums = groups.map((group) => extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number")).filter(Boolean);

          const existing = await FinanceEntry.find({
            $or: [
              { order_line_id: { $in: lineIds } },
              { order_number: { $in: orderNums }, entry_type: "order" }
            ]
          }).select("order_number order_line_id source raw_rows").lean();

          const existingByLine = new Map();
          const existingByOrder = new Map();
          for (const item of existing) {
            if (item.order_line_id) existingByLine.set(item.order_line_id, item);
            if (item.order_number) {
              if (!existingByOrder.has(item.order_number)) existingByOrder.set(item.order_number, []);
              existingByOrder.get(item.order_number).push(item);
            }
          }

          const entries = [];
          for (const group of groups) {
            const lineId = extractEntryLineId(group);
            const orderNum = extractFirstNonEmpty(group, "Order Number", "Order No", "Order ID", "order_number");
            const rawLineId = extractFirstNonEmpty(group, "Order Line ID", "Order Item ID", "Item ID", "order_line_id");
            const prior = existingByLine.get(lineId);

            // An imported statement file is authoritative for its lines; never mix API lines into it
            if (prior?.source === "statement_file") continue;

            // If this is an order-level fee group (no item line ID) but a prior item for this order exists in DB:
            if (!rawLineId && orderNum && !prior) {
              const existingParents = existingByOrder.get(orderNum);
              if (existingParents && existingParents.length > 0) {
                const targetParent = existingParents[0];
                if (targetParent.source !== "statement_file") {
                  const mergedRows = mergeStatementRows(targetParent.raw_rows || [], group);
                  const updatedEntry = await buildEntryFromGroup(mergedRows, store, preloadedCache);
                  if (updatedEntry) {
                    updatedEntry.statement_period = period;
                    updatedEntry.source = targetParent.source || "live_api_transaction";
                    updatedEntry.raw_rows = mergedRows;
                    entries.push(updatedEntry);
                  }
                  continue;
                }
              }
            }

            const mergedRows = mergeStatementRows(prior?.source === "live_api_transaction" ? prior.raw_rows : [], group);
            const entry = await buildEntryFromGroup(mergedRows, store, preloadedCache);
            if (entry) {
              entry.statement_period = period;
              entry.source = "live_api_transaction";
              entry.raw_rows = mergedRows;
              entries.push(entry);
              if (entry.entry_type === "order") totalImportedOrders++;
              else totalImportedAdjustments++;
              storeImported++;
            }
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
            await autoMatchUncostedFinanceEntries();
          }
        } catch (apiErr) {
          console.warn(`[FinanceSync] Live transaction notice for ${store.name}: ${apiErr.message}`);
        }
      }

      // 2. Fallback to Store Orders (Delivered/Shipped orders for this weekly period)
      // NOTE: Daraz fees vary per order/category/promotion - only the actual CSV statement has real numbers.
      // This fallback records orders WITHOUT fee calculations. Import CSV for accurate profit.
      if (storeImported === 0 && dateRange) {
        try {
          const CentralOrder = require("../models/CentralOrder");
          const CentralOrderItem = require("../models/CentralOrderItem");

          // Only delivered or returned orders in the statement period belong to the statement cycle
          const orderQuery = {
            store_id: store._id,
            status: { $in: ["delivered", "Delivered", "returned", "Returned"] },
            $or: [
              { order_created_at: { $gte: dateRange.startDate, $lte: dateRange.endDate } },
              { order_updated_at: { $gte: dateRange.startDate, $lte: dateRange.endDate } }
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

              const itemStatus = (item.status || parentOrder.status || "").toLowerCase();
              if (!itemStatus.includes("delivered") && !itemStatus.includes("return")) continue;

              // Skip if official Daraz lines (statement file or live Finance API) already exist for this order
              const existingCsvEntry = await FinanceEntry.findOne({
                order_number: orderNum,
                source: { $in: ["statement_file", "live_api_transaction"] }
              }).lean();
              if (existingCsvEntry) continue;

              // Use exact real-world Daraz settlement calculation
              const calc = calculateDarazSettlementForOrderItem(item, parentOrder, store);
              const qty = Number(item.quantity) || 1;

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
                product_price: calc.itemGross,
                shipping_paid_by_buyer: calc.buyerShipping,
                gross_amount: calc.grossAmount,
                commission_fee: calc.commissionFee,
                payment_fee: calc.paymentFee,
                handling_fee: calc.handlingFee,
                cofunded_voucher_fee: calc.cofundedVoucherFee,
                free_shipping_max_fee: calc.freeShippingMaxFee,
                shipping_fee: calc.carrierShipping,
                coins_discount_fee: calc.coinsDiscountFee,
                income_tax_withholding: calc.incomeTaxWithholding,
                sales_tax_withholding: calc.salesTaxWithholding,
                wht_amount: calc.incomeTaxWithholding,
                vat_total: calc.salesTaxWithholding,
                total_fees: calc.totalFees,
                total_taxes: calc.totalTaxes,
                total_deductions: calc.totalDeductions,
                net_settlement: calc.netSettlement,
                cost_price: costPrice,
                quantity: qty,
                total_cost: totalCost,
                net_profit: costPrice > 0 ? Number((calc.netSettlement - totalCost).toFixed(2)) : null,
                matched_product_id: costDetails.matched_product_id,
                matched_product_name: costDetails.matched_product_name || item.product_name,
                matched_by: "store_order_sync",
                source: "store_order_sync",
                cost_match_type: costDetails.matched_by || "none",
                profit_ready: costPrice > 0,
                fee_breakdown: {
                  "Product Price Paid by Buyer": calc.itemGross,
                  ...(calc.buyerShipping > 0 ? { "Shipping Fee Paid by Buyer": calc.buyerShipping } : {}),
                  "Commission Fee": -calc.commissionFee,
                  "Payment Fee": -calc.paymentFee,
                  ...(calc.carrierShipping > 0 ? { "Shipping Fee": -calc.carrierShipping } : {}),
                  ...(calc.freeShippingMaxFee > 0 ? { "Free Shipping Max Fee": -calc.freeShippingMaxFee } : {}),
                  ...(calc.cofundedVoucherFee > 0 ? { "Co-funded Voucher Max": -calc.cofundedVoucherFee } : {}),
                  "Handling Fee": -calc.handlingFee,
                  ...(calc.coinsDiscountFee > 0 ? { "Daraz Coins Discount Participation Fee": -calc.coinsDiscountFee } : {}),
                  "Income Tax Withholding": -calc.incomeTaxWithholding,
                  "Sales Tax Withholding": -calc.salesTaxWithholding
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
      ? `Successfully synchronized ${totalImportedOrders} order(s) for "${period}".`
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
module.exports.autoMatchUncostedFinanceEntries = autoMatchUncostedFinanceEntries;
module.exports.findCostDetails = findCostDetails;
module.exports.roundMoney = roundMoney;
module.exports.getDarazHandlingFee = getDarazHandlingFee;
module.exports.resolveCategoryRule = resolveCategoryRule;
module.exports.isStoreEnrolledInFSM = isStoreEnrolledInFSM;
module.exports.buildEntryFromGroup = buildEntryFromGroup;
module.exports.calculateDarazSettlementForOrderItem = calculateDarazSettlementForOrderItem;
module.exports.DARAZ_CATEGORY_RULES = DARAZ_CATEGORY_RULES;
module.exports.parseDarazFileToRows = parseDarazFileToRows;
module.exports.tagRowFingerprints = tagRowFingerprints;
module.exports.mergeStatementRows = mergeStatementRows;
module.exports.groupRowsByOrder = groupRowsByOrder;
module.exports.buildSummary = buildSummary;
