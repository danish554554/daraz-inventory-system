
const express = require("express");
const crypto = require("crypto");

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
    const store = await Store.findById(req.params.id);

    if (!store) {
      return res.status(404).json({
        success: false,
        message: "Store not found"
      });
    }

    const token = await StoreToken.findOne({ store_id: store._id });
    const config = await StoreConnectionConfig.findOne({ store_id: store._id });

    if (!config) {
      return res.status(400).json({
        success: false,
        message: "Daraz configuration not saved for this store"
      });
    }

    if (!token) {
      config.auth_status = "not_connected";
      config.last_error_message = "Token not connected";
      config.last_validated_at = new Date();
      await config.save();

      return res.status(400).json({
        success: false,
        message: "Store token is not connected"
      });
    }

    const now = new Date();
    token.last_validated_at = now;

    if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) {
      token.token_status = "expired";
      token.last_error = "Token expired. Reconnect the store.";
      config.auth_status = "token_expired";
      config.last_error_message = token.last_error;
    } else if (!token.access_token) {
      token.token_status = "invalid";
      token.last_error = "Access token is missing";
      config.auth_status = "token_invalid";
      config.last_error_message = token.last_error;
    } else {
      token.token_status = token.token_status === "invalid" ? "active" : token.token_status || "active";
      token.last_error = "";
      config.auth_status = "token_active";
      config.last_error_message = "";
      config.last_validated_at = now;
      if (!config.last_connected_at) {
        config.last_connected_at = now;
      }
    }

    await Promise.all([token.save(), config.save()]);

    const result = await getSingleStoreHealth(store._id, 10);

    res.json({
      success: true,
      message: "Connection status refreshed",
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
      { new: true }
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
      { new: true }
    );

    if (!config) {
      await StoreConnectionConfig.create({
        store_id: store._id,
        platform: "daraz",
        connection_mode: "seller_managed_app",
        app_key: process.env.DARAZ_APP_KEY || "",
        app_secret: process.env.DARAZ_APP_SECRET || "",
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
SAVE DARAZ CONFIG
------------------------------------------------
*/
router.post("/:id/daraz-config", async (req, res) => {
  try {
    const storeId = req.params.id;

    const {
      app_key,
      app_secret,
      redirect_uri,
      api_region,
      seller_email,
      seller_account_name
    } = req.body;

    if (!app_key || !app_secret) {
      return res.status(400).json({
        success: false,
        message: "App key and app secret are required"
      });
    }

    const config = await StoreConnectionConfig.findOneAndUpdate(
      { store_id: storeId },
      {
        store_id: storeId,
        app_key: normalize(app_key),
        app_secret: normalize(app_secret),
        redirect_uri: normalize(redirect_uri),
        api_region: normalize(api_region || "pk"),
        seller_email: normalize(seller_email),
        seller_account_name: normalize(seller_account_name),
        auth_status: "config_saved",
        last_error_message: ""
      },
      {
        upsert: true,
        new: true
      }
    );

    res.json({
      success: true,
      message: "Daraz configuration saved",
      config
    });
  } catch (error) {
    console.error(error);

    res.status(500).json({
      success: false,
      message: "Failed to save Daraz config"
    });
  }
});

/*
------------------------------------------------
GENERATE DARAZ CONNECT URL
------------------------------------------------
*/
router.get("/:id/daraz-connect", async (req, res) => {
  try {
    const storeId = req.params.id;

    const config = await StoreConnectionConfig.findOne({
      store_id: storeId
    });

    if (!config) {
      return res.status(400).json({
        success: false,
        message: "Daraz config not saved"
      });
    }

    const state = crypto.randomBytes(16).toString("hex");

    config.auth_state = state;
    config.auth_status = "auth_url_generated";
    config.auth_url_last_generated_at = new Date();

    await config.save();

    const region = config.api_region || "pk";

    const baseUrls = {
      pk: "https://auth.daraz.pk/oauth/authorize",
      bd: "https://auth.daraz.com.bd/oauth/authorize",
      lk: "https://auth.daraz.lk/oauth/authorize",
      np: "https://auth.daraz.com.np/oauth/authorize",
      mm: "https://auth.shop.com.mm/oauth/authorize"
    };

    const authBase = baseUrls[region];

    const connectUrl =
      `${authBase}?` +
      `response_type=code&` +
      `client_id=${config.app_key}&` +
      `redirect_uri=${encodeURIComponent(config.redirect_uri)}&` +
      `state=${state}`;

    res.json({
      success: true,
      url: connectUrl
    });
  } catch (error) {
    console.error(error);

    res.status(500).json({
      success: false,
      message: "Failed to generate connect URL"
    });
  }
});

/*
------------------------------------------------
GET DARAZ CONFIG
------------------------------------------------
*/
router.get("/:id/daraz-config", async (req, res) => {
  try {
    const config = await StoreConnectionConfig.findOne({
      store_id: req.params.id
    }).lean();

    if (!config) {
      return res.json({
        success: true,
        config: null
      });
    }

    res.json({
      success: true,
      config: {
        ...config,
        app_secret: config.app_secret ? "********" : ""
      }
    });
  } catch (error) {
    console.error(error);

    res.status(500).json({
      success: false,
      message: "Failed to load config"
    });
  }
});

/*
------------------------------------------------
DISCONNECT DARAZ
------------------------------------------------
*/
router.delete("/:id/daraz-config", async (req, res) => {
  try {
    await Promise.all([
      StoreConnectionConfig.findOneAndUpdate(
        { store_id: req.params.id },
        {
          auth_status: "disconnected",
          last_error_message: "Disconnected by admin"
        }
      ),
      StoreToken.deleteOne({ store_id: req.params.id })
    ]);

    res.json({
      success: true,
      message: "Daraz connection removed"
    });
  } catch (error) {
    console.error(error);

    res.status(500).json({
      success: false,
      message: "Failed to disconnect"
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
