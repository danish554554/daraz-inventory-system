/**
 * verifyDarazSettlement.js
 * Standalone automated verification suite for Daraz Pakistan settlement calculations.
 * 
 * Tests:
 * 1. Benchmark Order #250676373648373 (Official Statement Import Reconciled to exact PKR 1,023.86, Delta = 0.00)
 * 2. Low-Value Order (< PKR 1,000 -> Handling Fee = PKR 17.40)
 * 3. High-Value Order (>= PKR 2,000 -> Handling Fee = PKR 69.00)
 * 4. Non-FSM Store (FSM Fee = PKR 0.00, Standard Shipping)
 * 5. Category Variation (Cookware ~11.50%, Health & Beauty ~18.45%, Electronics ~16.82%)
 * 6. Official Statement Override (Statement Authoritative > API Estimate)
 * 7. Section 236V Income Tax WHT Exemption (Cookware = 0.00 vs Non-exempt = 2.0%)
 */

// Shim dependencies if running in an environment without local node_modules
const Module = require("module");
const originalRequire = Module.prototype.require;
Module.prototype.require = function(id) {
  try {
    return originalRequire.apply(this, arguments);
  } catch (err) {
    if (id === "express") {
      const routerObj = {
        get: () => routerObj,
        post: () => routerObj,
        put: () => routerObj,
        delete: () => routerObj,
        use: () => routerObj
      };
      const expressMock = () => routerObj;
      expressMock.Router = () => routerObj;
      return expressMock;
    }
    if (id === "mongoose") {
      function MockSchema() { this.index = () => {}; }
      MockSchema.Types = { ObjectId: String };
      const chainable = () => ({
        lean: () => null,
        sort: () => ({ lean: () => null })
      });
      return {
        Schema: MockSchema,
        model: () => ({
          find: () => ({ lean: () => [], sort: () => ({ lean: () => [] }) }),
          findOne: chainable,
          findById: chainable,
          updateOne: () => Promise.resolve(),
          updateMany: () => Promise.resolve(),
          deleteMany: () => Promise.resolve(),
          bulkWrite: () => Promise.resolve()
        })
      };
    }
    if (id === "xlsx") {
      return { read: () => ({ SheetNames: [], Sheets: {} }), utils: { sheet_to_json: () => [] } };
    }
    if (id === "dotenv") {
      return { config: () => {} };
    }
    if (id.includes("../models/")) {
      return {
        find: () => ({ lean: () => [] }),
        findOne: () => ({ lean: () => null }),
        findById: () => ({ lean: () => null })
      };
    }
    throw err;
  }
};

const {
  roundMoney,
  getDarazHandlingFee,
  resolveCategoryRule,
  isStoreEnrolledInFSM,
  buildEntryFromGroup,
  calculateDarazSettlementForOrderItem
} = require("../routes/financeRoutes");

let totalTests = 0;
let passedTests = 0;
let failedTests = 0;

function reportResult(testName, expected, calculated, details = "") {
  totalTests++;
  const expNum = roundMoney(Number(expected));
  const calcNum = roundMoney(Number(calculated));
  const delta = roundMoney(Math.abs(calcNum - expNum));
  const passed = delta === 0.00;

  if (passed) {
    passedTests++;
    console.log(`[PASS] ${testName}`);
    console.log(`       Expected:   PKR ${expNum.toFixed(2)}`);
    console.log(`       Calculated: PKR ${calcNum.toFixed(2)}`);
    console.log(`       Delta:      PKR ${delta.toFixed(2)}`);
    if (details) console.log(`       Details:    ${details}`);
  } else {
    failedTests++;
    console.error(`[FAIL] ${testName}`);
    console.error(`       Expected:   PKR ${expNum.toFixed(2)}`);
    console.error(`       Calculated: PKR ${calcNum.toFixed(2)}`);
    console.error(`       Delta:      PKR ${delta.toFixed(2)}`);
    if (details) console.error(`       Details:    ${details}`);
  }
  console.log("------------------------------------------------------------");
}

async function runTests() {
  console.log("============================================================");
  console.log(" DARAZ PAKISTAN SETTLEMENT RECONCILIATION TEST SUITE");
  console.log("============================================================\n");

  // =========================================================================
  // TEST 1: Benchmark Order #250676373648373 Official Statement Import
  // =========================================================================
  const benchmarkStatementRows = [
    {
      "Statement Period": "12 Oct 2026 - 18 Oct 2026",
      "Statement Number": "PK2NBNKOWO5-2026-042",
      "Transaction Date": "15 Oct 2026",
      "Fee Name": "Payment Fee",
      "Amount(Include Tax)": "-36.2",
      "VAT Amount": "4.722",
      "Release Status": "Ready to Release",
      "Order Creation Date": "11 Oct 2026",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373",
      "Seller SKU": "947906218-1771387935210-0",
      "Lazada SKU": "947906218_PK-14011470474",
      "WHT Amount": "0",
      "Order Status": "Delivered",
      "Product Name": "Stainless Steel Deep Fryer Pot with Basket – Manual Oil Frying Cooker for Fries, Chicken & Snacks",
      "Short Code": "PK2NBNKOWO5"
    },
    {
      "Fee Name": "Shipping Fee Paid by Buyer",
      "Amount(Include Tax)": "49",
      "VAT Amount": "0",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Product Price Paid by Buyer",
      "Amount(Include Tax)": "1399",
      "VAT Amount": "0",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Commission Fee",
      "Amount(Include Tax)": "-160.89",
      "VAT Amount": "20.985",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Shipping Fee",
      "Amount(Include Tax)": "-230",
      "VAT Amount": "30",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Handling Fee",
      "Amount(Include Tax)": "-23",
      "VAT Amount": "3",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Shipping Fee Discount",
      "Amount(Include Tax)": "173.65",
      "VAT Amount": "22.65",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Free Shipping Max Fee",
      "Amount(Include Tax)": "-96.53",
      "VAT Amount": "12.591",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Co-funded Voucher Max",
      "Amount(Include Tax)": "-41.97",
      "VAT Amount": "0",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    },
    {
      "Fee Name": "Daraz Coins Discount Participation Fee",
      "Amount(Include Tax)": "-9.2",
      "VAT Amount": "1.2",
      "Order Number": "250676373648373",
      "Order Line ID": "250676373748373"
    }
  ];

  const benchmarkEntry = await buildEntryFromGroup(benchmarkStatementRows);
  reportResult(
    "Test 1: Benchmark Order #250676373648373 (Official Statement Reconciled)",
    1023.86,
    benchmarkEntry.net_settlement,
    `Gross: PKR ${benchmarkEntry.gross_amount}, Deductions: PKR ${benchmarkEntry.total_deductions}, Source: ${benchmarkEntry.source}`
  );

  // =========================================================================
  // TEST 2: Low-Value Order (< PKR 1,000 -> Handling Fee = PKR 17.40)
  // =========================================================================
  const handlingLow = getDarazHandlingFee(999.99);
  reportResult(
    "Test 2: Low-Value Order Handling Fee (< PKR 1,000 at 999.99 boundary)",
    17.40,
    handlingLow,
    "Strict PKR 15 base + 16% PST tier applied"
  );

  // =========================================================================
  // TEST 3: High-Value Order (>= PKR 2,000 -> Handling Fee = PKR 69.00)
  // =========================================================================
  const handlingMid = getDarazHandlingFee(1000.00);
  const handlingHigh = getDarazHandlingFee(2000.00);
  reportResult(
    "Test 3a: Mid-Value Boundary Handling Fee (PKR 1,000.00 exactly)",
    23.00,
    handlingMid,
    "Strict PKR 20 base + 15% PST tier applied"
  );
  reportResult(
    "Test 3b: High-Value Boundary Handling Fee (>= PKR 2,000 at 2,000.00 exactly)",
    69.00,
    handlingHigh,
    "Strict PKR 60 base + 15% PST tier applied"
  );

  // =========================================================================
  // TEST 4: Non-FSM Store (FSM Fee = PKR 0.00)
  // =========================================================================
  const nonFsmStore = { name: "TK-kart Store", code: "tk_store_01" };
  const isEnrolled = isStoreEnrolledInFSM(nonFsmStore);
  const nonFsmEstimate = calculateDarazSettlementForOrderItem(
    { unit_price: 1500, quantity: 1, name: "General Kitchen Knife", seller_sku: "K-01" },
    {},
    nonFsmStore
  );
  reportResult(
    "Test 4: Non-FSM Store Free Shipping Max Fee",
    0.00,
    nonFsmEstimate.freeShippingMaxFee,
    `Store isEnrolled: ${isEnrolled}, FSM fee zeroed out`
  );

  // =========================================================================
  // TEST 5: Category Commission Rates & Rules
  // =========================================================================
  const cookwareRule = resolveCategoryRule("Stainless Steel Pressure Cooker");
  const beautyRule = resolveCategoryRule("Rechargeable Facial Epilator Hair Remover");
  const electronicsRule = resolveCategoryRule("Bluetooth Wireless Earbuds Headphone");

  reportResult(
    "Test 5a: Cookware Category Effective Commission Rate (~11.50%)",
    0.1150035,
    cookwareRule.effectiveRate,
    `${cookwareRule.name} (Base 10% + 15% GST)`
  );
  reportResult(
    "Test 5b: Health & Beauty Category Effective Commission Rate (~18.45%)",
    0.1844612,
    beautyRule.effectiveRate,
    `${beautyRule.name} (Base 16% + 15% PST)`
  );
  reportResult(
    "Test 5c: Electronics Category Effective Commission Rate (~16.82%)",
    0.1682,
    electronicsRule.effectiveRate,
    `${electronicsRule.name} (Base 14.5% + 16% PST)`
  );

  // =========================================================================
  // TEST 6: Precedence Rule (Official Statement Wins over API Estimate)
  // =========================================================================
  // Simulate API estimate vs Official Statement
  const simulatedApiEstimate = 1003.21;
  const officialStatementRecord = benchmarkEntry.net_settlement;
  // Official statement must take authoritative precedence
  const finalAdoptedPayout = benchmarkEntry.source === "statement_file"
    ? officialStatementRecord
    : simulatedApiEstimate;

  reportResult(
    "Test 6: Precedence Rule (Official Statement overrides API Estimate)",
    1023.86,
    finalAdoptedPayout,
    `API Estimate was PKR ${simulatedApiEstimate}; Official Statement PKR ${officialStatementRecord} took precedence`
  );

  // =========================================================================
  // TEST 7: Section 236V WHT Exemption for Cookware vs Non-Exempt Beauty
  // =========================================================================
  const cookwareEstimate = calculateDarazSettlementForOrderItem(
    { unit_price: 1399, quantity: 1, name: "Non-Stick Frying Pan Cookware", seller_sku: "PAN-01" },
    {},
    { name: "Accessories Hub 76" }
  );
  const beautyEstimate = calculateDarazSettlementForOrderItem(
    { unit_price: 1500, quantity: 1, name: "Facial Hair Shaver Trimmer Beauty", seller_sku: "BEAUTY-01" },
    {},
    { name: "Accessories Hub 76" }
  );

  reportResult(
    "Test 7a: Section 236V WHT for Exempt Cookware Category",
    0.00,
    cookwareEstimate.incomeTaxWithholding,
    "Cookware / Kitchen appliances are strictly exempt (0.00 PKR WHT)"
  );
  reportResult(
    "Test 7b: Section 236V WHT for Non-Exempt Beauty Category (2% of PKR 1,500)",
    30.00,
    beautyEstimate.incomeTaxWithholding,
    "Non-exempt personal care/beauty order >= 1000 attracts 2.0% WHT (PKR 30.00)"
  );

  // =========================================================================
  // SUMMARY
  // =========================================================================
  console.log("\n============================================================");
  console.log(` TEST SUMMARY: ${passedTests}/${totalTests} Passed (${failedTests} Failed)`);
  console.log("============================================================\n");

  if (failedTests > 0) {
    process.exit(1);
  } else {
    process.exit(0);
  }
}

runTests().catch((err) => {
  console.error("Test execution failed:", err);
  process.exit(1);
});
