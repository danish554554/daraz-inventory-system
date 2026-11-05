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
  console.log("🔥 DARAZ CALLBACK HIT:", req.query);

  try {
    const result = await handleOauthCallback(req.query);

    console.log("[Daraz OAuth Callback Result]", {
      ok: result.ok,
      redirect_url: result.redirect_url,
      store_id: result.store?._id ? String(result.store._id) : undefined,
      store_name: result.store?.name
    });

    const isCustomScheme = result.redirect_url && !result.redirect_url.startsWith("http://") && !result.redirect_url.startsWith("https://");

    if (isCustomScheme) {
      const storeName = result.store?.name || "Store";
      return res.send(`<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Daraz Store Connection</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f172a;
      color: #ffffff;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      padding: 20px;
      box-sizing: border-box;
      text-align: center;
    }
    .card {
      background: #1e293b;
      border-radius: 20px;
      padding: 32px 24px;
      max-width: 420px;
      width: 100%;
      box-shadow: 0 10px 25px rgba(0,0,0,0.5);
      border: 1px solid #334155;
    }
    .icon {
      font-size: 54px;
      margin-bottom: 16px;
    }
    h2 {
      margin: 0 0 8px 0;
      font-size: 22px;
      font-weight: 800;
    }
    p {
      color: #94a3b8;
      font-size: 14px;
      line-height: 1.5;
      margin: 0 0 24px 0;
    }
    .btn {
      display: block;
      background: #f97316;
      color: #ffffff;
      text-decoration: none;
      font-weight: 700;
      font-size: 16px;
      padding: 14px 20px;
      border-radius: 12px;
      box-shadow: 0 4px 12px rgba(249, 115, 22, 0.4);
    }
    .secondary-note {
      font-size: 12px;
      color: #64748b;
      margin-top: 16px;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">${result.ok ? "🎉" : "⚠️"}</div>
    <h2>${result.ok ? "Store Connected!" : "Connection Issue"}</h2>
    <p>${result.ok ? `<strong>${storeName}</strong> is now connected to your Daraz Inventory system.` : (result.message || "Could not complete authorization. Please try again.")}</p>
    <a href="${result.redirect_url}" class="btn">Open Daraz Inventory App</a>
    <div class="secondary-note">If your app doesn't open automatically, tap the button above or simply return to the app on your phone.</div>
  </div>
  <script>
    setTimeout(function() {
      try {
        window.location.href = ${JSON.stringify(result.redirect_url)};
      } catch (e) {}
    }, 400);
  </script>
</body>
</html>`);
    }

    return res.redirect(result.redirect_url);
  } catch (error) {
    console.error("[Daraz OAuth Callback Error]", error);
    return res.status(500).send(error.message || "OAuth callback failed");
  }
});

module.exports = router;
