const express = require("express");
const protectAdmin = require("../middleware/authMiddleware");
const {
  createOauthConnectUrl,
  handleOauthCallback
} = require("../services/darazService");

const router = express.Router();

/*
  Admin route:
  generate Daraz connect URL for a store
*/
router.get("/:storeId/connect", protectAdmin, async (req, res) => {
  try {
    const result = await createOauthConnectUrl(req.params.storeId, {
      clientRedirectUri: req.query.client_redirect_uri,
      forceAuth: req.query.force_auth
    });

    return res.json({
      success: true,
      authorize_url: result.authorize_url,
      store: {
        _id: result.store._id,
        name: result.store.name,
        country: result.store.country
      }
    });
  } catch (error) {
    console.error("[Daraz OAuth Connect Error]", error);
    return res.status(500).json({
      success: false,
      message: error.message || "Failed to generate Daraz connect URL"
    });
  }
});

/*
  Public route:
  Daraz redirects back here after seller authorization
*/
router.get("/callback", async (req, res) => {
  try {
    const result = await handleOauthCallback(req.query);
    return res.redirect(result.redirect_url);
  } catch (error) {
    console.error("[Daraz OAuth Callback Error]", error);
    return res.status(500).send(error.message || "OAuth callback failed");
  }
});

module.exports = router;