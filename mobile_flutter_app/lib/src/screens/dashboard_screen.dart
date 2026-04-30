import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/formatters.dart';
import '../services/session_manager.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _error;

  List<StoreModel> _stores = <StoreModel>[];
  List<InventoryItem> _inventory = <InventoryItem>[];
  List<InventoryTransactionModel> _transactions =
      <InventoryTransactionModel>[];
  List<CentralOrder> _orders = <CentralOrder>[];
  List<CentralOrderItem> _orderItems = <CentralOrderItem>[];
  SyncStatus? _syncStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    Future<dynamic> safe(Future<dynamic> request) async {
      try {
        return await request;
      } catch (_) {
        return null;
      }
    }

    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        safe(ApiClient.instance.get('/stores')),
        safe(ApiClient.instance.get('/central-inventory')),
        safe(
          ApiClient.instance.get(
            '/central-inventory/transactions',
            queryParameters: <String, dynamic>{'limit': 30},
          ),
        ),
        safe(
          ApiClient.instance.get(
            '/daraz-sync/orders',
            queryParameters: <String, dynamic>{'limit': 20},
          ),
        ),
        safe(
          ApiClient.instance.get(
            '/daraz-sync/order-items',
            queryParameters: <String, dynamic>{'limit': 40},
          ),
        ),
        safe(ApiClient.instance.get('/daraz-sync/status')),
      ]);

      final storesMap = JsonReaders.map(results[0]);
      final inventoryList = JsonReaders.list(results[1]);
      final ordersMap = JsonReaders.map(results[3]);
      final itemsMap = JsonReaders.map(results[4]);

      if (storesMap.isEmpty && inventoryList.isEmpty) {
        throw ApiException(message: 'Could not load the dashboard. Check the backend URL and session.');
      }

      setState(() {
        _stores = JsonReaders.list(storesMap['stores'])
            .map((item) => StoreModel.fromJson(JsonReaders.map(item)))
            .toList();
        _inventory = inventoryList
            .map((item) => InventoryItem.fromJson(JsonReaders.map(item)))
            .toList();
        _transactions = JsonReaders.list(results[2])
            .map(
              (item) =>
                  InventoryTransactionModel.fromJson(JsonReaders.map(item)),
            )
            .toList();
        _orders = JsonReaders.list(ordersMap['orders'])
            .map((item) => CentralOrder.fromJson(JsonReaders.map(item)))
            .toList();
        _orderItems = JsonReaders.list(itemsMap['items'])
            .map((item) => CentralOrderItem.fromJson(JsonReaders.map(item)))
            .toList();
        _syncStatus = results[5] == null
            ? SyncStatus(
                schedulerManagedBy: '',
                syncEngine: '',
                syncRunningNow: false,
              )
            : SyncStatus.fromJson(JsonReaders.map(results[5]));
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Failed to load dashboard.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  int get _totalStock => _inventory.fold<int>(0, (sum, item) => sum + item.stock);

  int get _reservedStock =>
      _inventory.fold<int>(0, (sum, item) => sum + item.reservedStock);

  int get _availableStock =>
      _inventory.fold<int>(0, (sum, item) => sum + item.availableStock);

  int get _lowStockCount => _inventory.where((item) => item.isLowStock).length;

  int get _openOrders => _orders
      .where(
        (order) => !<String>{
          'canceled',
          'cancelled',
          'delivered',
        }.contains(order.status.toLowerCase()),
      )
      .length;

  int get _connectedStores =>
      _stores.where((store) => store.tokenConnected).length;

  int get _recentSales => _orderItems
      .where(
        (item) => <String>{
          'deducted',
          'processed',
        }.contains(item.processingStatus.toLowerCase()),
      )
      .fold<int>(0, (sum, item) => sum + item.quantity);

  List<_DashboardAlert> get _alerts {
    final alerts = <_DashboardAlert>[];

    final critical = _inventory.where((item) => item.isCritical).toList()
      ..sort((a, b) => a.stock.compareTo(b.stock));

    for (final item in critical.take(2)) {
      alerts.add(
        _DashboardAlert(
          type: 'Critical Low Stock',
          badge: 'Urgent',
          color: AppTheme.warning,
          softColor: AppTheme.warningSoft,
          message:
              '${item.productName} in ${item.storeName} has only ${item.stock} available.',
          meta: '${item.storeCode} • ${item.sellerSku}',
        ),
      );
    }

    final disconnected = _stores.where((store) => !store.tokenConnected).toList();

    for (final store in disconnected.take(2)) {
      alerts.add(
        _DashboardAlert(
          type: 'Store Disconnected',
          badge: 'Review',
          color: AppTheme.danger,
          softColor: AppTheme.dangerSoft,
          message:
              '${store.name} needs Daraz reconnection before live sync can continue.',
          meta: store.code,
        ),
      );
    }

    final lowStock =
        _inventory.where((item) => item.isLowStock && !item.isCritical).take(2);

    for (final item in lowStock) {
      alerts.add(
        _DashboardAlert(
          type: 'Low Stock Warning',
          badge: 'High',
          color: AppTheme.warning,
          softColor: AppTheme.warningSoft,
          message: '${item.productName} is approaching the low stock threshold.',
          meta: '${item.storeCode} • ${item.stock} left',
        ),
      );
    }

    return alerts;
  }


  List<_PurchaseCandidate> get _purchaseCandidates {
    final grouped = <String, List<InventoryItem>>{};
    for (final item in _inventory) {
      final key = item.masterSku.isNotEmpty ? item.masterSku : item.sellerSku;
      grouped.putIfAbsent(key, () => <InventoryItem>[]).add(item);
    }

    final candidates = grouped.entries.map((entry) {
      final rows = entry.value;
      final totalStock = rows.fold<int>(0, (sum, item) => sum + item.stock);
      final totalAvailable = rows.fold<int>(0, (sum, item) => sum + item.availableStock);
      final threshold = rows.fold<int>(0, (sum, item) => sum + item.lowStockLimit);
      final stores = rows.map((item) => item.storeCode).toSet().join(', ');
      final productName = rows.first.productName.isEmpty ? entry.key : rows.first.productName;
      return _PurchaseCandidate(
        sku: entry.key,
        productName: productName,
        stock: totalStock,
        available: totalAvailable,
        threshold: threshold,
        stores: stores,
      );
    }).where((item) => item.stock <= item.threshold).toList()
      ..sort((a, b) => a.stock.compareTo(b.stock));

    return candidates;
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _purchaseCandidates;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const AppLoader(label: 'Loading dashboard...')
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: EmptyState(
                      title: 'Dashboard unavailable',
                      message: _error!,
                      icon: Icons.error_outline,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      children: <Widget>[
                        Text(
                          _greeting(),
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Inventory Control',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1.0,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _todayStatusCard(candidates.length),
                        const SizedBox(height: 18),
                        const SectionHeader(title: 'Stock Summary'),
                        const SizedBox(height: 12),
                        _metricsGrid(context),
                        const SizedBox(height: 20),
                        SectionHeader(
                          title: 'Buy Again',
                          action: candidates.isEmpty
                              ? null
                              : StatusChip(
                                  label: '${candidates.length} low',
                                  color: AppTheme.danger,
                                  softColor: AppTheme.dangerSoft,
                                ),
                        ),
                        const SizedBox(height: 12),
                        if (candidates.isEmpty)
                          const EmptyState(
                            title: 'Stock is healthy',
                            message: 'No products are below their reorder limit.',
                            icon: Icons.check_circle_outline,
                          )
                        else
                          ...candidates.take(5).map(_buildPurchaseCard),
                        const SizedBox(height: 20),
                        const SectionHeader(title: 'Store Status'),
                        const SizedBox(height: 12),
                        _operationsGrid(context),
                        const SizedBox(height: 20),
                        const SectionHeader(title: 'Alerts'),
                        const SizedBox(height: 12),
                        if (_alerts.isEmpty)
                          const EmptyState(
                            title: 'No alerts',
                            message: 'All connected stores and stock levels look okay.',
                            icon: Icons.shield_outlined,
                          )
                        else
                          ..._alerts.map(_buildAlertCard),
                        const SizedBox(height: 20),
                        const SectionHeader(title: 'Recent Stock Movement'),
                        const SizedBox(height: 12),
                        if (_transactions.isEmpty)
                          const EmptyState(
                            title: 'No movement yet',
                            message: 'Orders, restocks, and adjustments will appear here.',
                            icon: Icons.receipt_long_outlined,
                          )
                        else
                          ..._transactions.take(5).map(_buildTransactionCard),
                      ],
                    ),
                  ),
      ),
    );
  }


  Widget _todayStatusCard(int lowProducts) {
    final syncRunning = _syncStatus?.syncRunningNow == true;
    final hasDisconnectedStores = _connectedStores < _stores.length;
    final message = syncRunning
        ? 'Sync is running now.'
        : hasDisconnectedStores
            ? 'Reconnect disconnected stores before relying on order sync.'
            : lowProducts > 0
                ? 'Review low stock products and purchase before overselling.'
                : 'Inventory is up to date.';

    return AppCard(
      borderColor: lowProducts > 0 || hasDisconnectedStores ? AppTheme.warningSoft : AppTheme.successSoft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: lowProducts > 0 || hasDisconnectedStores ? AppTheme.warningSoft : AppTheme.successSoft,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              lowProducts > 0 || hasDisconnectedStores ? Icons.priority_high_rounded : Icons.done_rounded,
              color: lowProducts > 0 || hasDisconnectedStores ? AppTheme.warning : AppTheme.success,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Today', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(message, style: const TextStyle(color: AppTheme.textMuted, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPurchaseCard(_PurchaseCandidate item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        borderColor: item.stock <= 0 ? AppTheme.dangerSoft : AppTheme.warningSoft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    item.productName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
                StatusChip(
                  label: item.stock <= 0 ? 'Out' : 'Low',
                  color: item.stock <= 0 ? AppTheme.danger : AppTheme.warning,
                  softColor: item.stock <= 0 ? AppTheme.dangerSoft : AppTheme.warningSoft,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(item.sku, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                _miniTag('Stock', '${item.stock}'),
                _miniTag('Available', '${item.available}'),
                _miniTag('Limit', '${item.threshold}'),
                _miniTag('Stores', item.stores),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricsGrid(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 380 ? width - 40 : (width - 56) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Total Stock',
            value: Formatters.quantity(_totalStock),
            icon: Icons.inventory_2_outlined,
            caption: '+${Formatters.quantity(_availableStock)} usable',
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Reserved',
            value: Formatters.quantity(_reservedStock),
            icon: Icons.bookmark_border_rounded,
            tint: AppTheme.warningSoft,
            iconColor: AppTheme.warning,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Available',
            value: Formatters.quantity(_availableStock),
            icon: Icons.verified_user_outlined,
            tint: AppTheme.successSoft,
            iconColor: AppTheme.success,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Low Stock',
            value: Formatters.quantity(_lowStockCount),
            icon: Icons.warning_amber_rounded,
            tint: AppTheme.dangerSoft,
            iconColor: AppTheme.danger,
          ),
        ),
      ],
    );
  }

  Widget _operationsGrid(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 380 ? width - 40 : (width - 56) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Open Orders',
            value: Formatters.quantity(_openOrders),
            icon: Icons.shopping_bag_outlined,
            tint: AppTheme.infoSoft,
            iconColor: AppTheme.info,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Sales Today',
            value: Formatters.quantity(_recentSales),
            icon: Icons.trending_up_rounded,
            tint: AppTheme.primarySoft,
            iconColor: AppTheme.primary,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Connected Stores',
            value: Formatters.quantity(_connectedStores),
            icon: Icons.storefront_outlined,
            tint: AppTheme.successSoft,
            iconColor: AppTheme.success,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Sync Engine',
            value: _syncStatus?.syncRunningNow == true ? 'Running' : 'Idle',
            icon: Icons.sync,
            tint: (_syncStatus?.syncRunningNow == true)
                ? AppTheme.infoSoft
                : AppTheme.primarySoft,
            iconColor: (_syncStatus?.syncRunningNow == true)
                ? AppTheme.info
                : AppTheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildAlertCard(_DashboardAlert alert) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        borderColor: alert.softColor,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: alert.softColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.warning_amber_rounded,
                color: alert.color,
                size: 18,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          alert.type,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      StatusChip(
                        label: alert.badge,
                        color: alert.color,
                        softColor: alert.softColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    alert.message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    alert.meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncActivityCard(StoreModel store) {
    final softColor =
        store.tokenConnected ? AppTheme.successSoft : AppTheme.dangerSoft;
    final color = store.tokenConnected ? AppTheme.success : AppTheme.danger;
    final label = store.tokenConnected ? 'Success' : 'Offline';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        store.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${store.code} • ${Formatters.dateTime(store.lastSyncFinishedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusChip(label: label, color: color, softColor: softColor),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                _miniTag('Failed', '${store.lastSyncFailedCount}'),
                _miniTag('Warnings', '${store.lastSyncWarningCount}'),
                _miniTag(
                  'Duration',
                  Formatters.durationMs(store.lastSyncDurationMs),
                ),
              ],
            ),
            if (store.healthReason.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                store.healthReason,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionCard(InventoryTransactionModel tx) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _transactionSoftColor(tx.transactionType),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _transactionIcon(tx.transactionType),
                color: _transactionColor(tx.transactionType),
                size: 18,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          tx.productName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Text(
                        '${tx.quantity}',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: _transactionColor(tx.transactionType),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${tx.storeCode} • ${tx.sellerSku} • ${tx.transactionType.replaceAll('_', ' ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Stock ${tx.stockBefore} → ${tx.stockAfter} • ${Formatters.dateTime(tx.createdAt)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniTag(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  Color _transactionColor(String type) {
    switch (type) {
      case 'manual_add':
      case 'cancel_restore':
        return AppTheme.success;
      case 'manual_deduct':
      case 'order_deduct':
        return AppTheme.danger;
      default:
        return AppTheme.primary;
    }
  }

  Color _transactionSoftColor(String type) {
    switch (type) {
      case 'manual_add':
      case 'cancel_restore':
        return AppTheme.successSoft;
      case 'manual_deduct':
      case 'order_deduct':
        return AppTheme.dangerSoft;
      default:
        return AppTheme.primarySoft;
    }
  }

  IconData _transactionIcon(String type) {
    switch (type) {
      case 'manual_add':
        return Icons.add_circle_outline;
      case 'manual_deduct':
        return Icons.remove_circle_outline;
      case 'order_deduct':
        return Icons.shopping_cart_checkout_outlined;
      case 'cancel_restore':
        return Icons.undo_outlined;
      default:
        return Icons.swap_horiz_rounded;
    }
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class _PurchaseCandidate {
  _PurchaseCandidate({
    required this.sku,
    required this.productName,
    required this.stock,
    required this.available,
    required this.threshold,
    required this.stores,
  });

  final String sku;
  final String productName;
  final int stock;
  final int available;
  final int threshold;
  final String stores;
}

class _DashboardAlert {
  _DashboardAlert({
    required this.type,
    required this.badge,
    required this.color,
    required this.softColor,
    required this.message,
    required this.meta,
  });

  final String type;
  final String badge;
  final Color color;
  final Color softColor;
  final String message;
  final String meta;
}