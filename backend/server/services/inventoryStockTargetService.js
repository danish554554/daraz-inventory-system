const mongoose = require('mongoose');
const CentralInventory = require('../models/CentralInventory');
const InventoryMergeGroup = require('../models/InventoryMergeGroup');

function safeString(value) {
  return (value ?? '').toString().trim();
}

function toNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function isObjectId(value) {
  return mongoose.Types.ObjectId.isValid(String(value || ''));
}

function normalizeSku(value) {
  return safeString(value);
}

function buildMasterSku(title = '', fallback = '') {
  const base = safeString(title || fallback || 'MASTER')
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
  return base || 'MASTER';
}

async function findGroupById(id) {
  if (!isObjectId(id)) return null;
  return InventoryMergeGroup.findById(id).populate({ path: 'inventory_ids', populate: { path: 'store_id', select: 'name code' } });
}

async function findGroupByInventoryId(inventoryId) {
  if (!isObjectId(inventoryId)) return null;
  return InventoryMergeGroup.findOne({ inventory_ids: inventoryId }).populate({ path: 'inventory_ids', populate: { path: 'store_id', select: 'name code' } });
}

async function findInventoryById(id) {
  if (!isObjectId(id)) return null;
  return CentralInventory.findById(id).populate('store_id', 'name code');
}

async function findOrCreateInventoryBySku({ store_id, seller_sku, product_name = '', display_title = '', image_url = '', allowCreate = true }) {
  const sku = normalizeSku(seller_sku);
  if (!store_id || !sku) return null;

  const cleanName = safeString(product_name) || sku;
  const cleanTitle = safeString(display_title) || cleanName;
  const update = {};
  if (cleanName) {
    update.product_name = cleanName;
    update.original_product_name = cleanName;
  }
  if (cleanTitle) update.display_title = cleanTitle;
  if (safeString(image_url)) update.image_url = safeString(image_url);

  if (!allowCreate) {
    const existing = await CentralInventory.findOne({ store_id, seller_sku: sku }).populate('store_id', 'name code');
    if (existing && Object.keys(update).length) {
      await CentralInventory.updateOne({ _id: existing._id }, { $set: update });
      Object.assign(existing, update);
    }
    return existing;
  }

  return CentralInventory.findOneAndUpdate(
    { store_id, seller_sku: sku },
    {
      $setOnInsert: {
        store_id,
        seller_sku: sku,
        product_name: cleanName,
        original_product_name: cleanName,
        display_title: cleanTitle,
        image_url: safeString(image_url),
        stock: 0,
        reserved_stock: 0,
        low_stock_limit: 5
      },
      $set: update
    },
    { upsert: true, new: true, setDefaultsOnInsert: true }
  ).populate('store_id', 'name code');
}

function groupTarget(group, inventory = null) {
  const items = Array.isArray(group.inventory_ids) ? group.inventory_ids.filter(Boolean) : [];
  const primary = inventory || items[0] || {};
  const title = safeString(group.title || primary.display_title || primary.product_name || primary.seller_sku || 'Merged Product');
  return {
    kind: 'merge',
    doc: group,
    group,
    inventory: primary,
    inventory_id: group._id,
    stock_doc_id: group._id,
    store_id: primary.store_id?._id || primary.store_id || null,
    seller_sku: primary.seller_sku || safeString(group.master_sku),
    master_sku: safeString(group.master_sku) || buildMasterSku(title, group._id),
    product_name: title,
    display_title: title,
    image_url: safeString(group.image_url || primary.image_url),
    stock: toNumber(group.stock, toNumber(primary.stock, 0)),
    reserved_stock: toNumber(group.reserved_stock, 0),
    low_stock_limit: toNumber(group.low_stock_limit, 5),
    linked_items: items,
    source_inventory_ids: items.map((item) => String(item._id || item))
  };
}

function inventoryTarget(inventory) {
  return {
    kind: 'inventory',
    doc: inventory,
    inventory,
    group: null,
    inventory_id: inventory._id,
    stock_doc_id: inventory._id,
    store_id: inventory.store_id?._id || inventory.store_id || null,
    seller_sku: inventory.seller_sku,
    master_sku: inventory.seller_sku,
    product_name: inventory.product_name || inventory.display_title || inventory.seller_sku,
    display_title: inventory.display_title || inventory.product_name || inventory.seller_sku,
    image_url: safeString(inventory.image_url),
    stock: toNumber(inventory.stock, 0),
    reserved_stock: toNumber(inventory.reserved_stock, 0),
    low_stock_limit: toNumber(inventory.low_stock_limit, 5),
    linked_items: [inventory],
    source_inventory_ids: [String(inventory._id)]
  };
}

async function resolveStockTarget(payload = {}, options = {}) {
  const allowCreate = options.allowCreate !== false;
  const directId = safeString(payload.inventory_id || payload.product_id || payload.master_product_id || payload.merge_group_id);

  if (directId) {
    const groupById = await findGroupById(directId);
    if (groupById) return groupTarget(groupById);

    const inventory = await findInventoryById(directId);
    if (inventory) {
      const group = await findGroupByInventoryId(inventory._id);
      if (group) return groupTarget(group, inventory);
      return inventoryTarget(inventory);
    }
  }

  const sku = normalizeSku(payload.seller_sku);
  if (payload.store_id && sku) {
    const inventory = await findOrCreateInventoryBySku({
      store_id: payload.store_id,
      seller_sku: sku,
      product_name: payload.product_name,
      display_title: payload.display_title,
      image_url: payload.image_url,
      allowCreate
    });
    if (!inventory) return null;

    const group = await findGroupByInventoryId(inventory._id);
    if (group) return groupTarget(group, inventory);
    return inventoryTarget(inventory);
  }

  return null;
}

async function updateTargetStock(target, { type, quantity, product_name, low_stock_limit }) {
  const qty = Math.max(1, Math.floor(toNumber(quantity, 0)));
  if (!target || !qty) throw new Error('A valid stock target and quantity are required');

  const inc = type === 'decrease' ? -qty : qty;
  const set = {};
  if (safeString(product_name)) set[target.kind === 'merge' ? 'title' : 'product_name'] = safeString(product_name);
  if (low_stock_limit !== undefined) set.low_stock_limit = Math.max(0, Math.floor(toNumber(low_stock_limit, 5)));

  const Model = target.kind === 'merge' ? InventoryMergeGroup : CentralInventory;
  if (target.kind === 'merge' && (target.doc.stock === undefined || target.doc.stock === null)) {
    await InventoryMergeGroup.updateOne(
      { _id: target.stock_doc_id },
      {
        $set: {
          stock: toNumber(target.stock, 0),
          reserved_stock: toNumber(target.reserved_stock, 0),
          low_stock_limit: toNumber(target.low_stock_limit, 5)
        }
      }
    );
  }
  const filter = { _id: target.stock_doc_id };
  if (type === 'decrease') filter.stock = { $gte: qty };

  const update = { $inc: { stock: inc } };
  if (Object.keys(set).length) update.$set = set;

  const before = await Model.findOneAndUpdate(filter, update, { new: false });
  if (!before) {
    return {
      ok: false,
      reason: 'insufficient_stock',
      stock_before: target.stock,
      stock_after: target.stock
    };
  }

  const stockBefore = toNumber(before.stock, 0);
  const stockAfter = stockBefore + inc;
  return {
    ok: true,
    stock_before: stockBefore,
    stock_after: stockAfter,
    quantity: qty,
    target: await resolveStockTarget({ inventory_id: target.stock_doc_id }, { allowCreate: false })
  };
}

async function setTargetLowStockLimit(target, threshold) {
  const value = Math.max(0, Math.floor(toNumber(threshold, target.low_stock_limit || 5)));
  if (target.kind === 'merge') {
    await InventoryMergeGroup.updateOne({ _id: target.stock_doc_id }, { $set: { low_stock_limit: value } });
  } else {
    await CentralInventory.updateOne({ _id: target.stock_doc_id }, { $set: { low_stock_limit: value } });
  }
  return value;
}

module.exports = {
  safeString,
  toNumber,
  buildMasterSku,
  resolveStockTarget,
  updateTargetStock,
  setTargetLowStockLimit,
  findGroupByInventoryId,
  findGroupById
};
