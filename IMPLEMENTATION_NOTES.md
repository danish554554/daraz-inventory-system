# Daraz Inventory Control - Professional UI/Sync Update

Implemented changes in this build:

- Product cards now support and display `image_url` via a reusable Flutter `ProductImageBox`.
- Daraz imported products now store `original_product_name`, `display_title`, and `image_url` when available from Daraz data.
- Urdu/non-Latin product names fall back to available English title fields; if Daraz does not provide English, the app uses a cleaned SKU-based display title instead of showing unreadable card text.
- Stock card plus/minus buttons were removed; product cards are now view-first and manual changes are handled through sheets/actions.
- Quick Adjustment and Restock dropdowns are expanded and ellipsized to avoid Flutter overflow warnings with long product names.
- Store screen top plus button was removed; the connect/create card remains the main call-to-action.
- Sync Center now has separate action states for Sync Orders, Sync Products, Store Sync, Refresh Status, Return Orders, and Failed Delivery.
- Sync Center now shows Daraz-style order cards with product title, product image, order number, store, status, and amount.
- Added backend endpoints for return orders, failed delivery records, and orders history summaries.
- Added 6-day failed-delivery collection deadline calculations from the logistic facility date when that date is available.
- Replaced Recent Activity-style dashboard area with Orders History cards, revenue, returns, failed delivery counts, and simple graph bars.
- Added low-stock threshold controls through backend alert setting endpoints and an in-app low-stock notification prompt after inventory load/sync.

Notes:

- Full phone push notifications require device notification permission plus a background push/local-notification service. This build stores thresholds and shows in-app alerts; native push can be added later with Firebase Cloud Messaging or flutter_local_notifications.
- English title quality depends on Daraz returning English title fields. If only Urdu is returned, the app now preserves the original title but uses a SKU-derived display title for professional card display.
- Failed-delivery facility dates depend on Daraz returning a usable status timestamp. If Daraz does not provide it, the backend falls back to available update timestamps.
