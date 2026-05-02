# Final implementation notes

## Implemented changes

1. **Merged products now behave like shared-stock master products.**
   - `InventoryMergeGroup` now stores `master_sku`, `stock`, `reserved_stock`, and `low_stock_limit`.
   - Merged product stock is no longer calculated by summing all linked SKU rows.
   - New merges start with `actual_stock` / `stock` from the request when provided, otherwise the primary selected row stock.

2. **Order deduction now deducts from the shared merged product stock.**
   - Order sync resolves the incoming Daraz `store_id + seller_sku` to a central SKU row.
   - If that SKU belongs to a merge group, stock is deducted from the merge group.
   - If the SKU is not imported/linked, the order item is marked `unmapped` instead of creating fake inventory during order sync.

3. **Restock, bulk restock, quick adjustment, and adjustment approvals now use the shared stock target.**
   - If the selected SKU belongs to a merge group, the merged product stock is updated.
   - If the selected SKU is not merged, the individual central inventory row is updated.

4. **Daraz product import no longer overwrites actual app stock.**
   - Product import updates title/image/Daraz IDs/SKU data only.
   - New imported SKUs start with internal stock `0`.
   - Existing internal stock remains untouched during import.

5. **Return and failed-delivery false positives reduced.**
   - Removed `updated_at` fallback from return claim date detection.
   - Removed `updated_at` fallback from failed-delivery facility date detection.
   - Failed-delivery scan/list no longer treats any logistic date alone as enough evidence.

6. **Returned/failed items do not auto-restore stock.**
   - Auto-restore is restricted to cancellation-style statuses.
   - Added backend endpoint to manually mark return/failed delivery item as received back:
     `POST /daraz-sync/order-items/:id/mark-received`.
   - Flutter return and failed-delivery cards now show a mark-received action.

7. **Order sync pagination added.**
   - Store sync now loops through Daraz order pages using `offset` and `limit`.

8. **Processing status enum fixed.**
   - `CentralOrder.processing_status` now supports `deducted` and `failed`.

9. **Flutter opacity issue fixed.**
   - All `.withOpacity(...)` usages were replaced with `.withValues(alpha: ...)`.
   - A compatibility extension was added in `app_theme.dart` for older Flutter SDKs.

10. **Android release shrinking configured.**
    - `minifyEnabled true`
    - `shrinkResources true`
    - ProGuard rules file added.

## Important usage note

For existing merged products created before this update, the app will use the first linked SKU stock as the starting merged stock fallback. You should review each merged product once and correct its actual stock using Quick Adjustment or Restock.

## Recommended build command for smaller APKs

```bash
cd mobile_flutter_app
flutter build apk --release --split-per-abi
```

