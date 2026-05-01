class JsonReaders {
  static Map<String, dynamic> map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, value) => MapEntry(key.toString(), value));
    return <String, dynamic>{};
  }

  static List<dynamic> list(dynamic value) {
    if (value is List) return value;
    return <dynamic>[];
  }

  static String string(Map<String, dynamic> json, String key, [String fallback = '']) {
    final value = json[key];
    return value == null ? fallback : value.toString();
  }

  static int integer(Map<String, dynamic> json, String key, [int fallback = 0]) {
    final value = json[key];
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double number(Map<String, dynamic> json, String key, [double fallback = 0]) {
    final value = json[key];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static bool boolean(Map<String, dynamic> json, String key, [bool fallback = false]) {
    final value = json[key];
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (['true', '1', 'yes'].contains(normalized)) return true;
      if (['false', '0', 'no'].contains(normalized)) return false;
    }
    return fallback;
  }

  static DateTime? date(Map<String, dynamic> json, String key) {
    final raw = json[key]?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static String nestedId(dynamic value) {
    if (value is String) return value;
    if (value is Map<String, dynamic>) return value['_id']?.toString() ?? '';
    if (value is Map) return value['_id']?.toString() ?? '';
    return '';
  }

  static String nestedString(dynamic value, String key, [String fallback = '']) {
    if (value is Map<String, dynamic>) return value[key]?.toString() ?? fallback;
    if (value is Map) return value[key]?.toString() ?? fallback;
    return fallback;
  }
}

class StoreSummary {
  StoreSummary({
    required this.totalStores,
    required this.activeStores,
    required this.inactiveStores,
    required this.healthyStores,
    required this.attentionStores,
    required this.reconnectRequired,
    required this.setupRequired,
    required this.syncErrorStores,
    required this.connectedStores,
    required this.disconnectedStores,
    required this.expiringSoon,
  });

  final int totalStores;
  final int activeStores;
  final int inactiveStores;
  final int healthyStores;
  final int attentionStores;
  final int reconnectRequired;
  final int setupRequired;
  final int syncErrorStores;
  final int connectedStores;
  final int disconnectedStores;
  final int expiringSoon;

  factory StoreSummary.fromJson(Map<String, dynamic> json) {
    return StoreSummary(
      totalStores: JsonReaders.integer(json, 'total_stores'),
      activeStores: JsonReaders.integer(json, 'active_stores'),
      inactiveStores: JsonReaders.integer(json, 'inactive_stores'),
      healthyStores: JsonReaders.integer(json, 'healthy_stores'),
      attentionStores: JsonReaders.integer(json, 'attention_stores'),
      reconnectRequired: JsonReaders.integer(json, 'reconnect_required'),
      setupRequired: JsonReaders.integer(json, 'setup_required'),
      syncErrorStores: JsonReaders.integer(json, 'sync_error_stores'),
      connectedStores: JsonReaders.integer(json, 'connected_stores'),
      disconnectedStores: JsonReaders.integer(json, 'disconnected_stores'),
      expiringSoon: JsonReaders.integer(json, 'expiring_soon'),
    );
  }
}

class StoreModel {
  StoreModel({
    required this.id,
    required this.name,
    required this.code,
    required this.platform,
    required this.country,
    required this.status,
    required this.deductStage,
    required this.restoreOnCancel,
    required this.syncIntervalMinutes,
    required this.notes,
    required this.tokenConnected,
    required this.darazConnected,
    required this.tokenStatus,
    required this.healthState,
    required this.healthLabel,
    required this.healthReason,
    required this.account,
    required this.sellerId,
    required this.lastSyncMessage,
    required this.lastSyncFinishedAt,
    required this.lastSyncStartedAt,
    required this.lastSyncSuccess,
    required this.lastSyncDurationMs,
    required this.lastSyncFailedCount,
    required this.lastSyncWarningCount,
    required this.expiresAt,
    required this.lastError,
  });

  final String id;
  final String name;
  final String code;
  final String platform;
  final String country;
  final String status;
  final String deductStage;
  final bool restoreOnCancel;
  final int syncIntervalMinutes;
  final String notes;
  final bool tokenConnected;
  final bool darazConnected;
  final String tokenStatus;
  final String healthState;
  final String healthLabel;
  final String healthReason;
  final String account;
  final String sellerId;
  final String lastSyncMessage;
  final DateTime? lastSyncFinishedAt;
  final DateTime? lastSyncStartedAt;
  final bool? lastSyncSuccess;
  final int lastSyncDurationMs;
  final int lastSyncFailedCount;
  final int lastSyncWarningCount;
  final DateTime? expiresAt;
  final String lastError;

  bool get isActive => status == 'active';

  factory StoreModel.fromJson(Map<String, dynamic> json) {
    return StoreModel(
      id: JsonReaders.string(json, '_id'),
      name: JsonReaders.string(json, 'name'),
      code: JsonReaders.string(json, 'code'),
      platform: JsonReaders.string(json, 'platform', 'daraz'),
      country: JsonReaders.string(json, 'country', 'PK'),
      status: JsonReaders.string(json, 'status', 'active'),
      deductStage: JsonReaders.string(json, 'deduct_stage', 'ready_to_ship'),
      restoreOnCancel: JsonReaders.boolean(json, 'restore_on_cancel', true),
      syncIntervalMinutes: JsonReaders.integer(json, 'sync_interval_minutes', 5),
      notes: JsonReaders.string(json, 'notes'),
      tokenConnected: JsonReaders.boolean(json, 'token_connected'),
      darazConnected: JsonReaders.boolean(json, 'daraz_connected'),
      tokenStatus: JsonReaders.string(json, 'token_status', 'not_connected'),
      healthState: JsonReaders.string(json, 'health_state', 'unknown'),
      healthLabel: JsonReaders.string(json, 'health_label', 'Unknown'),
      healthReason: JsonReaders.string(json, 'health_reason'),
      account: JsonReaders.string(json, 'account'),
      sellerId: JsonReaders.string(json, 'seller_id'),
      lastSyncMessage: JsonReaders.string(json, 'last_sync_message'),
      lastSyncFinishedAt: JsonReaders.date(json, 'last_sync_finished_at'),
      lastSyncStartedAt: JsonReaders.date(json, 'last_sync_started_at'),
      lastSyncSuccess: json['last_sync_success'] is bool ? json['last_sync_success'] as bool : null,
      lastSyncDurationMs: JsonReaders.integer(json, 'last_sync_duration_ms'),
      lastSyncFailedCount: JsonReaders.integer(json, 'last_sync_failed_count'),
      lastSyncWarningCount: JsonReaders.integer(json, 'last_sync_warning_count'),
      expiresAt: JsonReaders.date(json, 'expires_at'),
      lastError: JsonReaders.string(json, 'last_error'),
    );
  }

  Map<String, dynamic> toUpdatePayload() {
    return <String, dynamic>{
      'name': name,
      'platform': platform,
      'country': country,
      'status': status,
      'deduct_stage': deductStage,
      'restore_on_cancel': restoreOnCancel,
      'sync_interval_minutes': syncIntervalMinutes,
      'notes': notes,
    };
  }

  StoreModel copyWith({
    String? name,
    String? country,
    String? status,
    String? deductStage,
    bool? restoreOnCancel,
    int? syncIntervalMinutes,
    String? notes,
  }) {
    return StoreModel(
      id: id,
      name: name ?? this.name,
      code: code,
      platform: platform,
      country: country ?? this.country,
      status: status ?? this.status,
      deductStage: deductStage ?? this.deductStage,
      restoreOnCancel: restoreOnCancel ?? this.restoreOnCancel,
      syncIntervalMinutes: syncIntervalMinutes ?? this.syncIntervalMinutes,
      notes: notes ?? this.notes,
      tokenConnected: tokenConnected,
      darazConnected: darazConnected,
      tokenStatus: tokenStatus,
      healthState: healthState,
      healthLabel: healthLabel,
      healthReason: healthReason,
      account: account,
      sellerId: sellerId,
      lastSyncMessage: lastSyncMessage,
      lastSyncFinishedAt: lastSyncFinishedAt,
      lastSyncStartedAt: lastSyncStartedAt,
      lastSyncSuccess: lastSyncSuccess,
      lastSyncDurationMs: lastSyncDurationMs,
      lastSyncFailedCount: lastSyncFailedCount,
      lastSyncWarningCount: lastSyncWarningCount,
      expiresAt: expiresAt,
      lastError: lastError,
    );
  }
}

class SyncLog {
  SyncLog({
    required this.id,
    required this.success,
    required this.summaryMessage,
    required this.syncStartedAt,
    required this.syncFinishedAt,
    required this.triggerSource,
    required this.durationMs,
    required this.processed,
    required this.deducted,
    required this.restored,
    required this.failed,
    required this.warnings,
  });

  final String id;
  final bool? success;
  final String summaryMessage;
  final DateTime? syncStartedAt;
  final DateTime? syncFinishedAt;
  final String triggerSource;
  final int durationMs;
  final int processed;
  final int deducted;
  final int restored;
  final int failed;
  final List<String> warnings;

  factory SyncLog.fromJson(Map<String, dynamic> json) {
    return SyncLog(
      id: JsonReaders.string(json, '_id'),
      success: json['success'] is bool ? json['success'] as bool : null,
      summaryMessage: JsonReaders.string(json, 'summary_message'),
      syncStartedAt: JsonReaders.date(json, 'sync_started_at'),
      syncFinishedAt: JsonReaders.date(json, 'sync_finished_at'),
      triggerSource: JsonReaders.string(json, 'trigger_source', 'manual'),
      durationMs: JsonReaders.integer(json, 'duration_ms'),
      processed: JsonReaders.integer(json, 'processed'),
      deducted: JsonReaders.integer(json, 'deducted'),
      restored: JsonReaders.integer(json, 'restored'),
      failed: JsonReaders.integer(json, 'failed'),
      warnings: JsonReaders.list(json['warnings']).map((e) => e.toString()).toList(),
    );
  }
}

class StoreHealthDetail {
  StoreHealthDetail({
    required this.store,
    required this.syncLogs,
  });

  final StoreModel store;
  final List<SyncLog> syncLogs;

  factory StoreHealthDetail.fromJson(Map<String, dynamic> json) {
    return StoreHealthDetail(
      store: StoreModel.fromJson(JsonReaders.map(json['store'])),
      syncLogs: JsonReaders.list(json['sync_logs'])
          .map((item) => SyncLog.fromJson(JsonReaders.map(item)))
          .toList(),
    );
  }
}

class InventoryItem {
  InventoryItem({
    required this.id,
    required this.inventoryId,
    required this.storeId,
    required this.storeName,
    required this.storeCode,
    required this.productName,
    required this.originalTitle,
    required this.displayTitle,
    required this.imageUrl,
    required this.sellerSku,
    required this.masterSku,
    required this.stock,
    required this.reservedStock,
    required this.availableStock,
    required this.lowStockLimit,
    required this.updatedAt,
  });

  final String id;
  final String inventoryId;
  final String storeId;
  final String storeName;
  final String storeCode;
  final String productName;
  final String originalTitle;
  final String displayTitle;
  final String imageUrl;
  final String sellerSku;
  final String masterSku;
  final int stock;
  final int reservedStock;
  final int availableStock;
  final int lowStockLimit;
  final DateTime? updatedAt;

  bool get isLowStock => stock <= lowStockLimit;
  bool get isCritical => stock <= 0 || stock <= 2;
  bool get isInStock => stock > lowStockLimit;
  String get title => displayTitle.isNotEmpty ? displayTitle : productName;

  factory InventoryItem.fromJson(Map<String, dynamic> json) {
    final productName = JsonReaders.string(json, 'product_name');
    final displayTitle = JsonReaders.string(json, 'display_title', productName);
    return InventoryItem(
      id: JsonReaders.string(json, '_id'),
      inventoryId: JsonReaders.string(json, 'inventory_id'),
      storeId: JsonReaders.string(json, 'store_id'),
      storeName: JsonReaders.string(json, 'store_name'),
      storeCode: JsonReaders.string(json, 'store_code'),
      productName: productName,
      originalTitle: JsonReaders.string(json, 'original_title', productName),
      displayTitle: displayTitle,
      imageUrl: JsonReaders.string(json, 'image_url'),
      sellerSku: JsonReaders.string(json, 'seller_sku'),
      masterSku: JsonReaders.string(json, 'master_sku'),
      stock: JsonReaders.integer(json, 'stock'),
      reservedStock: JsonReaders.integer(json, 'reserved_stock'),
      availableStock: JsonReaders.integer(json, 'available_stock'),
      lowStockLimit: JsonReaders.integer(json, 'low_stock_limit', 5),
      updatedAt: JsonReaders.date(json, 'updatedAt'),
    );
  }
}

class InventorySummary {
  InventorySummary({
    required this.totalProducts,
    required this.totalStock,
    required this.totalReservedStock,
    required this.totalAvailableStock,
    required this.lowStockProducts,
    required this.zeroStockProducts,
    required this.recentRestockEntries,
    required this.pendingAdjustments,
  });

  final int totalProducts;
  final int totalStock;
  final int totalReservedStock;
  final int totalAvailableStock;
  final int lowStockProducts;
  final int zeroStockProducts;
  final int recentRestockEntries;
  final int pendingAdjustments;

  factory InventorySummary.fromJson(Map<String, dynamic> json) {
    return InventorySummary(
      totalProducts: JsonReaders.integer(json, 'total_products'),
      totalStock: JsonReaders.integer(json, 'total_stock'),
      totalReservedStock: JsonReaders.integer(json, 'total_reserved_stock'),
      totalAvailableStock: JsonReaders.integer(json, 'total_available_stock'),
      lowStockProducts: JsonReaders.integer(json, 'low_stock_products'),
      zeroStockProducts: JsonReaders.integer(json, 'zero_stock_products'),
      recentRestockEntries: JsonReaders.integer(json, 'recent_restock_entries'),
      pendingAdjustments: JsonReaders.integer(json, 'pending_adjustments'),
    );
  }
}

class RestockEntry {
  RestockEntry({
    required this.id,
    required this.storeCode,
    required this.storeName,
    required this.productName,
    required this.sellerSku,
    required this.receiptType,
    required this.quantity,
    required this.unitCost,
    required this.totalCost,
    required this.supplierName,
    required this.invoiceNumber,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String storeCode;
  final String storeName;
  final String productName;
  final String sellerSku;
  final String receiptType;
  final int quantity;
  final double unitCost;
  final double totalCost;
  final String supplierName;
  final String invoiceNumber;
  final String note;
  final DateTime? createdAt;

  factory RestockEntry.fromJson(Map<String, dynamic> json) {
    return RestockEntry(
      id: JsonReaders.string(json, '_id'),
      storeCode: JsonReaders.string(json, 'store_code'),
      storeName: JsonReaders.string(json, 'store_name'),
      productName: JsonReaders.string(json, 'product_name'),
      sellerSku: JsonReaders.string(json, 'seller_sku'),
      receiptType: JsonReaders.string(json, 'receipt_type'),
      quantity: JsonReaders.integer(json, 'quantity'),
      unitCost: JsonReaders.number(json, 'unit_cost'),
      totalCost: JsonReaders.number(json, 'total_cost'),
      supplierName: JsonReaders.string(json, 'supplier_name'),
      invoiceNumber: JsonReaders.string(json, 'invoice_number'),
      note: JsonReaders.string(json, 'note'),
      createdAt: JsonReaders.date(json, 'createdAt'),
    );
  }
}

class AdjustmentRequestModel {
  AdjustmentRequestModel({
    required this.id,
    required this.inventoryId,
    required this.storeId,
    required this.storeName,
    required this.masterSku,
    required this.sellerSku,
    required this.productName,
    required this.currentStock,
    required this.adjustmentType,
    required this.quantity,
    required this.reasonCode,
    required this.note,
    required this.requestedBy,
    required this.status,
    required this.stockBefore,
    required this.stockAfter,
    required this.approvedBy,
    required this.approvedAt,
    required this.createdAt,
  });

  final String id;
  final String inventoryId;
  final String storeId;
  final String storeName;
  final String masterSku;
  final String sellerSku;
  final String productName;
  final int currentStock;
  final String adjustmentType;
  final int quantity;
  final String reasonCode;
  final String note;
  final String requestedBy;
  final String status;
  final int stockBefore;
  final int? stockAfter;
  final String approvedBy;
  final DateTime? approvedAt;
  final DateTime? createdAt;

  factory AdjustmentRequestModel.fromJson(Map<String, dynamic> json) {
    return AdjustmentRequestModel(
      id: JsonReaders.string(json, '_id'),
      inventoryId: JsonReaders.string(json, 'inventory_id'),
      storeId: JsonReaders.string(json, 'store_id'),
      storeName: JsonReaders.string(json, 'store_name'),
      masterSku: JsonReaders.string(json, 'master_sku'),
      sellerSku: JsonReaders.string(json, 'seller_sku'),
      productName: JsonReaders.string(json, 'product_name'),
      currentStock: JsonReaders.integer(json, 'current_stock'),
      adjustmentType: JsonReaders.string(json, 'adjustment_type'),
      quantity: JsonReaders.integer(json, 'quantity'),
      reasonCode: JsonReaders.string(json, 'reason_code'),
      note: JsonReaders.string(json, 'note'),
      requestedBy: JsonReaders.string(json, 'requested_by'),
      status: JsonReaders.string(json, 'status'),
      stockBefore: JsonReaders.integer(json, 'stock_before'),
      stockAfter: json['stock_after'] == null ? null : JsonReaders.integer(json, 'stock_after'),
      approvedBy: JsonReaders.string(json, 'approved_by'),
      approvedAt: JsonReaders.date(json, 'approved_at'),
      createdAt: JsonReaders.date(json, 'createdAt'),
    );
  }
}

class DailyReport {
  DailyReport({
    required this.date,
    required this.rows,
    required this.totals,
  });

  final DateTime? date;
  final List<DailyReportRow> rows;
  final DailyReportTotals totals;

  factory DailyReport.fromJson(Map<String, dynamic> json) {
    return DailyReport(
      date: JsonReaders.date(json, 'date'),
      rows: JsonReaders.list(json['rows'])
          .map((item) => DailyReportRow.fromJson(JsonReaders.map(item)))
          .toList(),
      totals: DailyReportTotals.fromJson(JsonReaders.map(json['totals'])),
    );
  }
}

class DailyReportRow {
  DailyReportRow({
    required this.productName,
    required this.masterSku,
    required this.openingStock,
    required this.soldQty,
    required this.restoredQty,
    required this.manualAddQty,
    required this.manualDeductQty,
    required this.closingStock,
  });

  final String productName;
  final String masterSku;
  final int openingStock;
  final int soldQty;
  final int restoredQty;
  final int manualAddQty;
  final int manualDeductQty;
  final int closingStock;

  factory DailyReportRow.fromJson(Map<String, dynamic> json) {
    return DailyReportRow(
      productName: JsonReaders.string(json, 'product_name'),
      masterSku: JsonReaders.string(json, 'master_sku'),
      openingStock: JsonReaders.integer(json, 'opening_stock'),
      soldQty: JsonReaders.integer(json, 'sold_qty'),
      restoredQty: JsonReaders.integer(json, 'restored_qty'),
      manualAddQty: JsonReaders.integer(json, 'manual_add_qty'),
      manualDeductQty: JsonReaders.integer(json, 'manual_deduct_qty'),
      closingStock: JsonReaders.integer(json, 'closing_stock'),
    );
  }
}

class DailyReportTotals {
  DailyReportTotals({
    required this.products,
    required this.openingStock,
    required this.soldQty,
    required this.restoredQty,
    required this.manualAddQty,
    required this.manualDeductQty,
    required this.closingStock,
  });

  final int products;
  final int openingStock;
  final int soldQty;
  final int restoredQty;
  final int manualAddQty;
  final int manualDeductQty;
  final int closingStock;

  factory DailyReportTotals.fromJson(Map<String, dynamic> json) {
    return DailyReportTotals(
      products: JsonReaders.integer(json, 'products'),
      openingStock: JsonReaders.integer(json, 'opening_stock'),
      soldQty: JsonReaders.integer(json, 'sold_qty'),
      restoredQty: JsonReaders.integer(json, 'restored_qty'),
      manualAddQty: JsonReaders.integer(json, 'manual_add_qty'),
      manualDeductQty: JsonReaders.integer(json, 'manual_deduct_qty'),
      closingStock: JsonReaders.integer(json, 'closing_stock'),
    );
  }
}

class PurchaseAnalytics {
  PurchaseAnalytics({
    required this.start,
    required this.end,
    required this.suppliers,
    required this.daily,
    required this.totals,
  });

  final DateTime? start;
  final DateTime? end;
  final List<SupplierAnalyticsRow> suppliers;
  final List<PurchaseDailyRow> daily;
  final PurchaseAnalyticsTotals totals;

  factory PurchaseAnalytics.fromJson(Map<String, dynamic> json) {
    return PurchaseAnalytics(
      start: JsonReaders.date(json, 'start'),
      end: JsonReaders.date(json, 'end'),
      suppliers: JsonReaders.list(json['suppliers'])
          .map((item) => SupplierAnalyticsRow.fromJson(JsonReaders.map(item)))
          .toList(),
      daily: JsonReaders.list(json['daily'])
          .map((item) => PurchaseDailyRow.fromJson(JsonReaders.map(item)))
          .toList(),
      totals: PurchaseAnalyticsTotals.fromJson(JsonReaders.map(json['totals'])),
    );
  }
}

class SupplierAnalyticsRow {
  SupplierAnalyticsRow({
    required this.supplierName,
    required this.entries,
    required this.totalQuantity,
    required this.totalCost,
    required this.avgUnitCost,
    required this.invoiceCount,
    required this.lastPurchaseAt,
  });

  final String supplierName;
  final int entries;
  final int totalQuantity;
  final double totalCost;
  final double avgUnitCost;
  final int invoiceCount;
  final DateTime? lastPurchaseAt;

  factory SupplierAnalyticsRow.fromJson(Map<String, dynamic> json) {
    return SupplierAnalyticsRow(
      supplierName: JsonReaders.string(json, 'supplier_name'),
      entries: JsonReaders.integer(json, 'entries'),
      totalQuantity: JsonReaders.integer(json, 'total_quantity'),
      totalCost: JsonReaders.number(json, 'total_cost'),
      avgUnitCost: JsonReaders.number(json, 'avg_unit_cost'),
      invoiceCount: JsonReaders.integer(json, 'invoice_count'),
      lastPurchaseAt: JsonReaders.date(json, 'last_purchase_at'),
    );
  }
}

class PurchaseDailyRow {
  PurchaseDailyRow({
    required this.date,
    required this.entries,
    required this.totalQuantity,
    required this.totalCost,
  });

  final String date;
  final int entries;
  final int totalQuantity;
  final double totalCost;

  factory PurchaseDailyRow.fromJson(Map<String, dynamic> json) {
    return PurchaseDailyRow(
      date: JsonReaders.string(json, 'date'),
      entries: JsonReaders.integer(json, 'entries'),
      totalQuantity: JsonReaders.integer(json, 'total_quantity'),
      totalCost: JsonReaders.number(json, 'total_cost'),
    );
  }
}

class PurchaseAnalyticsTotals {
  PurchaseAnalyticsTotals({
    required this.suppliers,
    required this.totalQuantity,
    required this.totalCost,
    required this.entries,
  });

  final int suppliers;
  final int totalQuantity;
  final double totalCost;
  final int entries;

  factory PurchaseAnalyticsTotals.fromJson(Map<String, dynamic> json) {
    return PurchaseAnalyticsTotals(
      suppliers: JsonReaders.integer(json, 'suppliers'),
      totalQuantity: JsonReaders.integer(json, 'total_quantity'),
      totalCost: JsonReaders.number(json, 'total_cost'),
      entries: JsonReaders.integer(json, 'entries'),
    );
  }
}

class InventoryTransactionModel {
  InventoryTransactionModel({
    required this.id,
    required this.storeId,
    required this.storeName,
    required this.storeCode,
    required this.sellerSku,
    required this.productName,
    required this.transactionType,
    required this.quantity,
    required this.stockBefore,
    required this.stockAfter,
    required this.note,
    required this.createdAt,
    required this.externalOrderId,
  });

  final String id;
  final String storeId;
  final String storeName;
  final String storeCode;
  final String sellerSku;
  final String productName;
  final String transactionType;
  final int quantity;
  final int stockBefore;
  final int stockAfter;
  final String note;
  final DateTime? createdAt;
  final String externalOrderId;

  factory InventoryTransactionModel.fromJson(Map<String, dynamic> json) {
    return InventoryTransactionModel(
      id: JsonReaders.string(json, '_id'),
      storeId: JsonReaders.string(json, 'store_id'),
      storeName: JsonReaders.string(json, 'store_name'),
      storeCode: JsonReaders.string(json, 'store_code'),
      sellerSku: JsonReaders.string(json, 'seller_sku'),
      productName: JsonReaders.string(json, 'product_name'),
      transactionType: JsonReaders.string(json, 'transaction_type'),
      quantity: JsonReaders.integer(json, 'quantity'),
      stockBefore: JsonReaders.integer(json, 'stock_before'),
      stockAfter: JsonReaders.integer(json, 'stock_after'),
      note: JsonReaders.string(json, 'note'),
      createdAt: JsonReaders.date(json, 'createdAt'),
      externalOrderId: JsonReaders.string(json, 'external_order_id'),
    );
  }
}

class CentralOrder {
  CentralOrder({
    required this.id,
    required this.storeId,
    required this.storeName,
    required this.storeCode,
    required this.externalOrderId,
    required this.orderNumber,
    required this.status,
    required this.processingStatus,
    required this.productTitle,
    required this.productImageUrl,
    required this.itemCount,
    required this.amount,
    required this.orderCreatedAt,
    required this.orderUpdatedAt,
  });

  final String id;
  final String storeId;
  final String storeName;
  final String storeCode;
  final String externalOrderId;
  final String orderNumber;
  final String status;
  final String processingStatus;
  final String productTitle;
  final String productImageUrl;
  final int itemCount;
  final double amount;
  final DateTime? orderCreatedAt;
  final DateTime? orderUpdatedAt;

  factory CentralOrder.fromJson(Map<String, dynamic> json) {
    final storeRaw = json['store_id'];
    return CentralOrder(
      id: JsonReaders.string(json, '_id'),
      storeId: JsonReaders.nestedId(storeRaw).isNotEmpty ? JsonReaders.nestedId(storeRaw) : JsonReaders.string(json, 'store_id'),
      storeName: JsonReaders.string(json, 'store_name', JsonReaders.nestedString(storeRaw, 'name', '-')),
      storeCode: JsonReaders.string(json, 'store_code', JsonReaders.nestedString(storeRaw, 'code', '-')),
      externalOrderId: JsonReaders.string(json, 'external_order_id'),
      orderNumber: JsonReaders.string(json, 'order_number'),
      status: JsonReaders.string(json, 'status'),
      processingStatus: JsonReaders.string(json, 'processing_status'),
      productTitle: JsonReaders.string(json, 'product_title', 'Order items'),
      productImageUrl: JsonReaders.string(json, 'product_image_url'),
      itemCount: JsonReaders.integer(json, 'item_count', 1),
      amount: JsonReaders.number(json, 'amount'),
      orderCreatedAt: JsonReaders.date(json, 'order_created_at'),
      orderUpdatedAt: JsonReaders.date(json, 'order_updated_at'),
    );
  }
}

class CentralOrderItem {
  CentralOrderItem({
    required this.id,
    required this.storeId,
    required this.storeName,
    required this.storeCode,
    required this.orderId,
    required this.orderNumber,
    required this.orderStatus,
    required this.externalOrderItemId,
    required this.sellerSku,
    required this.productName,
    required this.displayTitle,
    required this.imageUrl,
    required this.quantity,
    required this.unitPrice,
    required this.amount,
    required this.status,
    required this.returnStatus,
    required this.returnReason,
    required this.claimDate,
    required this.logisticFacilityAt,
    required this.collectionDeadlineAt,
    required this.daysLeftToCollect,
    required this.collectionStatus,
    required this.processingStatus,
    required this.stockDeducted,
    required this.stockRestored,
    required this.errorMessage,
    required this.createdAt,
  });

  final String id;
  final String storeId;
  final String storeName;
  final String storeCode;
  final String orderId;
  final String orderNumber;
  final String orderStatus;
  final String externalOrderItemId;
  final String sellerSku;
  final String productName;
  final String displayTitle;
  final String imageUrl;
  final int quantity;
  final double unitPrice;
  final double amount;
  final String status;
  final String returnStatus;
  final String returnReason;
  final DateTime? claimDate;
  final DateTime? logisticFacilityAt;
  final DateTime? collectionDeadlineAt;
  final int? daysLeftToCollect;
  final String collectionStatus;
  final String processingStatus;
  final bool stockDeducted;
  final bool stockRestored;
  final String errorMessage;
  final DateTime? createdAt;

  String get title => displayTitle.isNotEmpty ? displayTitle : (productName.isEmpty ? sellerSku : productName);
  bool get isReturn => status.toLowerCase().contains('return') || returnStatus.isNotEmpty || returnReason.isNotEmpty;
  bool get isFailedDelivery => status.toLowerCase().contains('failed') || status.toLowerCase().contains('undelivered') || collectionStatus == 'needs_collection';

  factory CentralOrderItem.fromJson(Map<String, dynamic> json) {
    final storeRaw = json['store_id'];
    final orderRaw = json['order_id'];
    final productName = JsonReaders.string(json, 'product_name');
    final quantity = JsonReaders.integer(json, 'quantity', 1);
    final unitPrice = JsonReaders.number(json, 'unit_price');
    return CentralOrderItem(
      id: JsonReaders.string(json, '_id'),
      storeId: JsonReaders.nestedId(storeRaw).isNotEmpty ? JsonReaders.nestedId(storeRaw) : JsonReaders.string(json, 'store_id'),
      storeName: JsonReaders.string(json, 'store_name', JsonReaders.nestedString(storeRaw, 'name', '-')),
      storeCode: JsonReaders.string(json, 'store_code', JsonReaders.nestedString(storeRaw, 'code', '-')),
      orderId: JsonReaders.nestedId(orderRaw).isNotEmpty ? JsonReaders.nestedId(orderRaw) : JsonReaders.string(json, 'order_id'),
      orderNumber: JsonReaders.string(json, 'order_number', JsonReaders.nestedString(orderRaw, 'order_number', '-')),
      orderStatus: JsonReaders.string(json, 'order_status', JsonReaders.nestedString(orderRaw, 'status', '-')),
      externalOrderItemId: JsonReaders.string(json, 'external_order_item_id'),
      sellerSku: JsonReaders.string(json, 'seller_sku'),
      productName: productName,
      displayTitle: JsonReaders.string(json, 'display_title', productName),
      imageUrl: JsonReaders.string(json, 'image_url'),
      quantity: quantity,
      unitPrice: unitPrice,
      amount: JsonReaders.number(json, 'amount', unitPrice * quantity),
      status: JsonReaders.string(json, 'status'),
      returnStatus: JsonReaders.string(json, 'return_status'),
      returnReason: JsonReaders.string(json, 'return_reason'),
      claimDate: JsonReaders.date(json, 'claim_date'),
      logisticFacilityAt: JsonReaders.date(json, 'logistic_facility_at'),
      collectionDeadlineAt: JsonReaders.date(json, 'collection_deadline_at'),
      daysLeftToCollect: json['days_left_to_collect'] == null ? null : JsonReaders.integer(json, 'days_left_to_collect'),
      collectionStatus: JsonReaders.string(json, 'collection_status'),
      processingStatus: JsonReaders.string(json, 'processing_status'),
      stockDeducted: JsonReaders.boolean(json, 'stock_deducted'),
      stockRestored: JsonReaders.boolean(json, 'stock_restored'),
      errorMessage: JsonReaders.string(json, 'error_message'),
      createdAt: JsonReaders.date(json, 'createdAt'),
    );
  }
}

class SyncStatus {
  SyncStatus({
    required this.schedulerManagedBy,
    required this.syncEngine,
    required this.syncRunningNow,
  });

  final String schedulerManagedBy;
  final String syncEngine;
  final bool syncRunningNow;

  factory SyncStatus.fromJson(Map<String, dynamic> json) {
    return SyncStatus(
      schedulerManagedBy: JsonReaders.string(json, 'scheduler_managed_by'),
      syncEngine: JsonReaders.string(json, 'sync_engine'),
      syncRunningNow: JsonReaders.boolean(json, 'sync_running_now'),
    );
  }
}
