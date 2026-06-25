const mongoose = require('mongoose');

function toNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function toCsv(rows = [], headers = []) {
  const safe = (value) => {
    const text = value === null || value === undefined ? '' : String(value);
    return `"${text.replace(/"/g, '""')}"`;
  };

  const headerLine = headers.map((item) => safe(item.label)).join(',');
  const body = rows.map((row) => headers.map((item) => safe(row[item.key])).join(',')).join('\n');
  return `${headerLine}\n${body}`;
}

function startOfDay(input) {
  const date = new Date(input);
  date.setHours(0, 0, 0, 0);
  return date;
}

function endOfDay(input) {
  const date = new Date(input);
  date.setHours(23, 59, 59, 999);
  return date;
}

async function addStockToProduct({
  Product,
  InventoryTransaction,
  StockReceipt,
  productId,
  quantity,
  unitCost = 0,
  receiptType = 'purchase',
  supplierName = '',
  invoiceNumber = '',
  warehouseNote = '',
  note = '',
  adminName = 'admin'
}) {
  const qty = Math.max(0, Math.floor(toNumber(quantity, 0)));
  if (!qty) {
    const error = new Error('Quantity must be greater than zero');
    error.status = 400;
    throw error;
  }

  const session = await mongoose.startSession();
  let updatedProduct = null;
  let receiptDoc = null;

  try {
    await session.withTransaction(async () => {
      const product = await Product.findById(productId).session(session);
      if (!product) {
        const error = new Error('Product not found');
        error.status = 404;
        throw error;
      }

      const beforeStock = toNumber(product.stock, 0);
      const afterStock = beforeStock + qty;
      product.stock = afterStock;
      await product.save({ session });

      const receipts = await StockReceipt.create(
        [
          {
            product_id: product._id,
            receipt_type: receiptType,
            quantity: qty,
            unit_cost: Math.max(0, toNumber(unitCost, 0)),
            supplier_name: String(supplierName || '').trim(),
            invoice_number: String(invoiceNumber || '').trim(),
            warehouse_note: String(warehouseNote || '').trim(),
            note: String(note || '').trim(),
            created_by: String(adminName || 'admin').trim()
          }
        ],
        { session }
      );

      receiptDoc = receipts[0];

      await InventoryTransaction.create(
        [
          {
            store_id: null,
            product_id: product._id,
            inventory_id: null,
            seller_sku: product.sku,
            master_sku: product.sku,
            product_name: product.name,
            transaction_type: 'manual_add',
            quantity: qty,
            stock_before: beforeStock,
            stock_after: afterStock,
            note: String(note || `Stock received (${receiptType})`).trim()
          }
        ],
        { session }
      );

      updatedProduct = product;
    });
  } finally {
    await session.endSession();
  }

  return {
    product: updatedProduct,
    receipt: receiptDoc
  };
}

async function approveAdjustmentRequest({
  Product,
  StockAdjustmentRequest,
  InventoryTransaction,
  requestId,
  approvedBy = 'admin',
  decisionNote = ''
}) {
  const session = await mongoose.startSession();
  let updatedRequest = null;
  let updatedProduct = null;

  try {
    await session.withTransaction(async () => {
      const request = await StockAdjustmentRequest.findById(requestId).session(session);
      if (!request) {
        const error = new Error('Adjustment request not found');
        error.status = 404;
        throw error;
      }
      if (request.status !== 'pending') {
        const error = new Error('Only pending requests can be approved');
        error.status = 400;
        throw error;
      }

      const product = await Product.findById(request.product_id).session(session);
      if (!product) {
        const error = new Error('Product not found');
        error.status = 404;
        throw error;
      }

      const qty = Math.max(0, Math.floor(toNumber(request.quantity, 0)));
      const beforeStock = toNumber(product.stock, 0);
      const afterStock = request.adjustment_type === 'increase'
        ? beforeStock + qty
        : beforeStock - qty;

      if (request.adjustment_type === 'decrease' && afterStock < 0) {
        const error = new Error('Not enough stock to approve this decrease request');
        error.status = 400;
        throw error;
      }

      product.stock = afterStock;
      await product.save({ session });

      request.status = 'approved';
      request.stock_before = beforeStock;
      request.stock_after = afterStock;
      request.decision_note = String(decisionNote || '').trim();
      request.approved_by = String(approvedBy || 'admin').trim();
      request.approved_at = new Date();
      await request.save({ session });

      await InventoryTransaction.create(
        [
          {
            store_id: null,
            product_id: product._id,
            inventory_id: null,
            seller_sku: product.sku,
            master_sku: product.sku,
            product_name: product.name,
            adjustment_request_id: request._id,
            transaction_type: request.adjustment_type === 'increase' ? 'manual_add' : 'manual_deduct',
            quantity: qty,
            stock_before: beforeStock,
            stock_after: afterStock,
            note: `Approved adjustment (${request.reason_code})${request.note ? ` - ${request.note}` : ''}`
          }
        ],
        { session }
      );

      updatedRequest = request;
      updatedProduct = product;
    });
  } finally {
    await session.endSession();
  }

  return { request: updatedRequest, product: updatedProduct };
}

module.exports = {
  toNumber,
  toCsv,
  startOfDay,
  endOfDay,
  addStockToProduct,
  approveAdjustmentRequest
};
