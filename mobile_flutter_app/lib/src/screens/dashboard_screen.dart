import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/formatters.dart';
import '../services/report_generator_service.dart';
import '../services/session_manager.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'returns_screen.dart';
import 'scanner_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _error;
  String _historyPeriod = 'today';
  Map<String, dynamic> _historySummary = <String, dynamic>{};

  List<StoreModel> _stores = <StoreModel>[];
  List<InventoryItem> _inventory = <InventoryItem>[];
  List<CentralOrder> _orders = <CentralOrder>[];
  List<CentralOrderItem> _orderItems = <CentralOrderItem>[];
  SyncStatus? _syncStatus;
  Timer? _refreshTimer;
  bool _isLiveSyncing = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      _triggerBackgroundLiveSync();
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_loading) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _triggerBackgroundLiveSync() async {
    if (_isLiveSyncing) return;
    if (mounted) setState(() => _isLiveSyncing = true);
    try {
      await ApiClient.instance.post('/daraz-sync/run-all');
      if (mounted) {
        await _load(silent: true);
      }
    } catch (_) {
      // Background sync errors shouldn't break UI
    } finally {
      if (mounted) setState(() => _isLiveSyncing = false);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    Future<dynamic> safe(Future<dynamic> request) async {
      try {
        return await request;
      } catch (_) {
        return null;
      }
    }

    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        safe(ApiClient.instance.get('/stores', bypassCache: true)),
        safe(ApiClient.instance.get('/central-inventory', bypassCache: true)),
        safe(
          ApiClient.instance.get(
            '/daraz-sync/order-items',
            queryParameters: <String, dynamic>{'limit': 40},
            bypassCache: true,
          ),
        ),
        safe(ApiClient.instance.get('/daraz-sync/status', bypassCache: true)),
        safe(
          ApiClient.instance.get(
            '/daraz-sync/orders-history',
            queryParameters: <String, dynamic>{
              'period': _historyPeriod,
              'limit': 20,
            },
            bypassCache: true,
          ),
        ),
        safe(
          ApiClient.instance.get(
            '/daraz-sync/orders',
            queryParameters: <String, dynamic>{'limit': 20},
            bypassCache: true,
          ),
        ),
      ]);

      final storesMap = JsonReaders.map(results[0]);
      final inventoryList = JsonReaders.list(results[1]);
      final itemsMap = JsonReaders.map(results[2]);
      final historyMap = JsonReaders.map(results[4]);
      final liveOrdersMap = JsonReaders.map(results[5]);

      if (storesMap.isEmpty && inventoryList.isEmpty) {
        throw ApiException(
          message:
              'Could not load the dashboard. Check the backend URL and session.',
        );
      }

      if (!mounted) return;

      setState(() {
        _stores = JsonReaders.list(storesMap['stores'])
            .map((item) => StoreModel.fromJson(JsonReaders.map(item)))
            .toList();

        _inventory = inventoryList
            .map((item) => InventoryItem.fromJson(JsonReaders.map(item)))
            .toList();

        final historyOrders = JsonReaders.list(historyMap['orders']);
        final liveOrders = JsonReaders.list(liveOrdersMap['orders']);
        final targetOrders = historyOrders.isNotEmpty ? historyOrders : liveOrders;
        _orders = targetOrders
            .map((item) => CentralOrder.fromJson(JsonReaders.map(item)))
            .where(
              (order) =>
                  order.statusCategory != 'cancelled' &&
                  !order.status.toLowerCase().contains('cancel'),
            )
            .toList();

        _historySummary = JsonReaders.map(historyMap['summary']);

        _orderItems = JsonReaders.list(itemsMap['items'])
            .map((item) => CentralOrderItem.fromJson(JsonReaders.map(item)))
            .toList();

        _syncStatus = results[3] == null
            ? SyncStatus(
                schedulerManagedBy: '',
                syncEngine: '',
                syncRunningNow: false,
              )
            : SyncStatus.fromJson(JsonReaders.map(results[3]));
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed to load dashboard.');
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  int get _totalStock =>
      _inventory.fold<int>(0, (sum, item) => sum + item.stock);

  int get _lowStockCount =>
      _inventory.where((item) => item.isLowStock).length;

  int get _connectedStores =>
      _stores.where((store) => store.tokenConnected).length;

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
                    child: EmptyState(
                      title: 'Dashboard unavailable',
                      message: _error!,
                      icon: Icons.error_outline,
                    ),
                  ),
                )
              : AppShell(
                  onRefresh: () async {
                    await _load();
                    await _triggerBackgroundLiveSync();
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _headerBar(),
                      const SizedBox(height: 14),
                      _heroProfitCard(),
                      const SizedBox(height: 14),
                      _quickActionsGrid(context),
                      const SizedBox(height: 18),
                      _sectionTitle('Key Metrics'),
                      const SizedBox(height: 10),
                      _metricsGrid(context),
                      const SizedBox(height: 18),
                      _sectionTitle(
                        'Low stock radar',
                        action: _lowStockItems.isEmpty ? null : 'View all',
                      ),
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
                      _sectionTitle(
                        'Recent Live Orders',
                        action: _orders.isEmpty ? null : '${_orders.length} orders',
                      ),
                      const SizedBox(height: 10),
                      if (_orders.isEmpty)
                        const EmptyState(
                          title: 'No orders yet',
                          message: 'Live orders from connected stores will appear here after sync.',
                          icon: Icons.receipt_long_outlined,
                        )
                      else
                        ..._orders.take(6).map(_dashboardOrderCard),
                    ],
                  ),
                ),
    );
  }

  Widget _headerBar() {
    final user = widget.sessionManager.username.isEmpty
        ? 'Admin'
        : widget.sessionManager.username.split('@').first;

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _isLiveSyncing ? AppTheme.warning : AppTheme.success,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: (_isLiveSyncing ? AppTheme.warning : AppTheme.success).withValues(alpha: 0.5),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isLiveSyncing
                        ? 'SYNCING LIVE...'
                        : (_syncStatus?.syncRunningNow == true
                            ? 'SCHEDULER RUNNING'
                            : 'DARAZ LIVE CONNECTED'),
                    style: TextStyle(
                      color: _isLiveSyncing ? AppTheme.warning : AppTheme.success,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                'Hello, $user 👋',
                style: TextStyle(
                  color: AppTheme.textPrimaryColor(context),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Scan Barcode / QR',
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (context) => const ScannerScreen()),
            );
            await _load(silent: true);
          },
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.cardColor(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor(context)),
            ),
            child: const Icon(Icons.qr_code_scanner_rounded, size: 18, color: AppTheme.primary),
          ),
        ),
        IconButton(
          tooltip: 'Share Daily Profit Report',
          onPressed: () async {
            await ReportGeneratorService.shareDailySummary(
              historySummary: _historySummary,
              orders: _orders,
              lowStockItems: _lowStockItems,
              period: _historyPeriod,
              connectedStoresCount: _connectedStores,
              totalStoresCount: _stores.length,
            );
          },
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.cardColor(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor(context)),
            ),
            child: const Icon(Icons.share_rounded, size: 18, color: AppTheme.success),
          ),
        ),
        InkWell(
          onTap: _isLiveSyncing ? null : () async {
            await _triggerBackgroundLiveSync();
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.primarySoft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.sync_rounded,
                  size: 16,
                  color: AppTheme.primary,
                ),
                SizedBox(width: 4),
                Text(
                  'Sync',
                  style: TextStyle(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _heroProfitCard() {
    final revenue = JsonReaders.number(
      _historySummary,
      'revenue',
      _orderItems.fold<double>(0, (sum, item) => sum + item.amount),
    );

    final totalCost = JsonReaders.number(
      _historySummary,
      'total_cost',
      _orderItems.fold<double>(0, (sum, item) => sum + item.totalCost),
    );

    final profit = JsonReaders.number(
      _historySummary,
      'profit',
      revenue - totalCost,
    );

    final profitMargin = JsonReaders.number(
      _historySummary,
      'profit_margin',
      revenue > 0 ? (((revenue - totalCost) / revenue) * 100) : 0,
    );

    final totalOrders = JsonReaders.integer(
      _historySummary,
      'total_orders',
      _orders.length,
    );

    final returns = JsonReaders.integer(
      _historySummary,
      'returns',
      _orderItems.where((item) => item.isReturn).length,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppTheme.heroGradient,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF334155)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.trending_up_rounded,
                      color: AppTheme.success,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'TRUE NET PROFIT (${_historyPeriod.toUpperCase()})',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  gradient: AppTheme.profitGradient,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: AppTheme.success.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  profitMargin > 0 ? '+${profitMargin.toStringAsFixed(1)}% Margin' : 'Margin --',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            profit > 0 ? 'PKR ${Formatters.money(profit)}' : 'PKR 0',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.0,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                _heroSubMetric('Gross Revenue', 'PKR ${Formatters.money(revenue)}'),
                Container(height: 24, width: 1, color: Colors.white.withValues(alpha: 0.15)),
                _heroSubMetric('Orders', Formatters.quantity(totalOrders)),
                Container(height: 24, width: 1, color: Colors.white.withValues(alpha: 0.15)),
                InkWell(
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (context) => const ReturnsAndFailedDeliveryScreen()),
                    );
                    await _load(silent: true);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: _heroSubMetric('Returns', '${Formatters.quantity(returns)} ➔'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                _periodFilterPill('today', 'Today'),
                const SizedBox(width: 8),
                _periodFilterPill('week', 'This Week'),
                const SizedBox(width: 8),
                _periodFilterPill('month', 'This Month'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _periodFilterPill(String value, String label) {
    final selected = _historyPeriod == value;
    return InkWell(
      onTap: () async {
        if (selected || _loading) return;
        setState(() => _historyPeriod = value);
        await _load();
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppTheme.primary : Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _heroSubMetric(String label, String value) {
    return Column(
      children: <Widget>[
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _quickActionsGrid(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionTitle('Quick Operations'),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: _quickActionTile(
                title: 'Pull Orders',
                subtitle: 'Live Sync',
                icon: Icons.cloud_download_rounded,
                color: AppTheme.primary,
                background: AppTheme.primarySoft,
                onTap: _isLiveSyncing ? null : () => _triggerBackgroundLiveSync(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _quickActionTile(
                title: 'Returns & Failed Delivery',
                subtitle: 'Hub Collection & Deadlines',
                icon: Icons.assignment_return_rounded,
                color: AppTheme.warning,
                background: AppTheme.warningSoft,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (context) => const ReturnsAndFailedDeliveryScreen()),
                  );
                  await _load(silent: true);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: _quickActionTile(
                title: 'Scan Barcode',
                subtitle: 'Warehouse Audit',
                icon: Icons.qr_code_scanner_rounded,
                color: AppTheme.accent,
                background: AppTheme.accentSoft,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (context) => const ScannerScreen()),
                  );
                  await _load(silent: true);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _quickActionTile(
                title: 'Daily Report',
                subtitle: 'Share WhatsApp',
                icon: Icons.share_rounded,
                color: AppTheme.success,
                background: AppTheme.successSoft,
                onTap: () async {
                  await ReportGeneratorService.shareDailySummary(
                    historySummary: _historySummary,
                    orders: _orders,
                    lowStockItems: _lowStockItems,
                    period: _historyPeriod,
                    connectedStoresCount: _connectedStores,
                    totalStoresCount: _stores.length,
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _quickActionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required Color background,
    required VoidCallback? onTap,
  }) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricsGrid(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 360 ? width - 32 : (width - 44) / 2;

    final profit = JsonReaders.number(_historySummary, 'profit');
    final profitMargin = JsonReaders.number(_historySummary, 'profit_margin');
    final profitAvailable = JsonReaders.boolean(_historySummary, 'profit_available', profit > 0);

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
            caption: _isLiveSyncing ? 'Syncing live...' : 'All synced',
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
            label: "Today's Sales",
            value: Formatters.quantity(
              JsonReaders.integer(
                _historySummary,
                'total_orders',
                _orders.length,
              ),
            ),
            icon: Icons.shopping_bag_outlined,
            caption: profitAvailable
                ? 'Rs. ${Formatters.money(profit)} profit (${profitMargin.toStringAsFixed(0)}% margin)'
                : '${Formatters.quantity(_orders.length)} valid orders',
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
          child: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              letterSpacing: -0.2,
            ),
          ),
        ),
        if (action != null)
          Text(
            action,
            style: const TextStyle(
              color: AppTheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
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
              background:
                  critical ? AppTheme.dangerSoft : AppTheme.warningSoft,
              size: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${item.sellerSku} · ${item.storeCode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${item.stock} left',
              style: TextStyle(
                color: critical ? AppTheme.danger : AppTheme.warning,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dashboardOrderCard(CentralOrder order) {
    final hasProfit = order.profit != null && order.profit! > 0;
    final isCancelled = order.status.toLowerCase().contains('cancel');
    final isReturned = order.status.toLowerCase().contains('return');
    final isFailed = order.status.toLowerCase().contains('failed');

    Color statusColor = AppTheme.success;
    Color statusSoft = AppTheme.successSoft;
    if (isCancelled || isReturned || isFailed) {
      statusColor = AppTheme.danger;
      statusSoft = AppTheme.dangerSoft;
    } else if (order.status.toLowerCase().contains('pending') || order.status.toLowerCase().contains('ready')) {
      statusColor = AppTheme.primary;
      statusSoft = AppTheme.primarySoft;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                ProductImageBox(
                  imageUrl: order.productImageUrl,
                  icon: Icons.shopping_bag_outlined,
                  size: 46,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        order.productTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.softGrey,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppTheme.border),
                            ),
                            child: Text(
                              order.storeName.isEmpty ? 'Daraz Store' : order.storeName,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '#${order.orderNumber.isEmpty ? order.externalOrderId : order.orderNumber}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(
                  label: order.status.isEmpty ? 'Order' : order.status.toUpperCase(),
                  color: statusColor,
                  softColor: statusSoft,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.softGrey,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    order.amount > 0 ? 'Sale: PKR ${Formatters.money(order.amount)}' : 'Sale: PKR --',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: hasProfit ? AppTheme.successSoft : AppTheme.softGrey,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: hasProfit ? AppTheme.success.withValues(alpha: 0.3) : AppTheme.border,
                      ),
                    ),
                    child: Text(
                      hasProfit ? 'Profit: +PKR ${Formatters.money(order.profit!)}' : 'Profit: Calc on COGS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: hasProfit ? AppTheme.success : AppTheme.textMuted,
                      ),
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
}
