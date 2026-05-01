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
  List<InventoryTransactionModel> _transactions = <InventoryTransactionModel>[];
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
            .map((item) => InventoryTransactionModel.fromJson(JsonReaders.map(item)))
            .toList();
        _orders = JsonReaders.list(ordersMap['orders'])
            .map((item) => CentralOrder.fromJson(JsonReaders.map(item)))
            .toList();
        _orderItems = JsonReaders.list(itemsMap['items'])
            .map((item) => CentralOrderItem.fromJson(JsonReaders.map(item)))
            .toList();
        _syncStatus = results[5] == null
            ? SyncStatus(schedulerManagedBy: '', syncEngine: '', syncRunningNow: false)
            : SyncStatus.fromJson(JsonReaders.map(results[5]));
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Failed to load dashboard.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalStock => _inventory.fold<int>(0, (sum, item) => sum + item.stock);
  int get _reservedStock => _inventory.fold<int>(0, (sum, item) => sum + item.reservedStock);
  int get _availableStock => _inventory.fold<int>(0, (sum, item) => sum + item.availableStock);
  int get _lowStockCount => _inventory.where((item) => item.isLowStock).length;
  int get _connectedStores => _stores.where((store) => store.tokenConnected).length;
  int get _recentSales => _orderItems
      .where((item) => <String>{'deducted', 'processed'}.contains(item.processingStatus.toLowerCase()))
      .fold<int>(0, (sum, item) => sum + item.quantity);

  List<InventoryItem> get _lowStockItems {
    final items = _inventory.where((item) => item.isLowStock).toList()
      ..sort((a, b) => a.stock.compareTo(b.stock));
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading dashboard...')
          : _error != null
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: EmptyState(title: 'Dashboard unavailable', message: _error!, icon: Icons.error_outline),
                  ),
                )
              : AppShell(
                  onRefresh: _load,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _heroCard(),
                      const SizedBox(height: 14),
                      _metricsGrid(context),
                      const SizedBox(height: 18),
                      _sectionTitle('Low stock alerts', action: _lowStockItems.isEmpty ? null : 'View all'),
                      const SizedBox(height: 10),
                      if (_lowStockItems.isEmpty)
                        const EmptyState(
                          title: 'Stock is healthy',
                          message: 'No products are below their reorder limit.',
                          icon: Icons.check_circle_outline,
                        )
                      else
                        ..._lowStockItems.take(4).map(_lowStockCard),
                      const SizedBox(height: 18),
                      _sectionTitle('Orders History', action: 'Today'),
                      const SizedBox(height: 10),
                      _ordersHistoryCard(),
                      const SizedBox(height: 10),
                      if (_orders.isEmpty)
                        const EmptyState(
                          title: 'No orders yet',
                          message: 'Today, weekly, monthly and custom order history appears here after sync.',
                          icon: Icons.receipt_long_outlined,
                        )
                      else
                        ..._orders.take(5).map(_dashboardOrderCard),
                    ],
                  ),
                ),
    );
  }

  Widget _heroCard() {
    final user = widget.sessionManager.username.isEmpty ? 'Admin' : widget.sessionManager.username.split('@').first;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(22),
        boxShadow: <BoxShadow>[
          BoxShadow(color: AppTheme.primary.withOpacity(0.18), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -26,
            top: -34,
            child: Container(
              height: 116,
              width: 116,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), shape: BoxShape.circle),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _greeting(),
                          style: TextStyle(color: Colors.white.withOpacity(0.82), fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          user,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                  CircleIconButton(
                    icon: Icons.refresh_rounded,
                    onPressed: _load,
                    background: Colors.white.withOpacity(0.17),
                    foreground: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 19,
                    backgroundColor: Colors.white.withOpacity(0.18),
                    child: const Text('AR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _heroPill(Icons.link_rounded, '$_connectedStores/${_stores.length} stores connected'),
                  _heroPill(Icons.schedule_rounded, 'Last sync · ${_lastSyncLabel()}'),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metricsGrid(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 360 ? width - 32 : (width - 44) / 2;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Total Products',
            value: Formatters.quantity(_inventory.length),
            icon: Icons.inventory_2_outlined,
            caption: '${Formatters.quantity(_totalStock)} units total',
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Active Stores',
            value: Formatters.quantity(_connectedStores),
            icon: Icons.storefront_outlined,
            caption: 'All synced',
            tint: AppTheme.infoSoft,
            iconColor: AppTheme.info,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Low Stock',
            value: Formatters.quantity(_lowStockCount),
            icon: Icons.warning_amber_rounded,
            caption: _lowStockCount > 0 ? '+ review today' : 'healthy',
            tint: AppTheme.warningSoft,
            iconColor: AppTheme.warning,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: "Today's Orders",
            value: Formatters.quantity(_recentSales),
            icon: Icons.shopping_bag_outlined,
            caption: '${Formatters.quantity(_orders.length)} open orders',
            tint: AppTheme.successSoft,
            iconColor: AppTheme.success,
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, {String? action}) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: -0.2)),
        ),
        if (action != null)
          Text(action, style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w900)),
      ],
    );
  }

  Widget _lowStockCard(InventoryItem item) {
    final critical = item.isCritical;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            MiniIcon(
              icon: Icons.inventory_outlined,
              color: critical ? AppTheme.danger : AppTheme.warning,
              background: critical ? AppTheme.dangerSoft : AppTheme.warningSoft,
              size: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text('${item.sellerSku} · ${item.storeCode}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${item.stock} left',
              style: TextStyle(color: critical ? AppTheme.danger : AppTheme.warning, fontSize: 12, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }


  Widget _ordersHistoryCard() {
    final revenue = _orderItems.fold<double>(0, (sum, item) => sum + item.amount);
    final returns = _orderItems.where((item) => item.isReturn).length;
    final failed = _orderItems.where((item) => item.isFailedDelivery).length;
    final maxOrders = _orders.isEmpty ? 1 : _orders.length;
    final ordersFraction = (_orders.length / maxOrders).clamp(0.05, 1.0).toDouble();
    final revenueFraction = revenue <= 0 ? 0.05 : 1.0;

    return AppCard(
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: _historyMetric('Orders', Formatters.quantity(_orders.length))),
              Expanded(child: _historyMetric('Revenue', 'Rs. ${Formatters.money(revenue)}')),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(child: _historyMetric('Returns', Formatters.quantity(returns))),
              Expanded(child: _historyMetric('Failed Delivery', Formatters.quantity(failed))),
            ],
          ),
          const SizedBox(height: 12),
          _miniBar('Orders graph', ordersFraction),
          const SizedBox(height: 8),
          _miniBar('Revenue graph', revenueFraction),
        ],
      ),
    );
  }

  Widget _historyMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w800)),
      ],
    );
  }

  Widget _miniBar(String label, double value) {
    return Row(
      children: <Widget>[
        SizedBox(width: 96, child: Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w800))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 8,
              backgroundColor: AppTheme.background,
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
            ),
          ),
        ),
      ],
    );
  }

  Widget _dashboardOrderCard(CentralOrder order) {
    final color = order.status.toLowerCase().contains('cancel') ? AppTheme.danger : AppTheme.success;
    final soft = order.status.toLowerCase().contains('cancel') ? AppTheme.dangerSoft : AppTheme.successSoft;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            ProductImageBox(imageUrl: order.productImageUrl, icon: Icons.shopping_bag_outlined, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(order.productTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text('Order ${order.orderNumber.isEmpty ? order.externalOrderId : order.orderNumber} · ${order.storeName} · Rs. ${Formatters.money(order.amount)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusChip(label: order.status.isEmpty ? 'Order' : order.status, color: color, softColor: soft),
          ],
        ),
      ),
    );
  }

  Widget _activityCard(InventoryTransactionModel tx) {
    final color = _transactionColor(tx.transactionType);
    final soft = _transactionSoftColor(tx.transactionType);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            MiniIcon(icon: _transactionIcon(tx.transactionType), color: color, background: soft, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(tx.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text('${tx.storeCode} · Stock ${tx.stockBefore} → ${tx.stockAfter}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(Formatters.dateTime(tx.createdAt), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  Widget _heroPill(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: Colors.white, size: 13),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Welcome back';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _lastSyncLabel() {
    final dates = _stores.map((store) => store.lastSyncFinishedAt).whereType<DateTime>().toList()
      ..sort((a, b) => b.compareTo(a));
    if (dates.isEmpty) return _syncStatus?.syncRunningNow == true ? 'running' : 'not synced';
    return Formatters.dateTime(dates.first);
  }

  Color _transactionColor(String type) {
    switch (type.toLowerCase()) {
      case 'sale':
      case 'order_deduct':
      case 'deducted':
        return AppTheme.danger;
      case 'restock':
      case 'manual_add':
      case 'restore':
        return AppTheme.success;
      default:
        return AppTheme.primary;
    }
  }

  Color _transactionSoftColor(String type) {
    final color = _transactionColor(type);
    if (color == AppTheme.danger) return AppTheme.dangerSoft;
    if (color == AppTheme.success) return AppTheme.successSoft;
    return AppTheme.primarySoft;
  }

  IconData _transactionIcon(String type) {
    switch (type.toLowerCase()) {
      case 'sale':
      case 'order_deduct':
      case 'deducted':
        return Icons.shopping_bag_outlined;
      case 'restock':
      case 'manual_add':
        return Icons.add_box_outlined;
      case 'restore':
        return Icons.restart_alt_rounded;
      default:
        return Icons.swap_vert_rounded;
    }
  }
}
