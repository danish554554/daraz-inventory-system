const express = require("express");
const router = express.Router();

const {
  adjustStock,
  getAdjustmentHistory
} = require("../controllers/stockController");

router.post("/adjust-stock", adjustStock);
router.get("/stock-adjustments", getAdjustmentHistory);

module.exports = router;