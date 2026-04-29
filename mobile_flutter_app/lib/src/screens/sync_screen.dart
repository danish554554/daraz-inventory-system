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
        _stores = JsonReaders.list(storesMap['stores'])
            .map((item) => StoreModel.fromJson(JsonReaders.map(item)))
            .toList();
        _orders = JsonReaders.list(ordersMap['orders'])
            .map((item) => CentralOrder.fromJson(JsonReaders.map(item)))
            .toList();
        _orderItems = JsonReaders.list(itemsMap['items'])
            .map((item) => CentralOrderItem.fromJson(JsonReaders.map(item)))
            .toList();
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Failed to load sync center.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<CentralOrder> get _visibleOrders {
    final filtered = _storeFilter == 'all'
        ? _orders
        : _orders.where((order) => order.storeId == _storeFilter).toList();
    filtered.sort((a, b) {
      final aDate = a.orderCreatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = b.orderCreatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return filtered;
  }

  List<CentralOrderItem> get _visibleItems {
    var items = _storeFilter == 'all'
        ? List<CentralOrderItem>.from(_orderItems)
        : _orderItems.where((item) => item.storeId == _storeFilter).toList();

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
      if (mounted) {
        showAppSnackBar(context, response['message']?.toString() ?? 'All-store sync completed.');
      }
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
      if (mounted) {
        showAppSnackBar(context, response['message']?.toString() ?? '${store.name} synced.');
      }
      await _load();
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Center'),
        actions: <Widget>[
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const AppLoader(label: 'Loading sync center...')
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: EmptyState(
                      title: 'Sync center unavailable',
                      message: _error!,
                      icon: Icons.sync_problem_outlined,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                      children: <Widget>[
                        SectionHeader(
                          title: 'Daraz Sync',
                          subtitle: _status?.syncRunningNow == true
                              ? 'The central inventory sync engine is running right now.'
                              : 'Run all-store or single-store sync without changing backend logic.',
                        ),
                        const SizedBox(height: 16),
                        InfoBanner(
                          text: _status?.syncRunningNow == true
                              ? 'A sync job is in progress. New orders and stock deductions may still be updating.'
                              : 'Store sync pulls orders from Daraz, writes them to MongoDB, and applies ledger deductions or restores based on your existing rules.',
                          background: _status?.syncRunningNow == true ? AppTheme.infoSoft : AppTheme.primarySoft,
                          foreground: _status?.syncRunningNow == true ? AppTheme.info : AppTheme.primary,
                          icon: _status?.syncRunningNow == true ? Icons.sync : Icons.settings_input_component_outlined,
                        ),
                        const SizedBox(height: 18),
                        _topMetrics(context),
                        const SizedBox(height: 18),
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text('Sync Actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                              const SizedBox(height: 6),
                              const Text(
                                'Trigger the same sync endpoints used by the web app. Automatic scheduler behavior remains on the backend.',
                                style: TextStyle(color: AppTheme.textMuted),
                              ),
                              const SizedBox(height: 14),
                              PrimaryButton(
                                label: 'Run All Stores Sync',
                                onPressed: _working || _status?.syncRunningNow == true ? null : _runAllSync,
                                icon: Icons.play_circle_fill_rounded,
                                expanded: true,
                                loading: _working,
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 52,
                                child: DropdownButtonFormField<String>(
                                  initialValue: _storeFilter,
                                  decoration: const InputDecoration(labelText: 'Focus on store'),
                                  items: <DropdownMenuItem<String>>[
                                    const DropdownMenuItem<String>(value: 'all', child: Text('All stores')),
                                    ..._stores.map(
                                      (store) => DropdownMenuItem<String>(
                                        value: store.id,
                                        child: Text('${store.name} (${store.code})'),
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) => setState(() => _storeFilter = value ?? 'all'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text('Stores Ready for Sync', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        ..._stores.map(_buildStoreCard),
                        const SizedBox(height: 18),
                        Row(
                          children: <Widget>[
                            const Expanded(
                              child: Text('Recent Orders', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                            ),
                            TextButton(
                              onPressed: null,
                              child: Text('${_visibleOrders.length} items'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_visibleOrders.isEmpty)
                          const EmptyState(
                            title: 'No synced orders',
                            message: 'Run store sync to populate order records here.',
                            icon: Icons.receipt_long_outlined,
                          )
                        else
                          ..._visibleOrders.take(10).map(_buildOrderCard),
                        const SizedBox(height: 18),
                        Row(
                          children: <Widget>[
                            const Expanded(
                              child: Text('Order Items', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                            ),
                            SizedBox(
                              width: 150,
                              child: DropdownButtonFormField<String>(
                                initialValue: _itemFilter,
                                decoration: const InputDecoration(labelText: 'Filter'),
                                items: const <DropdownMenuItem<String>>[
                                  DropdownMenuItem<String>(value: 'all', child: Text('All')),
                                  DropdownMenuItem<String>(value: 'pending', child: Text('Pending')),
                                  DropdownMenuItem<String>(value: 'deducted', child: Text('Deducted')),
                                  DropdownMenuItem<String>(value: 'restored', child: Text('Restored')),
                                  DropdownMenuItem<String>(value: 'errors', child: Text('Errors')),
                                ],
                                onChanged: (value) => setState(() => _itemFilter = value ?? 'all'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_visibleItems.isEmpty)
                          const EmptyState(
                            title: 'No synced order items',
                            message: 'Order item deductions and restore outcomes appear here.',
                            icon: Icons.inventory_2_outlined,
                          )
                        else
                          ..._visibleItems.take(15).map(_buildOrderItemCard),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _topMetrics(BuildContext context) {
    final connected = _stores.where((store) => store.tokenConnected).length;
    final attention = _stores.where((store) => store.healthState != 'healthy').length;
    final deducted = _orderItems.where((item) => item.stockDeducted).length;
    final errors = _orderItems.where((item) => item.errorMessage.trim().isNotEmpty).length;
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 56) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(width: itemWidth, child: MetricCard(label: 'Connected Stores', value: '$connected', icon: Icons.storefront_outlined)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Need Attention', value: '$attention', icon: Icons.warning_amber_rounded, tint: AppTheme.warningSoft, iconColor: AppTheme.warning)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Deducted Items', value: '$deducted', icon: Icons.call_received_rounded, tint: AppTheme.successSoft, iconColor: AppTheme.success)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Sync Errors', value: '$errors', icon: Icons.error_outline, tint: AppTheme.dangerSoft, iconColor: AppTheme.danger)),
      ],
    );
  }

  Widget _buildStoreCard(StoreModel store) {
    final healthy = store.healthState == 'healthy';
    final syncingThisStore = _working && _storeFilter == store.id;
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
                      Text(store.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text('${store.code} • ${store.country} • ${store.deductStage}', style: const TextStyle(color: AppTheme.textMuted)),
                    ],
                  ),
                ),
                StatusChip(
                  label: healthy ? 'Healthy' : 'Attention',
                  color: healthy ? AppTheme.success : AppTheme.warning,
                  softColor: healthy ? AppTheme.successSoft : AppTheme.warningSoft,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              store.lastSyncMessage.isNotEmpty ? store.lastSyncMessage : store.healthReason,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Last sync ${Formatters.dateTime(store.lastSyncFinishedAt)} • Duration ${Formatters.durationMs(store.lastSyncDurationMs)}',
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'Sync ${store.code}',
              onPressed: _working || !store.tokenConnected ? null : () => _runStoreSync(store),
              icon: Icons.sync,
              expanded: true,
              loading: syncingThisStore,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(CentralOrder order) {
    final color = order.status.toLowerCase().contains('cancel') ? AppTheme.danger : AppTheme.info;
    final softColor = order.status.toLowerCase().contains('cancel') ? AppTheme.dangerSoft : AppTheme.infoSoft;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(order.orderNumber.isEmpty ? order.externalOrderId : order.orderNumber, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                StatusChip(label: order.status.isEmpty ? 'Unknown' : order.status, color: color, softColor: softColor),
              ],
            ),
            const SizedBox(height: 8),
            Text('${order.storeName} • ${order.storeCode}', style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 6),
            Text('Processing: ${order.processingStatus.isEmpty ? '-' : order.processingStatus}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('Created ${Formatters.dateTime(order.orderCreatedAt)}', style: const TextStyle(color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderItemCard(CentralOrderItem item) {
    final bool hasError = item.errorMessage.trim().isNotEmpty;
    final bool restored = item.stockRestored;
    final bool deducted = item.stockDeducted;

    final color = hasError
        ? AppTheme.danger
        : restored
            ? AppTheme.info
            : deducted
                ? AppTheme.success
                : AppTheme.warning;
    final softColor = hasError
        ? AppTheme.dangerSoft
        : restored
            ? AppTheme.infoSoft
            : deducted
                ? AppTheme.successSoft
                : AppTheme.warningSoft;
    final label = hasError
        ? 'Error'
        : restored
            ? 'Restored'
            : deducted
                ? 'Deducted'
                : 'Pending';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(item.productName.isEmpty ? item.sellerSku : item.productName, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                StatusChip(label: label, color: color, softColor: softColor),
              ],
            ),
            const SizedBox(height: 8),
            Text('${item.storeCode} • ${item.sellerSku} • Qty ${item.quantity}', style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 6),
            Text('Order ${item.orderNumber} • ${item.processingStatus}', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (hasError) ...<Widget>[
              const SizedBox(height: 6),
              Text(item.errorMessage, style: const TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 6),
            Text('Updated ${Formatters.dateTime(item.createdAt)}', style: const TextStyle(color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }
}
