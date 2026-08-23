import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/formatters.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'scanner_screen.dart';

class ReturnsAndFailedDeliveryScreen extends StatefulWidget {
  const ReturnsAndFailedDeliveryScreen({super.key});

  @override
  State<ReturnsAndFailedDeliveryScreen> createState() => _ReturnsAndFailedDeliveryScreenState();
}

class _ReturnsAndFailedDeliveryScreenState extends State<ReturnsAndFailedDeliveryScreen> {
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  String _search = '';
  String _activeTab = 'all'; // all, failed_delivery, returns, scrap_risk, collected

  List<CentralOrderItem> _items = <CentralOrderItem>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final res = await ApiClient.instance.get(
        '/daraz-sync/order-items',
        queryParameters: <String, dynamic>{'limit': 150},
        bypassCache: true,
      ) as Map<String, dynamic>;

      final rawList = JsonReaders.list(res['items']);
      final parsed = rawList
          .map((e) => CentralOrderItem.fromJson(JsonReaders.map(e)))
          .where((item) => item.isReturn || item.isFailedDelivery || item.hubArrivedAt != null || item.logisticFacilityAt != null)
          .toList();

      if (mounted) {
        setState(() {
          _items = parsed;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed to load returns and failed delivery records.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await Future.wait<dynamic>(<Future<dynamic>>[
        ApiClient.instance.post('/daraz-sync/scan-returns', body: <String, dynamic>{'history_days': 60}),
        ApiClient.instance.post('/daraz-sync/scan-failed-delivery', body: <String, dynamic>{'history_days': 60}),
      ]);
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Synced latest return & failed delivery records from Daraz.');
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Sync completed with cached records.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _markItemCollected(CentralOrderItem item) async {
    try {
      final id = item.id;
      if (id.isEmpty) return;
      await ApiClient.instance.post('/daraz-sync/order-items/$id/mark-received', body: <String, dynamic>{});
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Marked parcel as collected from Daraz hub.');
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Failed to update collection status.', error: true);
    }
  }

  List<CentralOrderItem> get _filteredItems {
    final query = _search.trim().toLowerCase();
    return _items.where((item) {
      final isReturn = item.isReturn;
      final isFailed = item.isFailedDelivery;
      final daysLeft = item.daysLeftToCollect ?? 99;
      final isScrapRisk = daysLeft <= 2 || item.collectionNotificationLevel == 'overdue' || item.collectionNotificationLevel == 'deadline';
      final isCollected = item.isCollected;

      if (_activeTab == 'failed_delivery' && !isFailed) return false;
      if (_activeTab == 'returns' && !isReturn) return false;
      if (_activeTab == 'scrap_risk' && (!isScrapRisk || isCollected)) return false;
      if (_activeTab == 'collected' && !isCollected) return false;

      if (query.isNotEmpty) {
        final matches = item.title.toLowerCase().contains(query) ||
            item.orderNumber.toLowerCase().contains(query) ||
            item.sellerSku.toLowerCase().contains(query) ||
            item.hubName.toLowerCase().contains(query) ||
            item.storeName.toLowerCase().contains(query);
        if (!matches) return false;
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final failedCount = _items.where((i) => i.isFailedDelivery && !i.isCollected).length;
    final returnsCount = _items.where((i) => i.isReturn && !i.isCollected).length;
    final scrapRiskCount = _items.where((i) => !i.isCollected && ((i.daysLeftToCollect ?? 99) <= 2 || i.collectionNotificationLevel == 'overdue')).length;

    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading hub parcels and returns...')
          : _error != null
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: EmptyState(
                      title: 'Hub records unavailable',
                      message: _error!,
                      icon: Icons.local_shipping_outlined,
                    ),
                  ),
                )
              : AppShell(
                  onRefresh: () => _load(silent: true),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SectionHeader(
                        title: 'Returns & Failed Delivery',
                        subtitle: 'Monitor 6-day scrap deadlines, hub pickups & customer claims',
                        action: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            CircleIconButton(
                              icon: Icons.qr_code_scanner_rounded,
                              onPressed: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (context) => const ScannerScreen(mode: ScannerScanMode.returnParcels),
                                  ),
                                );
                                await _load(silent: true);
                              },
                              background: AppTheme.accentSoft,
                              foreground: AppTheme.accent,
                            ),
                            const SizedBox(width: 8),
                            CircleIconButton(
                              icon: Icons.sync_rounded,
                              onPressed: _syncing ? null : _syncNow,
                              background: AppTheme.primary,
                              foreground: Colors.white,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _statsSummaryGrid(failedCount, returnsCount, scrapRiskCount),
                      const SizedBox(height: 16),
                      _filterTabs(failedCount, returnsCount, scrapRiskCount),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search order #, product, SKU, or hub...',
                          prefixIcon: Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _search = val),
                      ),
                      const SizedBox(height: 14),
                      if (_filteredItems.isEmpty)
                        EmptyState(
                          title: _items.isEmpty ? 'No Returns or Failed Deliveries' : 'No matching records',
                          message: _items.isEmpty
                              ? 'Your connected Daraz stores currently have 0 pending return claims or hub failed delivery parcels.'
                              : 'Try adjusting your search terms or filter tab.',
                          icon: Icons.check_circle_outline_rounded,
                        )
                      else
                        ..._filteredItems.map(_buildParcelCard),
                    ],
                  ),
                ),
    );
  }

  Widget _statsSummaryGrid(int failedCount, int returnsCount, int scrapRiskCount) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 44) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Failed Delivery',
            value: '$failedCount',
            icon: Icons.local_shipping_outlined,
            tint: AppTheme.dangerSoft,
            iconColor: AppTheme.danger,
            caption: '6-day scrap tracking',
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Return Claims',
            value: '$returnsCount',
            icon: Icons.assignment_return_outlined,
            tint: AppTheme.warningSoft,
            iconColor: AppTheme.warning,
            caption: 'Customer claims',
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Urgent Scrap Risk',
            value: '$scrapRiskCount',
            icon: Icons.warning_amber_rounded,
            tint: scrapRiskCount > 0 ? AppTheme.dangerSoft : AppTheme.successSoft,
            iconColor: scrapRiskCount > 0 ? AppTheme.danger : AppTheme.success,
            caption: scrapRiskCount > 0 ? 'Collect within 48h!' : 'All safe',
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Total Monitored',
            value: '${_items.length}',
            icon: Icons.inventory_2_outlined,
            tint: AppTheme.infoSoft,
            iconColor: AppTheme.info,
            caption: 'Live records',
          ),
        ),
      ],
    );
  }

  Widget _filterTabs(int failedCount, int returnsCount, int scrapRiskCount) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _tabChip('all', 'All (${_items.length})'),
          const SizedBox(width: 8),
          _tabChip('failed_delivery', 'Failed Delivery ($failedCount)'),
          const SizedBox(width: 8),
          _tabChip('returns', 'Returns ($returnsCount)'),
          if (scrapRiskCount > 0) ...<Widget>[
            const SizedBox(width: 8),
            _tabChip('scrap_risk', '🚨 Scrap Risk ($scrapRiskCount)'),
          ],
          const SizedBox(width: 8),
          _tabChip('collected', 'Collected'),
        ],
      ),
    );
  }

  Widget _tabChip(String key, String label) {
    final selected = _activeTab == key;
    final isDark = AppTheme.isDark(context);
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _activeTab = key),
      selectedColor: AppTheme.primary,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      labelStyle: TextStyle(
        color: selected ? Colors.white : (isDark ? Colors.white70 : AppTheme.textPrimary),
        fontSize: 12,
        fontWeight: FontWeight.w900,
      ),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.borderColor(context)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Widget _buildParcelCard(CentralOrderItem item) {
    final collected = item.isCollected;
    final daysLeft = item.daysLeftToCollect;
    final hubName = item.hubName.isNotEmpty ? item.hubName : 'Daraz Logistics Facility';
    final arrivalDate = item.hubArrivedAt ?? item.logisticFacilityAt;
    final deadlineDate = item.collectionDeadlineAt;

    // Determine status badge color and label
    Color chipColor = AppTheme.info;
    Color chipSoftColor = AppTheme.infoSoft;
    String limitText = 'Tracking';

    if (collected) {
      chipColor = AppTheme.success;
      chipSoftColor = AppTheme.successSoft;
      limitText = 'Collected';
    } else if (item.collectionNotificationLevel == 'overdue' || (daysLeft != null && daysLeft < 0)) {
      chipColor = AppTheme.danger;
      chipSoftColor = AppTheme.dangerSoft;
      limitText = '🚨 Overdue (Scrap Risk)';
    } else if (item.collectionNotificationLevel == 'deadline' || daysLeft == 0) {
      chipColor = AppTheme.danger;
      chipSoftColor = AppTheme.dangerSoft;
      limitText = '🚨 Due Today (Scrap Risk)';
    } else if (daysLeft != null && daysLeft == 1) {
      chipColor = AppTheme.danger;
      chipSoftColor = AppTheme.dangerSoft;
      limitText = '⚠️ 1 Day Left to Collect';
    } else if (daysLeft != null && daysLeft <= 3) {
      chipColor = AppTheme.warning;
      chipSoftColor = AppTheme.warningSoft;
      limitText = '⚠️ $daysLeft Days Left (6-Day Limit)';
    } else if (daysLeft != null) {
      chipColor = AppTheme.info;
      chipSoftColor = AppTheme.infoSoft;
      limitText = '📦 $daysLeft Days Left';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ProductImageBox(
                  imageUrl: item.imageUrl,
                  icon: item.isReturn ? Icons.assignment_return_outlined : Icons.local_shipping_outlined,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                          color: AppTheme.textPrimaryColor(context),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Order #${item.orderNumber.isNotEmpty ? item.orderNumber : item.externalOrderItemId} · ${item.storeName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textPrimaryColor(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'SKU: ${item.sellerSku} · Qty: ${item.quantity}',
                        style: TextStyle(
                          color: AppTheme.textMutedColor(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(label: item.isReturn ? 'Return' : 'Failed Delivery', color: chipColor, softColor: chipSoftColor),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.softGreyColor(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.location_on_outlined, size: 14, color: AppTheme.primary),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'Hub: $hubName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimaryColor(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        'Arrived: ${arrivalDate != null ? Formatters.date(arrivalDate) : "In Transit"}',
                        style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                      if (deadlineDate != null)
                        Text(
                          'Deadline: ${Formatters.date(deadlineDate)}',
                          style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
                  if (item.returnReason.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      'Reason: ${item.returnReason}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: chipSoftColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: chipColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    limitText,
                    style: TextStyle(
                      color: chipColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!collected)
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _markItemCollected(item),
                    icon: const Icon(Icons.inventory_rounded, size: 14),
                    label: const Text('Mark Collected', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                  )
                else
                  const Row(
                    children: <Widget>[
                      Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.success),
                      SizedBox(width: 4),
                      Text('Received', style: TextStyle(color: AppTheme.success, fontSize: 12, fontWeight: FontWeight.w900)),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
