import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/formatters.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> with WidgetsBindingObserver {
  bool _loading = true;
  String? _workingAction;
  String? _error;
  String _storeFilter = 'all';
  String _itemFilter = 'all';
  String _historyPeriod = 'month';
  DateTime? _historyStart;
  DateTime? _historyEnd;

  SyncStatus? _status;
  List<StoreModel> _stores = <StoreModel>[];
  List<CentralOrder> _orders = <CentralOrder>[];
  List<CentralOrderItem> _orderItems = <CentralOrderItem>[];
  List<CentralOrderItem> _returns = <CentralOrderItem>[];
  List<CentralOrderItem> _failedDeliveries = <CentralOrderItem>[];
  List<CentralOrder> _cancelledOrders = <CentralOrder>[];
  List<CentralOrderItem> _collectionAlerts = <CentralOrderItem>[];
  Map<String, dynamic> _historySummary = <String, dynamic>{};
  List<Map<String, dynamic>> _historySeries = <Map<String, dynamic>>[];
  DateTime? _lastAutoRefreshAt;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_loading && !_busy) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed || _busy || _loading) return;

    final now = DateTime.now();
    final lastRefreshAt = _lastAutoRefreshAt;
    if (lastRefreshAt != null && now.difference(lastRefreshAt) < const Duration(seconds: 15)) {
      return;
    }

    _lastAutoRefreshAt = now;
    _load(silent: true);
  }

  Map<String, dynamic> _historyQueryParameters() {
    final params = <String, dynamic>{'period': _historyPeriod};
    if (_historyStart != null) params['start'] = _historyStart!.toIso8601String();
    if (_historyEnd != null) params['end'] = _historyEnd!.toIso8601String();
    return params;
  }

  String get _historyLabel {
    switch (_historyPeriod) {
      case 'week':
        return _historyStart == null ? 'WEEK' : 'WEEK · ${Formatters.date(_historyStart)}';
      case 'month':
        return _historyStart == null ? 'MONTH' : 'MONTH · ${_historyStart!.year}-${_historyStart!.month.toString().padLeft(2, '0')}';
      default:
        return 'TODAY';
    }
  }

  Future<void> _selectHistoryPeriod(String value) async {
    if (_busy) return;

    if (value == 'today') {
      setState(() {
        _historyPeriod = 'today';
        _historyStart = null;
        _historyEnd = null;
      });
      await _load(silent: true);
      return;
    }

    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _historyStart ?? now,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1),
      helpText: value == 'week' ? 'Select any date in the week' : 'Select any date in the month',
    );
    if (picked == null) return;

    DateTime start;
    DateTime end;
    if (value == 'week') {
      start = DateTime(picked.year, picked.month, picked.day).subtract(Duration(days: picked.weekday - 1));
      end = start.add(const Duration(days: 6));
    } else {
      start = DateTime(picked.year, picked.month, 1);
      end = DateTime(picked.year, picked.month + 1, 0);
    }

    setState(() {
      _historyPeriod = value;
      _historyStart = start;
      _historyEnd = end;
    });
    await _load(silent: true);
  }

  bool get _historyRevenueAvailable => JsonReaders.boolean(_historySummary, 'revenue_available', JsonReaders.number(_historySummary, 'revenue') > 0);

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final historyParams = _historyQueryParameters();
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        ApiClient.instance.get('/daraz-sync/status', bypassCache: true),
        ApiClient.instance.get('/stores', bypassCache: true),
        ApiClient.instance.get('/daraz-sync/orders', queryParameters: <String, dynamic>{'limit': 50}, bypassCache: true),
        ApiClient.instance.get('/daraz-sync/order-items', queryParameters: <String, dynamic>{'limit': 80}, bypassCache: true),
        ApiClient.instance.get('/daraz-sync/return-orders', queryParameters: <String, dynamic>{'limit': 60, ...historyParams}, bypassCache: true),
        ApiClient.instance.get('/daraz-sync/failed-delivery', queryParameters: <String, dynamic>{'limit': 60, ...historyParams}, bypassCache: true),
        ApiClient.instance.get('/daraz-sync/orders-history', queryParameters: <String, dynamic>{'limit': 80, ...historyParams}, bypassCache: true),
        ApiClient.instance.get('/daraz-sync/cancelled-orders', queryParameters: <String, dynamic>{'limit': 40, ...historyParams}, bypassCache: true),
        ApiClient.instance.get('/daraz-sync/collection-alerts', queryParameters: <String, dynamic>{'limit': 20}, bypassCache: true),
      ]);

      final storesMap = JsonReaders.map(results[1]);
      if (JsonReaders.map(results[0]).isEmpty && storesMap.isEmpty) {
        throw ApiException(message: 'Could not load the sync center. Check the backend URL and session.');
      }

      final ordersMap = JsonReaders.map(results[2]);
      final itemsMap = JsonReaders.map(results[3]);
      final returnsMap = JsonReaders.map(results[4]);
      final failedMap = JsonReaders.map(results[5]);
      final historyMap = JsonReaders.map(results[6]);
      final cancelledMap = JsonReaders.map(results[7]);
      final alertsMap = JsonReaders.map(results[8]);

      if (!mounted) return;
      setState(() {
        _status = SyncStatus.fromJson(JsonReaders.map(results[0]));
        _stores = JsonReaders.list(storesMap['stores']).map((item) => StoreModel.fromJson(JsonReaders.map(item))).toList();
        _orders = JsonReaders.list(ordersMap['orders']).map((item) => CentralOrder.fromJson(JsonReaders.map(item))).toList();
        _orderItems = JsonReaders.list(itemsMap['items']).map((item) => CentralOrderItem.fromJson(JsonReaders.map(item))).toList();
        _returns = JsonReaders.list(returnsMap['returns']).map((item) => CentralOrderItem.fromJson(JsonReaders.map(item))).toList();
        _failedDeliveries = JsonReaders.list(failedMap['failed_deliveries']).map((item) => CentralOrderItem.fromJson(JsonReaders.map(item))).toList();
        _historySummary = JsonReaders.map(historyMap['summary']);
        _historySeries = JsonReaders.list(historyMap['series']).map((item) => JsonReaders.map(item)).toList();
        _cancelledOrders = JsonReaders.list(cancelledMap['cancelled_orders']).map((item) => CentralOrder.fromJson(JsonReaders.map(item))).toList();
        _collectionAlerts = JsonReaders.list(alertsMap['alerts']).map((item) => CentralOrderItem.fromJson(JsonReaders.map(item))).toList();
        _error = null;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'Failed to load sync center: $error');
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  List<CentralOrder> get _visibleOrders {
    final base = _storeFilter == 'all' ? List<CentralOrder>.from(_orders) : _orders.where((order) => order.storeId == _storeFilter).toList();
    final filtered = base.where((order) {
      final status = order.status.toLowerCase();
      return order.statusCategory != 'cancelled' && !status.contains('cancel');
    }).toList();
    filtered.sort((a, b) {
      final aDate = a.orderCreatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = b.orderCreatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return filtered;
  }

  List<CentralOrderItem> get _visibleItems {
    var items = _storeFilter == 'all' ? List<CentralOrderItem>.from(_orderItems) : _orderItems.where((item) => item.storeId == _storeFilter).toList();

    if (_itemFilter != 'all') {
      items = items.where((item) {
        switch (_itemFilter) {
          case 'errors':
            return item.errorMessage.trim().isNotEmpty;
          case 'deducted':
            return item.stockDeducted;
          case 'restored':
            return item.stockRestored;
          case 'pending':
            return !item.stockDeducted && !item.stockRestored && item.errorMessage.trim().isEmpty;
          default:
            return true;
        }
      }).toList();
    }

    items.sort((a, b) {
      final aDate = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return items;
  }

  List<CentralOrderItem> get _visibleReturns {
    final rows = _storeFilter == 'all' ? List<CentralOrderItem>.from(_returns) : _returns.where((item) => item.storeId == _storeFilter).toList();
    rows.sort((a, b) => (b.claimDate ?? b.createdAt ?? DateTime(0)).compareTo(a.claimDate ?? a.createdAt ?? DateTime(0)));
    return rows;
  }

  List<CentralOrderItem> get _visibleFailedDeliveries {
    final rows = _storeFilter == 'all' ? List<CentralOrderItem>.from(_failedDeliveries) : _failedDeliveries.where((item) => item.storeId == _storeFilter).toList();
    rows.sort((a, b) => (b.hubArrivedAt ?? b.logisticFacilityAt ?? b.createdAt ?? DateTime(0)).compareTo(a.hubArrivedAt ?? a.logisticFacilityAt ?? a.createdAt ?? DateTime(0)));
    return rows;
  }

  List<CentralOrder> get _visibleCancelledOrders {
    final rows = _storeFilter == 'all' ? List<CentralOrder>.from(_cancelledOrders) : _cancelledOrders.where((order) => order.storeId == _storeFilter).toList();
    rows.sort((a, b) => (b.orderUpdatedAt ?? b.orderCreatedAt ?? DateTime(0)).compareTo(a.orderUpdatedAt ?? a.orderCreatedAt ?? DateTime(0)));
    return rows;
  }

  List<CentralOrderItem> get _visibleCollectionAlerts {
    final rows = _storeFilter == 'all' ? List<CentralOrderItem>.from(_collectionAlerts) : _collectionAlerts.where((item) => item.storeId == _storeFilter).toList();
    rows.sort((a, b) => (a.collectionDeadlineAt ?? DateTime(9999)).compareTo(b.collectionDeadlineAt ?? DateTime(9999)));
    return rows;
  }

  Future<void> _runAction(String actionKey, Future<void> Function() action) async {
    if (_workingAction != null) return;
    setState(() => _workingAction = actionKey);
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      if (mounted) showAppSnackBar(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _workingAction = null);
    }
  }

  Future<void> _runAllSync() async {
    await _runAction('orders', () async {
      final response = await ApiClient.instance.post('/daraz-sync/run-all') as Map<String, dynamic>;
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, response['message']?.toString() ?? 'Order sync completed.');
    });
  }

  Future<void> _runStoreSync(StoreModel store) async {
    await _runAction('store', () async {
      final response = await ApiClient.instance.post('/daraz-sync/run-store/${store.id}') as Map<String, dynamic>;
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, response['message']?.toString() ?? '${store.name} synced.');
    });
  }

  Future<void> _importProductsForStore(StoreModel store) async {
    await _runAction('products', () async {
      await ApiClient.instance.post('/daraz-sync/import-products/${store.id}');
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Active Daraz products imported successfully.');
    });
  }

  Future<void> _refreshStatus() async {
    await _runAction('status', () async {
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Sync status refreshed.');
    });
  }

  Future<void> _refreshReturns() async {
    await _runAction('returns', () async {
      await ApiClient.instance.post('/daraz-sync/scan-returns');
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Return orders scanned from all stores.');
    });
  }

  Future<void> _refreshFailedDelivery() async {
    await _runAction('failed', () async {
      await ApiClient.instance.post('/daraz-sync/scan-failed-delivery');
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Failed delivery records scanned from all stores.');
    });
  }

  Future<void> _markItemReceived(CentralOrderItem item) async {
    await _runAction('receive-${item.id}', () async {
      await ApiClient.instance.post(
        '/daraz-sync/order-items/${item.id}/mark-received',
        body: <String, dynamic>{'actor': 'admin'},
      );
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Item marked as received back.');
    });
  }

  StoreModel? get _selectedStore {
    if (_stores.isEmpty) return null;
    if (_storeFilter == 'all') return _stores.first;
    for (final store in _stores) {
      if (store.id == _storeFilter) return store;
    }
    return null;
  }

  bool get _busy => _workingAction != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading sync center...')
          : _error != null
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: EmptyState(title: 'Sync center unavailable', message: _error!, icon: Icons.sync_problem_outlined),
                  ),
                )
              : AppShell(
                  onRefresh: () => _load(silent: true),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SectionHeader(
                        title: 'Sync Center',
                        subtitle: 'Orders, products, returns and failed delivery control',
                        action: StatusChip(
                          label: _status?.syncRunningNow == true ? 'Running' : 'Healthy',
                          color: _status?.syncRunningNow == true ? AppTheme.info : AppTheme.success,
                          softColor: _status?.syncRunningNow == true ? AppTheme.infoSoft : AppTheme.successSoft,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _storeSelector(),
                      const SizedBox(height: 14),
                      _actionGrid(context),
                      const SizedBox(height: 14),
                      _progressCard(),
                      if (_visibleCollectionAlerts.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 18),
                        _sectionTitle('Collection Alerts', action: '${_visibleCollectionAlerts.length} urgent'),
                        const SizedBox(height: 10),
                        ..._visibleCollectionAlerts.take(4).map(_buildCollectionAlertCard),
                      ],
                      const SizedBox(height: 18),
                      _ordersHistorySection(context),
                      const SizedBox(height: 18),
                      _sectionTitle('Latest Orders', action: 'Daraz style'),
                      const SizedBox(height: 10),
                      if (_visibleOrders.isEmpty)
                        const EmptyState(title: 'No orders synced', message: 'Run order sync to pull recent Daraz orders.', icon: Icons.receipt_long_outlined)
                      else
                        ..._visibleOrders.take(8).map(_buildOrderCard),
                      if (_visibleCancelledOrders.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 18),
                        _sectionTitle('Cancelled Orders', action: '${_visibleCancelledOrders.length} audit'),
                        const SizedBox(height: 10),
                        ..._visibleCancelledOrders.take(4).map(_buildOrderCard),
                      ],
                      const SizedBox(height: 18),
                      _sectionTitle('Return Orders', action: '${_visibleReturns.length} records'),
                      const SizedBox(height: 10),
                      if (_visibleReturns.isEmpty)
                        const EmptyState(title: 'No return claims', message: 'Customer return claims will appear here after sync.', icon: Icons.assignment_return_outlined)
                      else
                        ..._visibleReturns.take(6).map(_buildReturnCard),
                      const SizedBox(height: 18),
                      _sectionTitle('Failed Delivery', action: '${_visibleFailedDeliveries.length} to watch'),
                      const SizedBox(height: 10),
                      if (_visibleFailedDeliveries.isEmpty)
                        const EmptyState(title: 'No failed deliveries', message: 'Failed delivery collection records will appear here.', icon: Icons.local_shipping_outlined)
                      else
                        ..._visibleFailedDeliveries.take(6).map(_buildFailedDeliveryCard),
                      const SizedBox(height: 18),
                      _sectionTitle('Order item processing'),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            _filterChip('all', 'All'),
                            const SizedBox(width: 8),
                            _filterChip('deducted', 'Deducted'),
                            const SizedBox(width: 8),
                            _filterChip('restored', 'Restored'),
                            const SizedBox(width: 8),
                            _filterChip('pending', 'Pending'),
                            const SizedBox(width: 8),
                            _filterChip('errors', 'Errors'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_visibleItems.isEmpty)
                        const EmptyState(title: 'No synced order items', message: 'Order item deductions and restore outcomes appear here.', icon: Icons.inventory_2_outlined)
                      else
                        ..._visibleItems.take(10).map(_buildOrderItemCard),
                    ],
                  ),
                ),
    );
  }

  Widget _storeSelector() {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _storeFilter,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          items: <DropdownMenuItem<String>>[
            const DropdownMenuItem<String>(
              value: 'all',
              child: Text('All stores', overflow: TextOverflow.ellipsis),
            ),
            ..._stores.map(
              (store) => DropdownMenuItem<String>(
                value: store.id,
                child: Text('${store.name} · ${store.code}', overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: _busy ? null : (value) => setState(() => _storeFilter = value ?? 'all'),
        ),
      ),
    );
  }

  Widget _actionGrid(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 360 ? width - 32 : (width - 44) / 2;
    final store = _selectedStore;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(width: itemWidth, child: ActionTile(title: 'Sync Orders', subtitle: 'Pull new orders', icon: Icons.receipt_long_outlined, onTap: _busy ? null : _runAllSync, highlight: true, loading: _workingAction == 'orders')),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Sync Products', subtitle: 'Refresh listings', icon: Icons.cloud_download_outlined, onTap: _busy || store == null ? null : () => _importProductsForStore(store), loading: _workingAction == 'products')),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Store Sync', subtitle: 'Selected store only', icon: Icons.storefront_outlined, onTap: _busy || store == null ? null : () => _runStoreSync(store), loading: _workingAction == 'store')),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Refresh Status', subtitle: 'Update dashboard', icon: Icons.sync_rounded, onTap: _busy ? null : _refreshStatus, loading: _workingAction == 'status')),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Return Orders', subtitle: 'Claims and returns', icon: Icons.assignment_return_outlined, onTap: _busy ? null : _refreshReturns, loading: _workingAction == 'returns')),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Failed Delivery', subtitle: '6-day collection watch', icon: Icons.local_shipping_outlined, onTap: _busy ? null : _refreshFailedDelivery, loading: _workingAction == 'failed')),
      ],
    );
  }

  Widget _progressCard() {
    final total = _orderItems.length;
    final processed = _orderItems.where((item) => item.stockDeducted || item.stockRestored).length;
    final progress = total == 0 ? 0.0 : processed / total;
    return AppCard(
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const MiniIcon(icon: Icons.cloud_sync_outlined, color: AppTheme.info, background: AppTheme.infoSoft),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_status?.syncRunningNow == true ? 'Stock sync running' : 'Sync engine idle', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                    const SizedBox(height: 3),
                    Text('${_stores.length} stores · ${_orders.length} orders · $total items · ${_returns.length} returns · ${_failedDeliveries.length} failed delivery · ${_collectionAlerts.length} alerts', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              StatusChip(label: '${(progress * 100).round()}%', color: AppTheme.info, softColor: AppTheme.infoSoft),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: AppTheme.background,
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
            ),
          ),
          const SizedBox(height: 8),
          Text('$processed / $total processed', style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _ordersHistorySection(BuildContext context) {
    final totalOrders = JsonReaders.integer(_historySummary, 'total_orders');
    final revenue = JsonReaders.number(_historySummary, 'revenue');
    final returns = JsonReaders.integer(_historySummary, 'returns');
    final failed = JsonReaders.integer(_historySummary, 'failed_deliveries');
    final cancelled = JsonReaders.integer(_historySummary, 'cancelled_orders');
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 360 ? width - 32 : (width - 44) / 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionTitle('Orders History', action: _historyLabel),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              _historyChip('today', 'Today'),
              const SizedBox(width: 8),
              _historyChip('week', 'Week'),
              const SizedBox(width: 8),
              _historyChip('month', 'Month'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            SizedBox(width: itemWidth, child: MetricCard(label: 'Total Orders', value: Formatters.quantity(totalOrders), icon: Icons.shopping_bag_outlined, tint: AppTheme.successSoft, iconColor: AppTheme.success)),
            if (_historyRevenueAvailable)
              SizedBox(width: itemWidth, child: MetricCard(label: 'Revenue', value: 'Rs. ${Formatters.money(revenue)}', icon: Icons.payments_outlined, tint: AppTheme.infoSoft, iconColor: AppTheme.info)),
            SizedBox(width: itemWidth, child: MetricCard(label: 'Returns', value: Formatters.quantity(returns), icon: Icons.assignment_return_outlined, tint: AppTheme.warningSoft, iconColor: AppTheme.warning)),
            SizedBox(width: itemWidth, child: MetricCard(label: 'Failed Delivery', value: Formatters.quantity(failed), icon: Icons.local_shipping_outlined, tint: AppTheme.dangerSoft, iconColor: AppTheme.danger)),
            SizedBox(width: itemWidth, child: MetricCard(label: 'Cancelled', value: Formatters.quantity(cancelled), icon: Icons.cancel_outlined, tint: AppTheme.dangerSoft, iconColor: AppTheme.danger)),
          ],
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(_historyRevenueAvailable ? 'Orders + revenue trend' : 'Orders trend', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              const SizedBox(height: 10),
              if (_historySeries.isEmpty)
                const Text('No history data for this period.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700))
              else
                ..._historySeries.take(8).map(_historyBar),
            ],
          ),
        ),
      ],
    );
  }

  Widget _historyBar(Map<String, dynamic> row) {
    final orders = JsonReaders.integer(row, 'orders');
    final revenue = JsonReaders.number(row, 'revenue');
    final maxOrders = _historySeries.map((item) => JsonReaders.integer(item, 'orders')).fold<int>(1, (max, value) => value > max ? value : max);
    final fraction = (orders / maxOrders).clamp(0.05, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: <Widget>[
          SizedBox(width: 78, child: Text(JsonReaders.string(row, 'date'), style: const TextStyle(color: AppTheme.textMuted, fontSize: 10, fontWeight: FontWeight.w800))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 9,
                backgroundColor: AppTheme.background,
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 86, child: Text(_historyRevenueAvailable ? '$orders · Rs. ${Formatters.money(revenue)}' : '$orders orders', textAlign: TextAlign.right, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, {String? action}) {
    return Row(
      children: <Widget>[
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
        if (action != null) Text(action, style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w900)),
      ],
    );
  }

  Widget _historyChip(String value, String label) {
    final selected = _historyPeriod == value;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: _busy ? null : (_) => _selectHistoryPeriod(value),
      selectedColor: AppTheme.primary,
      backgroundColor: Colors.white,
      labelStyle: TextStyle(color: selected ? Colors.white : AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w900),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _itemFilter == value;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _itemFilter = value),
      selectedColor: AppTheme.primary,
      backgroundColor: Colors.white,
      labelStyle: TextStyle(color: selected ? Colors.white : AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w900),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Widget _buildOrderCard(CentralOrder order) {
    final amountText = order.amount > 0 ? ' · Rs. ${Formatters.money(order.amount)}' : '';
    final statusText = order.status.isNotEmpty ? order.status : (order.processingStatus.isEmpty ? 'Order' : order.processingStatus);
    final isCancelled = order.statusCategory == 'cancelled' || order.status.toLowerCase().contains('cancel');
    final color = isCancelled ? AppTheme.danger : AppTheme.success;
    final softColor = isCancelled ? AppTheme.dangerSoft : AppTheme.successSoft;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            ProductImageBox(imageUrl: order.productImageUrl, icon: Icons.shopping_bag_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(order.productTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('Order ${order.orderNumber.isEmpty ? order.externalOrderId : order.orderNumber}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text('${order.storeName} · ${Formatters.dateTime(order.orderCreatedAt)}$amountText', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusChip(label: statusText, color: color, softColor: softColor),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderItemCard(CentralOrderItem item) {
    final hasError = item.errorMessage.trim().isNotEmpty;
    final restored = item.stockRestored;
    final deducted = item.stockDeducted;
    final color = hasError ? AppTheme.danger : restored ? AppTheme.info : deducted ? AppTheme.success : AppTheme.warning;
    final softColor = hasError ? AppTheme.dangerSoft : restored ? AppTheme.infoSoft : deducted ? AppTheme.successSoft : AppTheme.warningSoft;
    final label = hasError ? 'Error' : restored ? 'Restored' : deducted ? 'Deducted' : 'Running';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            ProductImageBox(imageUrl: item.imageUrl, icon: hasError ? Icons.error_outline : Icons.inventory_2_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('${item.storeCode} · Qty ${item.quantity} · Order ${item.orderNumber}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                  if (hasError) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(item.errorMessage, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.danger, fontSize: 11, fontWeight: FontWeight.w800)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusChip(label: label, color: color, softColor: softColor),
          ],
        ),
      ),
    );
  }

  Widget _buildReturnCard(CentralOrderItem item) {
    final collected = item.isCollected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            ProductImageBox(imageUrl: item.imageUrl, icon: Icons.assignment_return_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('Return order ${item.externalOrderItemId} · Original ${item.orderNumber}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text('${item.hubName} · Arrived ${Formatters.date(item.hubArrivedAt ?? item.logisticFacilityAt)} · Deadline ${Formatters.date(item.collectionDeadlineAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                  if (item.returnReason.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(item.returnReason, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                StatusChip(label: collected ? 'Collected' : _collectionLabel(item), color: collected ? AppTheme.success : _collectionColor(item), softColor: collected ? AppTheme.successSoft : _collectionSoftColor(item)),
                if (!collected) ...<Widget>[
                  const SizedBox(height: 6),
                  IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Mark collected',
                    onPressed: _busy ? null : () => _markItemReceived(item),
                    icon: const Icon(Icons.inventory_rounded, size: 16),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollectionAlertCard(CentralOrderItem item) {
    return item.isReturn ? _buildReturnCard(item) : _buildFailedDeliveryCard(item);
  }

  Widget _buildFailedDeliveryCard(CentralOrderItem item) {
    final collected = item.isCollected;
    final color = collected ? AppTheme.success : _collectionColor(item);
    final softColor = collected ? AppTheme.successSoft : _collectionSoftColor(item);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            ProductImageBox(imageUrl: item.imageUrl, icon: Icons.local_shipping_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('Order ${item.orderNumber} · ${item.storeName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text('${item.hubName} · Arrived ${Formatters.date(item.hubArrivedAt ?? item.logisticFacilityAt)} · Deadline ${Formatters.date(item.collectionDeadlineAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                StatusChip(label: collected ? 'Collected' : _collectionLabel(item), color: color, softColor: softColor),
                if (!collected) ...<Widget>[
                  const SizedBox(height: 6),
                  IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Mark collected',
                    onPressed: _busy ? null : () => _markItemReceived(item),
                    icon: const Icon(Icons.inventory_rounded, size: 16),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _collectionLabel(CentralOrderItem item) {
    final daysLeft = item.daysLeftToCollect;
    if (item.collectionNotificationLevel == 'overdue') return 'Scrap risk';
    if (item.collectionNotificationLevel == 'deadline') return 'Due today';
    if (daysLeft == null) return item.hubArrivedAt == null ? 'Tracking' : 'Collect';
    if (daysLeft < 0) return 'Scrap risk';
    if (daysLeft == 0) return 'Due today';
    return '${daysLeft.clamp(0, 99)}d left';
  }

  Color _collectionColor(CentralOrderItem item) {
    final daysLeft = item.daysLeftToCollect;
    if (item.collectionNotificationLevel == 'overdue' || item.collectionNotificationLevel == 'deadline' || (daysLeft != null && daysLeft <= 1)) {
      return AppTheme.danger;
    }
    return AppTheme.warning;
  }

  Color _collectionSoftColor(CentralOrderItem item) {
    return _collectionColor(item) == AppTheme.danger ? AppTheme.dangerSoft : AppTheme.warningSoft;
  }

}
