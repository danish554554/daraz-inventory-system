const express = require('express');
const router = express.Router();

const CentralInventory = require('../models/CentralInventory');
const InventoryTransaction = require('../models/InventoryTransaction');
const StockReceipt = require('../models/StockReceipt');
const StockAdjustmentRequest = require('../models/StockAdjustmentRequest');
const Store = require('../models/Store');

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

function normalizeDateInput(value) {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) return new Date();
  return date;
}

async function findInventoryByPayload({ inventory_id, product_id, store_id, seller_sku, product_name }) {
  if (inventory_id) {
    return CentralInventory.findById(inventory_id);
  }

  if (product_id) {
    return CentralInventory.findById(product_id);
  }

  if (store_id && seller_sku) {
    return CentralInventory.findOneAndUpdate(
      { store_id, seller_sku: String(seller_sku).trim() },
      {
        $setOnInsert: {
          store_id,
          seller_sku: String(seller_sku).trim(),
          product_name: String(product_name || seller_sku).trim(),
          stock: 0,
          reserved_stock: 0,
          low_stock_limit: 5
        },
        $set: product_name ? { product_name: String(product_name).trim() } : {}
      },
      { upsert: true, new: true }
    );
  }

  return null;
}

function makeInventoryRow(item) {
  const stock = toNumber(item.stock, 0);
  const reserved = toNumber(item.reserved_stock, 0);
  return {
    _id: item._id,
    inventory_id: item._id,
    store_id: item.store_id?._id || item.store_id,
    store_name: item.store_id?.name || item.store_name || '-',
    store_code: item.store_id?.code || '-',
    product_name: item.product_name || item.seller_sku,
    seller_sku: item.seller_sku,
    master_sku: item.seller_sku,
    stock,
    reserved_stock: reserved,
    available_stock: Math.max(stock - reserved, 0),
    low_stock_limit: toNumber(item.low_stock_limit, 5),
    mapped_sku_count: 1,
    mapped_skus_text: `${item.store_id?.code || item.store_code || '-'}:${item.seller_sku}`,
    stores_involved: 1,
    updatedAt: item.updatedAt || item.createdAt
  };
}

async function getInventoryRows({ search = '', lowStockOnly = false, storeId = '' } = {}) {
  const query = {};
  if (storeId) query.store_id = storeId;
  if (search?.trim()) {
    query.$or = [
      { product_name: { $regex: search.trim(), $options: 'i' } },
      { seller_sku: { $regex: search.trim(), $options: 'i' } }
    ];
  }

  let items = await CentralInventory.find(query)
    .populate('store_id', 'name code')
    .sort({ updatedAt: -1, createdAt: -1 })
    .lean();

  let rows = items.map(makeInventoryRow);
  if (lowStockOnly) rows = rows.filter((item) => item.stock <= item.low_stock_limit);
  return rows;
}

async function getRecentRestocks(limit = 20, storeId = '') {
  const query = {};
  if (storeId) query.store_id = storeId;
  const rows = await StockReceipt.find(query)
    .populate('store_id', 'name code')
    .sort({ createdAt: -1 })
    .limit(limit)
    .lean();

  return rows.map((item) => ({
    _id: item._id,
    inventory_id: item.inventory_id,
    store_id: item.store_id?._id || item.store_id,
    store_name: item.store_id?.name || '-',
    store_code: item.store_id?.code || '-',
    product_name: item.product_name || item.seller_sku || '-',
    seller_sku: item.seller_sku || '-',
    master_sku: item.seller_sku || '-',
    receipt_type: item.receipt_type || 'purchase',
    quantity: toNumber(item.quantity, 0),
    unit_cost: toNumber(item.unit_cost, 0),
    total_cost: toNumber(item.quantity, 0) * toNumber(item.unit_cost, 0),
    supplier_name: item.supplier_name || '-',
    invoice_number: item.invoice_number || '-',
    warehouse_note: item.warehouse_note || '',
    note: item.note || '',
    created_by: item.created_by || 'admin',
    createdAt: item.createdAt
  }));
}

async function getTransactions({ storeId = '', sellerSku = '', limit = 100 }) {
  const query = {};
  if (storeId) query.store_id = storeId;
  if (sellerSku?.trim()) query.seller_sku = sellerSku.trim();

  const rows = await InventoryTransaction.find(query)
    .populate('store_id', 'name code')
    .sort({ createdAt: -1 })
    .limit(Math.min(500, Math.max(1, Number(limit) || 100)))
    .lean();

  return rows.map((item) => ({
    _id: item._id,
    inventory_id: item.inventory_id,
    store_id: item.store_id?._id || item.store_id,
    store_name: item.store_id?.name || '-',
    store_code: item.store_id?.code || '-',
    seller_sku: item.seller_sku,
    master_sku: item.master_sku || item.seller_sku,
    product_name: item.product_name || item.seller_sku,
    transaction_type: item.transaction_type,
    quantity: item.quantity,
    stock_before: item.stock_before,
    stock_after: item.stock_after,
    note: item.note,
    createdAt: item.createdAt,
    external_order_id: item.external_order_id,
    external_order_item_id: item.external_order_item_id
  }));
}

async function getDailyReport(dateInput, search = '', storeId = '') {
  const date = normalizeDateInput(dateInput);
  const startDate = startOfDay(date);
  const endDate = endOfDay(date);

  const txQuery = { createdAt: { $gte: startDate, $lte: endDate } };
  if (storeId) txQuery.store_id = storeId;
  if (search?.trim()) {
    txQuery.$or = [
      { seller_sku: { $regex: search.trim(), $options: 'i' } },
      { product_name: { $regex: search.trim(), $options: 'i' } },
      { note: { $regex: search.trim(), $options: 'i' } }
    ];
  }

  const transactions = await InventoryTransaction.find(txQuery).sort({ createdAt: -1 }).lean();
  const map = new Map();

  for (const tx of transactions) {
    const sku = tx.seller_sku || tx.master_sku || 'UNKNOWN';
    const rowKey = `${String(tx.store_id || '')}:${sku}`;
    if (!map.has(rowKey)) {
      map.set(rowKey, {
        store_id: tx.store_id,
        product_name: tx.product_name || sku,
        master_sku: sku,
        sold_qty: 0,
        restored_qty: 0,
        manual_add_qty: 0,
        manual_deduct_qty: 0,
        opening_stock: null,
        closing_stock: null
      });
    }

    const row = map.get(rowKey);
    const qty = Math.abs(toNumber(tx.quantity, 0));

    if (tx.transaction_type === 'order_deduct') row.sold_qty += qty;
    if (tx.transaction_type === 'cancel_restore') row.restored_qty += qty;
    if (tx.transaction_type === 'manual_add' || tx.transaction_type === 'adjustment_approved' && tx.stock_after > tx.stock_before) row.manual_add_qty += qty;
    if (tx.transaction_type === 'manual_deduct' || tx.transaction_type === 'adjustment_approved' && tx.stock_after < tx.stock_before) row.manual_deduct_qty += qty;

    if (row.closing_stock === null) row.closing_stock = toNumber(tx.stock_after, 0);
    row.opening_stock = toNumber(tx.stock_before, 0);
  }

  const rows = Array.from(map.values()).map((item) => ({
    ...item,
    opening_stock: item.opening_stock === null ? 0 : item.opening_stock,
    closing_stock: item.closing_stock === null ? 0 : item.closing_stock
  }));

  const totals = rows.reduce((acc, item) => {
    acc.products += 1;
    acc.opening_stock += toNumber(item.opening_stock, 0);
    acc.sold_qty += toNumber(item.sold_qty, 0);
    acc.restored_qty += toNumber(item.restored_qty, 0);
    acc.manual_add_qty += toNumber(item.manual_add_qty, 0);
    acc.manual_deduct_qty += toNumber(item.manual_deduct_qty, 0);
    acc.closing_stock += toNumber(item.closing_stock, 0);
    return acc;
  }, { products: 0, opening_stock: 0, sold_qty: 0, restored_qty: 0, manual_add_qty: 0, manual_deduct_qty: 0, closing_stock: 0 });

  return { date: startDate, rows, totals };
}

async function getSupplierAnalytics({ start, end, supplier = '', storeId = '' } = {}) {
  const dateStart = start ? startOfDay(start) : startOfDay(new Date(new Date().setDate(new Date().getDate() - 29)));
  const dateEnd = end ? endOfDay(end) : endOfDay(new Date());
  const query = { createdAt: { $gte: dateStart, $lte: dateEnd } };
  if (storeId) query.store_id = storeId;
  if (supplier?.trim()) query.supplier_name = { $regex: supplier.trim(), $options: 'i' };

  const receipts = await StockReceipt.find(query).sort({ createdAt: -1 }).lean();
  const bySupplier = new Map();
  const byDay = new Map();

  for (const item of receipts) {
    const supplierName = item.supplier_name || 'Unknown Supplier';
    const dateKey = new Date(item.createdAt).toISOString().slice(0, 10);
    const qty = toNumber(item.quantity, 0);
    const unitCost = toNumber(item.unit_cost, 0);
    const lineCost = qty * unitCost;

    if (!bySupplier.has(supplierName)) {
      bySupplier.set(supplierName, { supplier_name: supplierName, entries: 0, total_quantity: 0, total_cost: 0, avg_unit_cost: 0, invoices: new Set(), last_purchase_at: null });
    }
    const supplierRow = bySupplier.get(supplierName);
    supplierRow.entries += 1;
    supplierRow.total_quantity += qty;
    supplierRow.total_cost += lineCost;
    if (item.invoice_number) supplierRow.invoices.add(item.invoice_number);
    if (!supplierRow.last_purchase_at || new Date(item.createdAt) > new Date(supplierRow.last_purchase_at)) supplierRow.last_purchase_at = item.createdAt;

    if (!byDay.has(dateKey)) byDay.set(dateKey, { date: dateKey, entries: 0, total_quantity: 0, total_cost: 0 });
    const dayRow = byDay.get(dateKey);
    dayRow.entries += 1;
    dayRow.total_quantity += qty;
    dayRow.total_cost += lineCost;
  }

  const suppliers = Array.from(bySupplier.values()).map((item) => ({
    ...item,
    avg_unit_cost: item.total_quantity ? Number((item.total_cost / item.total_quantity).toFixed(2)) : 0,
    invoice_count: item.invoices.size
  })).sort((a, b) => b.total_cost - a.total_cost);

  const daily = Array.from(byDay.values()).sort((a, b) => String(a.date).localeCompare(String(b.date)));
  const totals = suppliers.reduce((acc, item) => {
    acc.suppliers += 1;
    acc.total_quantity += toNumber(item.total_quantity, 0);
    acc.total_cost += toNumber(item.total_cost, 0);
    acc.entries += toNumber(item.entries, 0);
    return acc;
  }, { suppliers: 0, total_quantity: 0, total_cost: 0, entries: 0 });

  return { start: dateStart, end: dateEnd, suppliers, daily, totals };
}

router.get('/', async (req, res, next) => {
  try {
    const rows = await getInventoryRows({ search: req.query.search, storeId: req.query.store_id || '', lowStockOnly: ['1', 'true', 'yes'].includes(String(req.query.low_stock).toLowerCase()) });
    res.json(rows);
  } catch (error) { next(error); }
});

router.get('/summary', async (req, res, next) => {
  try {
    const [inventoryRows, recentRestocks, pendingAdjustments] = await Promise.all([
      getInventoryRows({ search: req.query.search, storeId: req.query.store_id || '' }),
      getRecentRestocks(10, req.query.store_id || ''),
      StockAdjustmentRequest.countDocuments(req.query.store_id ? { status: 'pending', store_id: req.query.store_id } : { status: 'pending' })
    ]);

    const summary = inventoryRows.reduce((acc, item) => {
      acc.total_products += 1;
      acc.total_stock += toNumber(item.stock, 0);
      acc.total_reserved_stock += toNumber(item.reserved_stock, 0);
      acc.total_available_stock += toNumber(item.available_stock, 0);
      if (toNumber(item.stock, 0) <= toNumber(item.low_stock_limit, 0)) acc.low_stock_products += 1;
      if (toNumber(item.stock, 0) <= 0) acc.zero_stock_products += 1;
      return acc;
    }, { total_products: 0, total_stock: 0, total_reserved_stock: 0, total_available_stock: 0, low_stock_products: 0, zero_stock_products: 0 });

    res.json({ ...summary, recent_restock_entries: recentRestocks.length, pending_adjustments: pendingAdjustments });
  } catch (error) { next(error); }
});

router.get('/transactions', async (req, res, next) => {
  try {
    const rows = await getTransactions({ storeId: req.query.store_id || '', sellerSku: req.query.seller_sku || '', limit: req.query.limit || 100 });
    res.json(rows);
  } catch (error) { next(error); }
});

router.get('/daily-report', async (req, res, next) => {
  try {
    const report = await getDailyReport(req.query.date, req.query.search || '', req.query.store_id || '');
    res.json(report);
  } catch (error) { next(error); }
});

router.get('/analytics/purchases', async (req, res, next) => {
  try {
    const analytics = await getSupplierAnalytics({ start: req.query.start, end: req.query.end, supplier: req.query.supplier || '', storeId: req.query.store_id || '' });
    res.json(analytics);
  } catch (error) { next(error); }
});

router.get('/restocks', async (req, res, next) => {
  try {
    const limit = Math.min(100, Math.max(1, Number(req.query.limit) || 25));
    const rows = await getRecentRestocks(limit, req.query.store_id || '');
    res.json(rows);
  } catch (error) { next(error); }
});

router.post('/restock', async (req, res, next) => {
  try {
    const inventory = await findInventoryByPayload(req.body);
    if (!inventory) return res.status(400).json({ message: 'inventory_id or store_id + seller_sku is required' });

    const qty = Math.max(1, Math.floor(toNumber(req.body.quantity, 0)));
    const unitCost = Math.max(0, toNumber(req.body.unit_cost, 0));
    const stockBefore = toNumber(inventory.stock, 0);
    inventory.stock = stockBefore + qty;
    if (req.body.product_name) inventory.product_name = String(req.body.product_name).trim();
    if (req.body.low_stock_limit !== undefined) inventory.low_stock_limit = Math.max(0, Math.floor(toNumber(req.body.low_stock_limit, 5)));
    await inventory.save();

    const receipt = await StockReceipt.create({
      inventory_id: inventory._id,
      store_id: inventory.store_id,
      seller_sku: inventory.seller_sku,
      product_name: inventory.product_name,
      quantity: qty,
      unit_cost: unitCost,
      supplier_name: String(req.body.supplier_name || '').trim(),
      invoice_number: String(req.body.invoice_number || '').trim(),
      warehouse_note: String(req.body.warehouse_note || '').trim(),
      note: String(req.body.note || '').trim(),
      receipt_type: req.body.receipt_type || 'purchase',
      created_by: String(req.body.created_by || 'admin').trim()
    });

    await InventoryTransaction.create({
      store_id: inventory.store_id,
      inventory_id: inventory._id,
      seller_sku: inventory.seller_sku,
      master_sku: inventory.seller_sku,
      product_name: inventory.product_name,
      transaction_type: 'manual_add',
      quantity: qty,
      stock_before: stockBefore,
      stock_after: inventory.stock,
      note: String(req.body.note || 'Manual restock').trim()
    });

    res.json({ message: 'Stock added successfully', inventory, receipt });
  } catch (error) { next(error); }
});

router.post('/restock/bulk', async (req, res, next) => {
  try {
    const raw = String(req.body.rows || '').trim();
    if (!raw) return res.status(400).json({ message: 'rows text is required' });

    const lines = raw.split('\n').map((item) => item.trim()).filter(Boolean);
    const results = [];
    const errors = [];

    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const [storeCode, sellerSku, qtyRaw, costRaw = '0', supplierName = '', invoiceNumber = '', note = '', productName = ''] = line.split(',').map((item) => item.trim());
      try {
        const store = await Store.findOne({ code: storeCode });
        if (!store) throw new Error(`Store not found for code ${storeCode}`);
        const inventory = await findInventoryByPayload({ store_id: store._id, seller_sku: sellerSku, product_name: productName || sellerSku });
        const qty = Math.max(1, Math.floor(toNumber(qtyRaw, 0)));
        const unitCost = Math.max(0, toNumber(costRaw, 0));
        const stockBefore = toNumber(inventory.stock, 0);
        inventory.stock = stockBefore + qty;
        await inventory.save();
        await StockReceipt.create({ inventory_id: inventory._id, store_id: inventory.store_id, seller_sku: inventory.seller_sku, product_name: inventory.product_name, quantity: qty, unit_cost: unitCost, supplier_name: supplierName, invoice_number: invoiceNumber, note, receipt_type: 'purchase', created_by: req.body.created_by || 'admin' });
        await InventoryTransaction.create({ store_id: inventory.store_id, inventory_id: inventory._id, seller_sku: inventory.seller_sku, master_sku: inventory.seller_sku, product_name: inventory.product_name, transaction_type: 'manual_add', quantity: qty, stock_before: stockBefore, stock_after: inventory.stock, note: note || 'Bulk restock' });
        results.push({ line: index + 1, store_code: storeCode, seller_sku: inventory.seller_sku, product_name: inventory.product_name, quantity: qty, stock_after: inventory.stock });
      } catch (error) {
        errors.push({ line: index + 1, value: line, message: error.message || 'Bulk restock failed' });
      }
    }

    res.json({ message: 'Bulk restock processed', processed: results.length, failed: errors.length, results, errors });
  } catch (error) { next(error); }
});

router.post('/adjust', async (req, res, next) => {
  try {
    const inventory = await findInventoryByPayload(req.body);
    if (!inventory) return res.status(400).json({ message: 'inventory_id or store_id + seller_sku is required' });
    const qty = Math.max(1, Math.floor(toNumber(req.body.quantity, 0)));
    const type = String(req.body.type || req.body.adjustment_type || '').trim().toLowerCase();
    if (!['increase', 'decrease'].includes(type)) return res.status(400).json({ message: 'type must be increase or decrease' });

    const stockBefore = toNumber(inventory.stock, 0);
    const stockAfter = type === 'increase' ? stockBefore + qty : Math.max(0, stockBefore - qty);
    inventory.stock = stockAfter;
    await inventory.save();

    const txType = type === 'increase' ? 'manual_add' : 'manual_deduct';
    const transaction = await InventoryTransaction.create({
      store_id: inventory.store_id,
      inventory_id: inventory._id,
      seller_sku: inventory.seller_sku,
      master_sku: inventory.seller_sku,
      product_name: inventory.product_name,
      transaction_type: txType,
      quantity: qty,
      stock_before: stockBefore,
      stock_after: stockAfter,
      note: String(req.body.note || '').trim()
    });

    res.json({ message: 'Inventory adjusted successfully', inventory, transaction });
  } catch (error) { next(error); }
});

router.get('/adjustment-requests', async (req, res, next) => {
  try {
    const status = req.query.status || 'pending';
    const query = status === 'all' ? {} : { status };
    if (req.query.store_id) query.store_id = req.query.store_id;
    const rows = await StockAdjustmentRequest.find(query).populate('store_id', 'name code').sort({ createdAt: -1 }).lean();
    res.json(rows.map((item) => ({
      _id: item._id,
      inventory_id: item.inventory_id,
      store_id: item.store_id?._id || item.store_id,
      store_name: item.store_id?.name || '-',
      master_sku: item.seller_sku,
      seller_sku: item.seller_sku,
      product_name: item.product_name || item.seller_sku,
      current_stock: toNumber(item.stock_after ?? item.stock_before, 0),
      adjustment_type: item.adjustment_type,
      quantity: toNumber(item.quantity, 0),
      reason_code: item.reason_code,
      note: item.note || '',
      requested_by: item.requested_by || 'admin',
      status: item.status,
      stock_before: toNumber(item.stock_before, 0),
      stock_after: item.stock_after === null ? null : toNumber(item.stock_after, 0),
      decision_note: item.decision_note || '',
      approved_by: item.approved_by || '',
      approved_at: item.approved_at,
      createdAt: item.createdAt
    })));
  } catch (error) { next(error); }
});

router.post('/adjustment-requests', async (req, res, next) => {
  try {
    const inventory = await findInventoryByPayload(req.body);
    if (!inventory) return res.status(400).json({ message: 'inventory_id or store_id + seller_sku is required' });
    if (!req.body.adjustment_type || !req.body.quantity) return res.status(400).json({ message: 'adjustment_type and quantity are required' });

    const request = await StockAdjustmentRequest.create({
      inventory_id: inventory._id,
      store_id: inventory.store_id,
      seller_sku: inventory.seller_sku,
      product_name: inventory.product_name,
      adjustment_type: req.body.adjustment_type,
      quantity: Math.max(1, Math.floor(toNumber(req.body.quantity, 0))),
      reason_code: req.body.reason_code || 'other',
      note: String(req.body.note || '').trim(),
      requested_by: String(req.body.requested_by || 'admin').trim(),
      stock_before: toNumber(inventory.stock, 0)
    });

    res.json({ message: 'Adjustment request created', request });
  } catch (error) { next(error); }
});

router.post('/adjustment-requests/:id/approve', async (req, res, next) => {
  try {
    const request = await StockAdjustmentRequest.findById(req.params.id);
    if (!request) return res.status(404).json({ message: 'Adjustment request not found' });
    if (request.status !== 'pending') return res.status(400).json({ message: 'Only pending requests can be approved' });
    const inventory = await CentralInventory.findById(request.inventory_id);
    if (!inventory) return res.status(404).json({ message: 'Central inventory not found' });

    const stockBefore = toNumber(inventory.stock, 0);
    const qty = toNumber(request.quantity, 0);
    inventory.stock = request.adjustment_type === 'increase' ? stockBefore + qty : Math.max(0, stockBefore - qty);
    await inventory.save();

    request.status = 'approved';
    request.decision_note = String(req.body.decision_note || '').trim();
    request.approved_by = String(req.body.approved_by || 'admin').trim();
    request.approved_at = new Date();
    request.stock_after = inventory.stock;
    await request.save();

    const transaction = await InventoryTransaction.create({
      store_id: inventory.store_id,
      inventory_id: inventory._id,
      seller_sku: inventory.seller_sku,
      master_sku: inventory.seller_sku,
      product_name: inventory.product_name,
      adjustment_request_id: request._id,
      transaction_type: 'adjustment_approved',
      quantity: qty,
      stock_before: stockBefore,
      stock_after: inventory.stock,
      note: request.note || request.reason_code
    });

    res.json({ message: 'Adjustment approved successfully', request, inventory, transaction });
  } catch (error) { next(error); }
});

router.post('/adjustment-requests/:id/reject', async (req, res, next) => {
  try {
    const request = await StockAdjustmentRequest.findById(req.params.id);
    if (!request) return res.status(404).json({ message: 'Adjustment request not found' });
    if (request.status !== 'pending') return res.status(400).json({ message: 'Only pending requests can be rejected' });
    request.status = 'rejected';
    request.decision_note = String(req.body.decision_note || '').trim();
    request.approved_by = String(req.body.approved_by || 'admin').trim();
    request.approved_at = new Date();
    await request.save();
    res.json({ message: 'Adjustment request rejected', request });
  } catch (error) { next(error); }
});

router.get('/export/inventory.csv', async (req, res, next) => {
  try {
    const rows = await getInventoryRows({ search: req.query.search || '', storeId: req.query.store_id || '' });
    const csv = toCsv(rows, [
      { key: 'store_code', label: 'Store Code' },
      { key: 'store_name', label: 'Store Name' },
      { key: 'product_name', label: 'Product Name' },
      { key: 'seller_sku', label: 'Seller SKU' },
      { key: 'stock', label: 'Stock' },
      { key: 'reserved_stock', label: 'Reserved Stock' },
      { key: 'available_stock', label: 'Available Stock' },
      { key: 'low_stock_limit', label: 'Low Stock Limit' }
    ]);
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename="inventory-report.csv"');
    res.send(csv);
  } catch (error) { next(error); }
});

router.get('/export/restocks.csv', async (req, res, next) => {
  try {
    const rows = await getRecentRestocks(500, req.query.store_id || '');
    const csv = toCsv(rows, [
      { key: 'createdAt', label: 'Created At' },
      { key: 'store_code', label: 'Store Code' },
      { key: 'store_name', label: 'Store Name' },
      { key: 'product_name', label: 'Product Name' },
      { key: 'seller_sku', label: 'Seller SKU' },
      { key: 'receipt_type', label: 'Receipt Type' },
      { key: 'quantity', label: 'Quantity' },
      { key: 'unit_cost', label: 'Unit Cost' },
      { key: 'total_cost', label: 'Total Cost' },
      { key: 'supplier_name', label: 'Supplier' },
      { key: 'invoice_number', label: 'Invoice Number' },
      { key: 'note', label: 'Note' }
    ]);
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename="restock-report.csv"');
    res.send(csv);
  } catch (error) { next(error); }
});

router.get('/export/purchase-analytics.csv', async (req, res, next) => {
  try {
    const analytics = await getSupplierAnalytics({ start: req.query.start, end: req.query.end, supplier: req.query.supplier || '', storeId: req.query.store_id || '' });
    const csv = toCsv(analytics.suppliers, [
      { key: 'supplier_name', label: 'Supplier' },
      { key: 'entries', label: 'Entries' },
      { key: 'total_quantity', label: 'Total Quantity' },
      { key: 'total_cost', label: 'Total Cost' },
      { key: 'avg_unit_cost', label: 'Average Unit Cost' },
      { key: 'invoice_count', label: 'Invoice Count' },
      { key: 'last_purchase_at', label: 'Last Purchase At' }
    ]);
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename="supplier-purchase-analytics.csv"');
    res.send(csv);
  } catch (error) { next(error); }
});

router.use((error, req, res, next) => {
  const status = error.status || 500;
  res.status(status).json({ message: error.message || 'Central inventory request failed', error: error.message || 'Unknown error' });
});

module.exports = router;
