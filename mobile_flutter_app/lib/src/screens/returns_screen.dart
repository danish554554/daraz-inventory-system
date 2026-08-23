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
  
  // Primary sections: 'failed_delivery' or 'returns'
  String _primarySection = 'failed_delivery'; 
  // Sub-filter: 'active', 'scrap_risk', 'collected'
  String _subFilter = 'active';

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
        queryParameters: <String, dynamic>{'limit': 200},
        bypassCache: true,
      ) as Map<String, dynamic>;

      final rawList = JsonReaders.list(res['items']);
      final parsed = rawList
          .map((e) => CentralOrderItem.fromJson(JsonReaders.map(e)))
          .where((item) => (item.isReturn || item.isFailedDelivery || item.hubArrivedAt != null || item.logisticFacilityAt != null) && !_isEarlyBuyerCancellation(item))
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

  bool _isEarlyBuyerCancellation(CentralOrderItem item) {
    final reason = item.returnReason.toLowerCase().trim();
    final status = (item.statusCategory.isNotEmpty ? item.statusCategory : item.orderNumber).toLowerCase();

    // If order was cancelled at initial stage without arriving at hub
    if (status.contains('cancel') && !item.isFailedDelivery && item.hubArrivedAt == null) {
      return true;
    }

    if (reason.isEmpty) return false;

    const ignoreCancellationReasons = <String>[
      'cheaper elsewhere',
      'found cheaper',
      'shipping cost is too high',
      'shipping cost',
      'dont want this order',
      "don't want this order",
      'dont want this item',
      "don't want this item",
      'want to place a new order',
      'place a new order',
      'different items',
      'more/different items',
      'seller asked me to cancel',
      'out of stock',
      'delivery time is too long',
      'delivery time',
      'duplicate order',
      'voucher',
      'forgot to use voucher',
      'change of delivery address',
      'delivery address',
      'change address',
      'decided for alternative product',
      'alternative product',
      'order placed by mistake',
      'buyer cancel',
      'buyer_cancel',
      'change of mind',
      'changed my mind'
    ];

    for (final pattern in ignoreCancellationReasons) {
      if (reason.contains(pattern)) {
        return true;
      }
    }
    return false;
  }

  bool _isItemAlreadyReturned(CentralOrderItem item) {
    if (item.isCollected) return true;
    final status = (item.statusCategory.isNotEmpty ? item.statusCategory : item.orderNumber).toLowerCase();
    final itemStatus = item.hubName.toLowerCase();
    return status.contains('successfully returned') ||
        status.contains('delivered_to_merchant') ||
        itemStatus.contains('successfully returned') ||
        itemStatus.contains('returned to seller');
  }

  Future<void> _markItemCollected(CentralOrderItem item) async {
    try {
      final id = item.id;
      if (id.isEmpty) return;
      await ApiClient.instance.post('/daraz-sync/order-items/$id/mark-received', body: <String, dynamic>{});
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Order #${item.orderNumber} marked as received/collected.');
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Failed to update collection status.', error: true);
    }
  }

  List<CentralOrderItem> get _filteredItems {
    final query = _search.trim().toLowerCase();

    return _items.where((item) {
      // Exclude early customer cancellations
      if (_isEarlyBuyerCancellation(item)) return false;

      final isReturn = item.isReturn;
      final isFailed = item.isFailedDelivery || (!item.isReturn && (item.hubArrivedAt != null || item.logisticFacilityAt != null));
      final isCompleted = _isItemAlreadyReturned(item);
      final daysLeft = item.daysLeftToCollect ?? 99;
      final isScrapRisk = daysLeft <= 2 || item.collectionNotificationLevel == 'overdue' || item.collectionNotificationLevel == 'deadline';

      // 1. Separate by Primary Section
      if (_primarySection == 'failed_delivery' && !isFailed) return false;
      if (_primarySection == 'returns' && !isReturn) return false;

      // 2. Sub-filter: Active (auto-hide completed), Scrap Risk, or Collected Archive
      if (_subFilter == 'active') {
        // Automatically exclude / remove orders that have been successfully returned
        if (isCompleted) return false;
      } else if (_subFilter == 'scrap_risk') {
        if (isCompleted || !isScrapRisk) return false;
      } else if (_subFilter == 'collected') {
        if (!isCompleted) return false;
      }

      // 3. Search query match
      if (query.isNotEmpty) {
        final matches = item.title.toLowerCase().contains(query) ||
            item.orderNumber.toLowerCase().contains(query) ||
            item.sellerSku.toLowerCase().contains(query) ||
            item.hubName.toLowerCase().contains(query) ||
            item.storeName.toLowerCase().contains(query) ||
            item.returnReason.toLowerCase().contains(query);
        if (!matches) return false;
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Calculate counts for active items
    final activeFailedCount = _items.where((i) => (i.isFailedDelivery || !i.isReturn) && !_isItemAlreadyReturned(i)).length;
    final activeReturnsCount = _items.where((i) => i.isReturn && !_isItemAlreadyReturned(i)).length;
    final urgentScrapRiskCount = _items.where((i) => !_isItemAlreadyReturned(i) && ((i.daysLeftToCollect ?? 99) <= 2 || i.collectionNotificationLevel == 'overdue')).length;

    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading returns and hub failed delivery orders...')
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
                        subtitle: 'Separate tracking for Hub Failed Delivery and Customer Return Claims',
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
                      _primarySegmentSelector(activeFailedCount, activeReturnsCount),
                      const SizedBox(height: 14),
                      _subFilterChips(urgentScrapRiskCount),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          hintText: _primarySection == 'failed_delivery'
                              ? 'Search failed delivery by title, order #, or hub...'
                              : 'Search customer return claims by product or reason...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _search = val),
                      ),
                      const SizedBox(height: 14),
                      if (_filteredItems.isEmpty)
                        EmptyState(
                          title: _primarySection == 'failed_delivery'
                              ? (_subFilter == 'active' ? 'No Pending Failed Deliveries 🎉' : 'No records found')
                              : (_subFilter == 'active' ? 'No Customer Returns Pending 🎉' : 'No return claims found'),
                          message: _subFilter == 'active'
                              ? 'All packages have either been successfully returned to your warehouse or there are no new orders at the Daraz hub.'
                              : 'Try adjusting your search query or switching tabs.',
                          icon: Icons.check_circle_outline_rounded,
                        )
                      else
                        ..._filteredItems.map(_buildSeparateParcelCard),
                    ],
                  ),
                ),
    );
  }

  Widget _primarySegmentSelector(int failedCount, int returnsCount) {
    final isDark = AppTheme.isDark(context);
    final isFailed = _primarySection == 'failed_delivery';

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _primarySection = 'failed_delivery'),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isFailed ? (isDark ? const Color(0xFF0F172A) : Colors.white) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: isFailed
                      ? <BoxShadow>[
                          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2)),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.local_shipping_rounded,
                      size: 16,
                      color: isFailed ? AppTheme.primary : AppTheme.textMutedColor(context),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Failed Delivery',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: isFailed ? AppTheme.textPrimaryColor(context) : AppTheme.textMutedColor(context),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isFailed ? AppTheme.dangerSoft : (isDark ? Colors.black38 : Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$failedCount',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: isFailed ? AppTheme.danger : AppTheme.textMutedColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _primarySection = 'returns'),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: !isFailed ? (isDark ? const Color(0xFF0F172A) : Colors.white) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: !isFailed
                      ? <BoxShadow>[
                          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2)),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.assignment_return_rounded,
                      size: 16,
                      color: !isFailed ? AppTheme.warning : AppTheme.textMutedColor(context),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Customer Returns',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: !isFailed ? AppTheme.textPrimaryColor(context) : AppTheme.textMutedColor(context),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: !isFailed ? AppTheme.warningSoft : (isDark ? Colors.black38 : Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$returnsCount',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: !isFailed ? AppTheme.warning : AppTheme.textMutedColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subFilterChips(int urgentScrapRiskCount) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _filterPill('active', 'To Collect / In Center'),
          if (urgentScrapRiskCount > 0 && _primarySection == 'failed_delivery') ...<Widget>[
            const SizedBox(width: 8),
            _filterPill('scrap_risk', '🚨 Scrap Risk ($urgentScrapRiskCount)'),
          ],
          const SizedBox(width: 8),
          _filterPill('collected', '📁 Returned Archive'),
        ],
      ),
    );
  }

  Widget _filterPill(String key, String label) {
    final selected = _subFilter == key;
    final isDark = AppTheme.isDark(context);
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _subFilter = key),
      selectedColor: AppTheme.primary,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      labelStyle: TextStyle(
        color: selected ? Colors.white : (isDark ? Colors.white70 : AppTheme.textPrimary),
        fontSize: 11,
        fontWeight: FontWeight.w900,
      ),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.borderColor(context)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }

  Widget _buildSeparateParcelCard(CentralOrderItem item) {
    final isReturn = item.isReturn;
    final isCompleted = _isItemAlreadyReturned(item);
    final daysLeft = item.daysLeftToCollect;
    final hubName = item.hubName.isNotEmpty ? item.hubName : 'Daraz Logistics Center';
    final arrivalDate = item.hubArrivedAt ?? item.logisticFacilityAt;
    final deadlineDate = item.collectionDeadlineAt;

    // Calculate deadline & scrap urgency
    Color countdownColor = AppTheme.info;
    Color countdownSoftColor = AppTheme.infoSoft;
    String limitText = 'In Transit';

    if (isCompleted) {
      countdownColor = AppTheme.success;
      countdownSoftColor = AppTheme.successSoft;
      limitText = 'Successfully Returned to Seller';
    } else if (item.collectionNotificationLevel == 'overdue' || (daysLeft != null && daysLeft < 0)) {
      countdownColor = AppTheme.danger;
      countdownSoftColor = AppTheme.dangerSoft;
      limitText = '🚨 Overdue (Scrap Risk)';
    } else if (item.collectionNotificationLevel == 'deadline' || daysLeft == 0) {
      countdownColor = AppTheme.danger;
      countdownSoftColor = AppTheme.dangerSoft;
      limitText = '🚨 Due Today (Destruction Risk)';
    } else if (daysLeft != null && daysLeft == 1) {
      countdownColor = AppTheme.danger;
      countdownSoftColor = AppTheme.dangerSoft;
      limitText = '⚠️ 1 Day Left Before Destroy';
    } else if (daysLeft != null && daysLeft <= 3) {
      countdownColor = AppTheme.warning;
      countdownSoftColor = AppTheme.warningSoft;
      limitText = '⚠️ $daysLeft Days Left (6-Day Limit)';
    } else if (daysLeft != null) {
      countdownColor = AppTheme.info;
      countdownSoftColor = AppTheme.infoSoft;
      limitText = '📦 $daysLeft Days Left at Hub';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Product Header Row: High-Res Image & Clear Title for Easy Comparison
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppTheme.softGreyColor(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.borderColor(context)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: item.imageUrl.isNotEmpty
                        ? Image.network(
                            item.imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(
                              isReturn ? Icons.assignment_return_outlined : Icons.local_shipping_outlined,
                              color: AppTheme.textMutedColor(context),
                              size: 28,
                            ),
                          )
                        : Icon(
                            isReturn ? Icons.assignment_return_outlined : Icons.local_shipping_outlined,
                            color: AppTheme.textMutedColor(context),
                            size: 28,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title.isNotEmpty ? item.title : 'Order Item #${item.orderNumber}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          height: 1.25,
                          color: AppTheme.textPrimaryColor(context),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Order #${item.orderNumber.isNotEmpty ? item.orderNumber : item.externalOrderItemId} · ${item.storeName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textPrimaryColor(context),
                          fontSize: 12,
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
              ],
            ),
            const SizedBox(height: 12),

            // Hub Location & Center Arrival Status
            Container(
              width: double.infinity,
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
                        arrivalDate != null ? 'Arrived at Center: ${Formatters.date(arrivalDate)}' : 'Status: In Transit to Hub',
                        style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                      if (deadlineDate != null && !isCompleted)
                        Text(
                          'Deadline: ${Formatters.date(deadlineDate)}',
                          style: const TextStyle(color: AppTheme.danger, fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                    ],
                  ),
                  if (isReturn && item.returnReason.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.warningSoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Customer Claim Reason: ${item.returnReason}',
                        style: const TextStyle(color: AppTheme.warning, fontSize: 10, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Bottom Action & Countdown Limit Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: countdownSoftColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: countdownColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    limitText,
                    style: TextStyle(
                      color: countdownColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!isCompleted)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: isReturn ? AppTheme.warning : AppTheme.primary,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _markItemCollected(item),
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 15),
                    label: const Text('Mark Collected', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                  )
                else
                  const Row(
                    children: <Widget>[
                      Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.success),
                      SizedBox(width: 4),
                      Text('Collected', style: TextStyle(color: AppTheme.success, fontSize: 12, fontWeight: FontWeight.w900)),
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
