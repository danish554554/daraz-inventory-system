const express = require("express");
const CentralOrder = require("../models/CentralOrder");
const CentralOrderItem = require("../models/CentralOrderItem");
const {
  syncAllStores,
  syncStoreById,
  getSyncLockState
} = require("../services/centralInventorySyncService");

const router = express.Router();

function normalizeString(value) {
  return (value || "").toString().trim();
}

router.get("/status", async (req, res) => {
  try {
    const lockState = getSyncLockState();

    res.json({
      success: true,
      scheduler_managed_by: "orderSyncScheduler",
      sync_engine: "centralInventorySyncService",
      sync_running_now: !!lockState.syncInProgress
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error getting sync status",
      error: error.message
    });
  }
});

router.post("/run-all", async (req, res) => {
  try {
    const lockState = getSyncLockState();

    if (lockState.syncInProgress) {
      return res.status(409).json({
        success: false,
        message: "Sync is already running"
      });
    }

    const result = await syncAllStores();

    res.json({
      success: true,
      message: "Daraz sync completed",
      result
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error running Daraz sync",
      error: error.message
    });
  }
});

router.post("/run-store/:storeId", async (req, res) => {
  try {
    const lockState = getSyncLockState();

    if (lockState.syncInProgress) {
      return res.status(409).json({
        success: false,
        message: "Sync is already running"
      });
    }

    const result = await syncStoreById(req.params.storeId);

    res.json({
      success: true,
      message: "Store sync completed",
      result
    });
  } catch (error) {
    const statusCode = error.message === "Store not found" ? 404 : 500;

    res.status(statusCode).json({
      success: false,
      message: "Error syncing store",
      error: error.message
    });
  }
});

router.get("/orders", async (req, res) => {
  try {
    const { store_id, status, limit = 50 } = req.query;
    const query = {};

    if (store_id) {
      query.store_id = store_id;
    }

    if (status) {
      query.status = normalizeString(status).toLowerCase();
    }

    const orders = await CentralOrder.find(query)
      .populate("store_id", "name code deduct_stage")
      .sort({ order_created_at: -1, createdAt: -1 })
      .limit(Number(limit));

    res.json({
      success: true,
      count: orders.length,
      orders
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching synced orders",
      error: error.message
    });
  }
});

router.get("/order-items", async (req, res) => {
  try {
    const {
      store_id,
      seller_sku,
      processing_status,
      status,
      limit = 100
    } = req.query;

    const query = {};

    if (store_id) {
      query.store_id = store_id;
    }

    if (seller_sku) {
      query.seller_sku = normalizeString(seller_sku);
    }

    if (processing_status) {
      query.processing_status = normalizeString(processing_status).toLowerCase();
    }

    if (status) {
      query.status = normalizeString(status).toLowerCase();
    }

    const items = await CentralOrderItem.find(query)
      .populate("store_id", "name code")
      .populate("order_id", "external_order_id order_number status")
      .sort({ createdAt: -1 })
      .limit(Number(limit));

    res.json({
      success: true,
      count: items.length,
      items
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: "Error fetching synced order items",
      error: error.message
    });
  }
});

module.exports = router;