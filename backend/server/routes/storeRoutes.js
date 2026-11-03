
const express = require("express");

const Store = require("../models/Store");
const StoreToken = require("../models/StoreToken");
const StoreConnectionConfig = require("../models/StoreConnectionConfig");
const StoreSyncLog = require("../models/StoreSyncLog");
const CentralInventory = require("../models/CentralInventory");
const CentralOrder = require("../models/CentralOrder");
const CentralOrderItem = require("../models/CentralOrderItem");
const InventoryTransaction = require("../models/InventoryTransaction");
const ProductSkuMap = require("../models/ProductSkuMap");
const StockAdjustmentRequest = require("../models/StockAdjustmentRequest");
const StockReceipt = require("../models/StockReceipt");
const SyncIssue = require("../models/SyncIssue");
const { getStoresHealthData, getSingleStoreHealth } = require("../services/storeHealthService");
const { validateStoreToken } = require("../services/darazService");

const router = express.Router();

function normalize(value) {
  return String(value || "").trim();
}

/*
------------------------------------------------
HEALTH SUMMARY
------------------------------------------------
*/
router.get("/health-summary", async (req, res) => {
  try {
    const result = await getStoresHealthData();

    res.json({
      success: true,
      summary: result.summary
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({
      success: false,
      message: "Failed to load store health summary"
    });
  }
});

/*
------------------------------------------------
GET STORES
------------------------------------------------
*/
router.get("/", async (req, res) => {
  try {
    const result = await getStoresHealthData();

    res.json({
      success: true,
      stores: result.stores,
      summary: result.summary
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({
      success: false,
      message: "Failed to load stores"
    });
  }
});

/*
------------------------------------------------
STORE HEALTH DETAIL
------------------------------------------------
*/
router.get("/:id/health", async (req, res) => {
  try {
    const logLimit = Math.max(1, Math.min(Number(req.query.limit) || 10, 50));
    const result = await getSingleStoreHealth(req.params.id, logLimit);

    res.json({
      success: true,
      ...result
    });
  } catch (error) {
    const status = error.message === "Store not found" ? 404 : 500;
    console.error(error);
    res.status(status).json({
      success: false,
      message: error.message || "Failed to load store health detail"
    });
  }
});

/*
------------------------------------------------
RUN SINGLE STORE HEALTH CHECK
------------------------------------------------
*/
router.post("/:id/validate-connection", async (req, res) => {
  try {
    // This must contact Daraz.  A local token-presence check can incorrectly
    // report a healthy connection after a token has been revoked remotely.
    const validation = await validateStoreToken(req.params.id);
    const config = await StoreConnectionConfig.findOne({ store_id: validation.store._id });

    if (config) {
      config.auth_status = validation.ok ? "token_active" : "token_invalid";
      config.last_error_message = validation.ok ? "" : validation.message;
      config.last_validated_at = new Date();
      await config.save();
    }

    const result = await getSingleStoreHealth(validation.store._id, 10);
    return res.status(validation.ok ? 200 : 400).json({
      success: validation.ok,
      message: validation.message,
      token: validation.token_summary,
      ...result
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({
      success: false,
      message: "Failed to validate store connection"
    });
  }
});

/*
------------------------------------------------
CREATE STORE
------------------------------------------------
*/
router.post("/", async (req, res) => {
  try {
    const store = await Store.create(req.body);

    res.json({
      success: true,
      store
    });
  } catch (error) {
    console.error(error);

    res.status(500).json({
      success: false,
      message: "Failed to create store"
    });
  }
});

/*
------------------------------------------------
UPDATE STORE
------------------------------------------------
*/
router.put("/:id", async (req, res) => {
  try {
    const store = await Store.findByIdAndUpdate(
      req.params.id,
      req.body,
      { returnDocument: 'after' }
    );

    res.json({
      success: true,
      store
    });
  } catch (error) {
    console.error(error);

    res.status(500).json({
      success: false,
      message: "Failed to update store"
    });
  }
});


/*
------------------------------------------------
DISCONNECT STORE
------------------------------------------------
*/
router.post("/:id/disconnect", async (req, res) => {
  try {
    const store = await Store.findById(req.params.id);

    if (!store) {
      return res.status(404).json({
        success: false,
        message: "Store not found"
      });
    }

    await StoreToken.deleteOne({ store_id: store._id });

    const config = await StoreConnectionConfig.findOneAndUpdate(
      { store_id: store._id },
      {
        auth_status: "disconnected",
        auth_state: "",
        seller_email: "",
        seller_account_name: "",
        last_error_message: "Store disconnected by admin",
        last_validated_at: new Date()
      },
      { returnDocument: 'after' }
    );

    if (!config) {
      await StoreConnectionConfig.create({
        store_id: store._id,
        platform: "daraz",
        connection_mode: "seller_managed_app",
        app_key: process.env.DARAZ_APP_KEY || "",
        redirect_uri: process.env.DARAZ_OAUTH_REDIRECT_URI || "",
        api_region: normalize(store.country).toLowerCase() || "pk",
        auth_status: "disconnected",
        last_error_message: "Store disconnected by admin",
        last_validated_at: new Date()
      });
    }

    return res.json({
      success: true,
      message: "Store disconnected successfully"
    });
  } catch (error) {
    console.error(error);
    return res.status(500).json({
      success: false,
      message: "Failed to disconnect store"
    });
  }
});

/*
------------------------------------------------
DELETE STORE
------------------------------------------------
*/
router.delete("/:id", async (req, res) => {
  try {
    const store = await Store.findById(req.params.id);

    if (!store) {
      return res.status(404).json({
        success: false,
        message: "Store not found"
      });
    }

    const query = { store_id: store._id };

    await Promise.all([
      StoreToken.deleteMany(query),
      StoreConnectionConfig.deleteMany(query),
      StoreSyncLog.deleteMany(query),
      CentralInventory.deleteMany(query),
      CentralOrder.deleteMany(query),
      CentralOrderItem.deleteMany(query),
      InventoryTransaction.deleteMany(query),
      ProductSkuMap.deleteMany(query),
      StockAdjustmentRequest.deleteMany(query),
      StockReceipt.deleteMany(query),
      SyncIssue.deleteMany(query),
      Store.deleteOne({ _id: store._id })
    ]);

    return res.json({
      success: true,
      message: "Store deleted successfully"
    });
  } catch (error) {
    console.error(error);
    return res.status(500).json({
      success: false,
      message: "Failed to delete store"
    });
  }
});

/*
------------------------------------------------
GET STORE SYNC LOGS
------------------------------------------------
*/
router.get("/:id/sync-logs", async (req, res) => {
  try {
    const limit = Math.max(1, Math.min(Number(req.query.limit) || 20, 100));
    const logs = await StoreSyncLog.find({ store_id: req.params.id })
      .sort({ sync_started_at: -1, createdAt: -1 })
      .limit(limit)
      .lean();

    res.json({
      success: true,
      logs
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({
      success: false,
      message: "Failed to load sync logs"
    });
  }
});

module.exports = router;
