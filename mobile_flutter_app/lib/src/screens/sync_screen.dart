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

class _SyncScreenState extends State<SyncScreen> {
  bool _loading = true;
  bool _working = false;
  String? _error;
  String _storeFilter = 'all';
  String _itemFilter = 'all';

  SyncStatus? _status;
  List<StoreModel> _stores = <StoreModel>[];
  List<CentralOrder> _orders = <CentralOrder>[];
  List<CentralOrderItem> _orderItems = <CentralOrderItem>[];

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
        safe(ApiClient.instance.get('/daraz-sync/status')),
        safe(ApiClient.instance.get('/stores')),
        safe(ApiClient.instance.get('/daraz-sync/orders', queryParameters: <String, dynamic>{'limit': 30})),
        safe(ApiClient.instance.get('/daraz-sync/order-items', queryParameters: <String, dynamic>{'limit': 60})),
      ]);

      final storesMap = JsonReaders.map(results[1]);
      if (results[0] == null && storesMap.isEmpty) {
        throw ApiException(message: 'Could not load the sync center. Check the backend URL and session.');
      }

      final ordersMap = JsonReaders.map(results[2]);
      final itemsMap = JsonReaders.map(results[3]);

      setState(() {
        _status = results[0] == null
            ? SyncStatus(schedulerManagedBy: '', syncEngine: '', syncRunningNow: false)
            : SyncStatus.fromJson(JsonReaders.map(results[0]));
        _stores = JsonReaders.list(storesMap['stores']).map((item) => StoreModel.fromJson(JsonReaders.map(item))).toList();
        _orders = JsonReaders.list(ordersMap['orders']).map((item) => CentralOrder.fromJson(JsonReaders.map(item))).toList();
        _orderItems = JsonReaders.list(itemsMap['items']).map((item) => CentralOrderItem.fromJson(JsonReaders.map(item))).toList();
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Failed to load sync center.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CentralOrder> get _visibleOrders {
    final filtered = _storeFilter == 'all' ? _orders : _orders.where((order) => order.storeId == _storeFilter).toList();
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

  Future<void> _runAllSync() async {
    setState(() => _working = true);
    try {
      final response = await ApiClient.instance.post('/daraz-sync/run-all') as Map<String, dynamic>;
      if (mounted) showAppSnackBar(context, response['message']?.toString() ?? 'All-store sync completed.');
      await _load();
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _runStoreSync(StoreModel store) async {
    setState(() => _working = true);
    try {
      final response = await ApiClient.instance.post('/daraz-sync/run-store/${store.id}') as Map<String, dynamic>;
      if (mounted) showAppSnackBar(context, response['message']?.toString() ?? '${store.name} synced.');
      await _load();
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _importProductsForStore(StoreModel store) async {
    setState(() => _working = true);
    try {
      await ApiClient.instance.post('/daraz-sync/import-products/${store.id}');
      if (mounted) showAppSnackBar(context, 'Active Daraz products imported successfully.');
      await _load();
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Failed to import Daraz products. Please try again.', error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  StoreModel? get _selectedStore {
    if (_stores.isEmpty) return null;
    if (_storeFilter == 'all') return _stores.first;
    for (final store in _stores) {
      if (store.id == _storeFilter) return store;
    }
    return null;
  }

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
                  onRefresh: _load,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SectionHeader(
                        title: 'Sync Center',
                        subtitle: 'Pull orders, push stock, refresh products',
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
                      const SizedBox(height: 18),
                      _sectionTitle('Recent activity', action: 'View log'),
                      const SizedBox(height: 10),
                      if (_visibleOrders.isEmpty)
                        const EmptyState(title: 'No orders synced', message: 'Run order sync to pull recent Daraz orders.', icon: Icons.receipt_long_outlined)
                      else
                        ..._visibleOrders.take(5).map(_buildOrderCard),
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
          onChanged: (value) => setState(() => _storeFilter = value ?? 'all'),
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
        SizedBox(width: itemWidth, child: ActionTile(title: 'Sync Orders', subtitle: 'Pull new orders', icon: Icons.receipt_long_outlined, onTap: _working ? null : _runAllSync, highlight: true, loading: _working && _storeFilter == 'all')),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Sync Products', subtitle: 'Refresh listings', icon: Icons.cloud_download_outlined, onTap: _working || store == null ? null : () => _importProductsForStore(store))),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Store Sync', subtitle: 'Selected store only', icon: Icons.storefront_outlined, onTap: _working || store == null ? null : () => _runStoreSync(store))),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Refresh Status', subtitle: 'Update dashboard', icon: Icons.sync_rounded, onTap: _working ? null : _load)),
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
                    Text('${_stores.length} stores · ${_orders.length} orders · $total items', style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
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

  Widget _sectionTitle(String title, {String? action}) {
    return Row(
      children: <Widget>[
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
        if (action != null) Text(action, style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w900)),
      ],
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
    final color = order.status.toLowerCase().contains('cancel') ? AppTheme.danger : AppTheme.success;
    final softColor = order.status.toLowerCase().contains('cancel') ? AppTheme.dangerSoft : AppTheme.successSoft;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            MiniIcon(icon: Icons.shopping_bag_outlined, color: color, background: softColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Order ${order.orderNumber.isEmpty ? order.externalOrderId : order.orderNumber}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('${order.storeName} · ${Formatters.dateTime(order.orderCreatedAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusChip(label: order.processingStatus.isEmpty ? order.status : order.processingStatus, color: color, softColor: softColor),
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
            MiniIcon(icon: hasError ? Icons.error_outline : Icons.inventory_2_outlined, color: color, background: softColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.productName.isEmpty ? item.sellerSku : item.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
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
}
