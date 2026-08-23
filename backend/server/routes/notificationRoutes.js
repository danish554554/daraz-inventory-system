const express = require("express");
const router = express.Router();
const notificationService = require("../services/notificationService");

// Register a mobile device FCM token
router.post("/register-token", async (req, res) => {
  try {
    const { token, platform, userId } = req.body;
    const result = await notificationService.registerToken({ token, platform, userId });
    return res.json({ success: true, token: result });
  } catch (error) {
    return res.status(400).json({ success: false, message: error.message });
  }
});

// Get alert & notification history
router.get("/history", async (req, res) => {
  try {
    const history = notificationService.getAlertHistory();
    return res.json({ success: true, alerts: history });
  } catch (error) {
    return res.status(500).json({ success: false, message: error.message });
  }
});

// Trigger an immediate scrap risk & low stock audit
router.post("/trigger-audit", async (req, res) => {
  try {
    const scrapAlerts = await notificationService.runScrapRiskAudit();
    const lowStockAlerts = await notificationService.runLowStockAudit();
    return res.json({
      success: true,
      scrap_alerts_count: scrapAlerts.length,
      low_stock_alerts_count: lowStockAlerts.length,
      alerts: [...scrapAlerts, ...lowStockAlerts]
    });
  } catch (error) {
    return res.status(500).json({ success: false, message: error.message });
  }
});

module.exports = router;
