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
  bool _batchActionLoading = false;
  String? _error;
  String _search = '';
  
  // Primary sections: 'failed_delivery' or 'returns'
  String _primarySection = 'failed_delivery'; 
  // Sub-filter: 'active', 'scrap_risk', 'collected'
  String _subFilter = 'active';

  List<CentralOrderItem> _items = <CentralOrderItem>[];
  List<StoreModel> _stores = <StoreModel>[];
  final Set<String> _selectedItemIds = <String>{};

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
      // Load stores to ensure accurate store name resolution
      try {
        final storesRes = await ApiClient.instance.get('/stores', bypassCache: true);
        final storesMap = JsonReaders.map(storesRes);
        final rawStores = JsonReaders.list(storesMap['stores']);
        if (rawStores.isNotEmpty) {
          _stores = rawStores.map((e) => StoreModel.fromJson(JsonReaders.map(e))).toList();
        }
      } catch (_) {
        // Ignore store lookup errors and use fallback
      }

      dynamic res;
      try {
        res = await ApiClient.instance.get(
          '/daraz-sync/order-items',
          queryParameters: <String, dynamic>{'limit': 300},
          bypassCache: true,
        );
      } catch (_) {
        res = await ApiClient.instance.get(
          '/daraz-sync/collection-watch',
          queryParameters: <String, dynamic>{'limit': 300, 'include_collected': 'true'},
          bypassCache: true,
        );
      }

      final resMap = JsonReaders.map(res);
      final rawList = JsonReaders.list(resMap['items'] ?? resMap['parcels']);
      final parsed = rawList
          .map((e) => CentralOrderItem.fromJson(JsonReaders.map(e)))
          .where((item) => item.isReturn || item.isFailedDelivery || item.hubArrivedAt != null || item.logisticFacilityAt != null)
          .toList();

      if (mounted) {
        setState(() {
          _items = parsed;
          // Prune selected IDs that are no longer present or already collected
          _selectedItemIds.removeWhere((id) {
            final match = _items.where((item) => item.id == id).firstOrNull;
            return match == null || _isItemAlreadyReturned(match);
          });
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
        ApiClient.instance.post('/daraz-sync/scan-returns', body: <String, dynamic>{'history_days': 40}),
        ApiClient.instance.post('/daraz-sync/scan-failed-delivery', body: <String, dynamic>{'history_days': 40}),
      ]);
      await _load(silent: true);
      if (mounted) showAppSnackBar(context, 'Synced latest return & failed delivery records from Daraz (Last 40 days).');
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Sync completed with cached records.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _getStoreDisplayName(CentralOrderItem item) {
    if (item.storeName.isNotEmpty && item.storeName != '-' && item.storeName != 'null') {
      return item.storeName;
    }
    if (item.storeId.isNotEmpty) {
      final match = _stores.where((s) => s.id == item.storeId || s.code == item.storeCode).firstOrNull;
      if (match != null && match.name.isNotEmpty && match.name != '-') {
        return match.name;
      }
    }
    if (item.storeCode.isNotEmpty && item.storeCode != '-') {
      final match = _stores.where((s) => s.code == item.storeCode).firstOrNull;
      if (match != null && match.name.isNotEmpty) {
        return match.name;
      }
      return item.storeCode;
    }
    return 'Daraz Store';
  }

  DateTime? _getReturnEventDate(CentralOrderItem item) {
    return item.claimDate ?? item.hubArrivedAt ?? item.logisticFacilityAt ?? item.createdAt;
  }

  bool _isWithinLast40Days(CentralOrderItem item) {
    final eventDate = _getReturnEventDate(item);
    if (eventDate == null) return true;
    final daysAgo = DateTime.now().difference(eventDate).inDays;
    return daysAgo <= 40;
  }

  bool _isRealCustomerReturnReason(String text) {
    final norm = text.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), ' ').trim();
    if (norm.isEmpty) return false;
    return norm.contains('defective') ||
        norm.contains('not working') ||
        norm.contains('wrong item') ||
        norm.contains('damaged') ||
        norm.contains('broken') ||
        norm.contains('missing parts') ||
        norm.contains('missing items') ||
        norm.contains('counterfeit') ||
        norm.contains('poor quality') ||
        norm.contains('quality not as expected') ||
        norm.contains('different from description') ||
        norm.contains('change of mind') ||
        norm.contains('rma') ||
        norm.contains('customer return') ||
        norm.contains('buyer return') ||
        norm.contains('return request') ||
        norm.contains('refund request');
  }

  bool _isCancelledOrder(CentralOrderItem item) {
    final status = item.status.toLowerCase();
    final category = item.statusCategory.toLowerCase();
    final reason = item.returnReason.toLowerCase();
    return status.contains('cancel') ||
        category.contains('cancel') ||
        status == 'closed' ||
        category == 'closed' ||
        reason.contains('seller asked me to cancel') ||
        reason.contains('out of stock') ||
        reason.contains('item is out of stock') ||
        reason.contains('buyer asked to cancel') ||
        reason.contains('cancelled') ||
        reason.contains('canceled') ||
        reason.contains('unpaid') ||
        reason.contains('payment failed') ||
        reason.contains('failed payment');
  }

  bool _isFailedDeliveryReason(String text) {
    final norm = text.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), ' ').trim();
    if (norm.isEmpty) return false;
    return norm.contains('rejected at doorstep') ||
        norm.contains('customer rescheduled outside') ||
        norm.contains('delivery sla') ||
        norm.contains('others missing mapping') ||
        norm.contains('delivery address is wrong') ||
        norm.contains('delivery address wrong') ||
        norm.contains('address is wrong') ||
        norm.contains('wrong address') ||
        norm.contains('address not found') ||
        norm.contains('incorrect address') ||
        norm.contains('invalid address') ||
        norm.contains('incomplete address') ||
        norm.contains('fake address') ||
        norm.contains('refused to accept') ||
        norm.contains('refused delivery') ||
        norm.contains('refused') ||
        norm.contains('consignee not available') ||
        norm.contains('customer not available') ||
        norm.contains('customer unreachable') ||
        norm.contains('phone switched off') ||
        norm.contains('no answer') ||
        norm.contains('premises closed') ||
        norm.contains('out of delivery area') ||
        norm.contains('failed delivery') ||
        norm.contains('delivery failed') ||
        norm.contains('delivery attempt failed') ||
        norm.contains('unable to deliver') ||
        norm.contains('undelivered') ||
        norm.contains('return to seller') ||
        norm.contains('returned to shipper');
  }

  bool _isFailedDeliveryOrder(CentralOrderItem item) {
    if (_isCancelledOrder(item)) return false;

    // Explicit Failed Delivery signals
    if (item.isFailedDelivery) return true;
    if (_isFailedDeliveryReason(item.returnReason)) return true;
    if (_isFailedDeliveryReason(item.status)) return true;
    if (_isFailedDeliveryReason(item.reasonLabel)) return true;
    if (_isFailedDeliveryReason(item.hubName)) return true;

    // Center/hub arrived parcel that is NOT a customer return
    if ((item.hubArrivedAt != null || item.logisticFacilityAt != null) && !_isCustomerReturnOrder(item)) {
      return true;
    }
    return false;
  }

  bool _isCustomerReturnOrder(CentralOrderItem item) {
    if (_isCancelledOrder(item)) return false;
    // Failed delivery orders are NEVER customer returns
    if (item.isFailedDelivery) return false;
    if (_isFailedDeliveryReason(item.returnReason)) return false;
    if (_isFailedDeliveryReason(item.status)) return false;
    if (_isFailedDeliveryReason(item.reasonLabel)) return false;
    if (_isFailedDeliveryReason(item.hubName)) return false;
    if (item.parcelType == 'failed_delivery' || item.statusCategory == 'failed_delivery') return false;

    // Genuine Customer Returns (parcel delivered/received by customer and then returned)
    final s = item.status.toLowerCase().trim();
    final cat = item.statusCategory.toLowerCase().trim();
    final isExplicitReturnStatus = s == 'returned' ||
        s == 'customer_return' ||
        s == 'buyer_return' ||
        s == 'return_requested' ||
        s == 'returning' ||
        s == 'refund' ||
        s == 'refunded' ||
        cat == 'return' ||
        item.parcelType == 'return';

    return isExplicitReturnStatus ||
        item.claimDate != null ||
        _isRealCustomerReturnReason(item.returnReason) ||
        _isRealCustomerReturnReason(item.reasonLabel);
  }

  String? _getDisplayableReason(CentralOrderItem item) {
    bool isGenericOrStatus(String text) {
      final norm = text.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), ' ').trim();
      return norm.isEmpty ||
          norm == 'active sale' ||
          norm == 'failed delivery' ||
          norm == 'failed delivery generic' ||
          norm == 'failed' ||
          norm == 'customer return claim' ||
          norm == 'customer return' ||
          norm == 'rma generic return' ||
          norm == 'return' ||
          norm == 'returned' ||
          norm == 'order cancelled' ||
          norm == 'cancelled' ||
          norm == 'canceled' ||
          norm == 'unmapped daraz status' ||
          norm == 'pending' ||
          norm == 'shipped' ||
          norm == 'ready to ship' ||
          norm == 'delivered' ||
          norm == 'rts' ||
          norm == 'in transit' ||
          norm == 'none' ||
          norm == '-' ||
          norm == 'null';
    }

    final label = item.reasonLabel.trim();
    if (label.isNotEmpty && !isGenericOrStatus(label)) {
      return label.replaceAll('_', ' ');
    }

    final reason = item.returnReason.trim();
    if (reason.isNotEmpty && !isGenericOrStatus(reason)) {
      return reason.replaceAll('_', ' ');
    }

    final origReason = item.originalDarazReason.trim();
    if (origReason.isNotEmpty && !isGenericOrStatus(origReason)) {
      return origReason.replaceAll('_', ' ');
    }

    return null;
  }

  bool _isItemAlreadyReturned(CentralOrderItem item) {
    if (item.isCollected) return true;
    final category = item.statusCategory.toLowerCase();
    final collectionStatus = item.collectionStatus.toLowerCase();
    if (collectionStatus == 'collected' || collectionStatus == 'received' || category == 'collected') {
      return true;
    }

    final inspection = '${item.status} ${item.orderStatus} ${item.returnReason} ${item.errorMessage}'.toLowerCase();
    final norm = inspection.replaceAll(RegExp(r'[\s\-_\[\]!.,/]+'), ' ');

    return norm.contains('successfully returned') ||
        norm.contains('package returned') ||
        norm.contains('your parcel has been successfully returned') ||
        norm.contains('delivered to merchant') ||
        norm.contains('returned to merchant') ||
        norm.contains('return delivered') ||
        norm.contains('merchant collected') ||
        norm.contains('collected by seller') ||
        norm.contains('handed over to seller') ||
        norm.contains('delivered to shipper') ||
        norm.contains('returned to seller') ||
        norm.contains('delivered to origin') ||
        norm.contains('package collected');
  }

  bool _isDay5OrScrapRisk(CentralOrderItem item) {
    if (_isItemAlreadyReturned(item) || _isCancelledOrder(item)) return false;
    final daysLeft = item.daysLeftToCollect;
    final arrival = item.hubArrivedAt ?? item.logisticFacilityAt;
    int daysElapsed = 0;
    if (arrival != null) {
      daysElapsed = DateTime.now().difference(arrival).inDays + 1;
    }
    return daysElapsed >= 5 ||
        (daysLeft != null && daysLeft <= 1) ||
        item.collectionNotificationLevel == 'deadline' ||
        item.collectionNotificationLevel == 'one_day' ||
        item.collectionNotificationLevel == 'overdue';
  }

  Future<void> _markItemCollected(CentralOrderItem item) async {
    final id = item.id;
    if (id.isEmpty) return;

    // Optimistically update item to 'collected' so it is immediately removed from the active list
    setState(() {
      final index = _items.indexWhere((i) => i.id == id);
      if (index != -1) {
        _items[index] = _items[index].copyWith(
          collectionStatus: 'collected',
          statusCategory: 'collected',
          collectedAt: DateTime.now(),
          daysLeftToCollect: 0,
          collectionActionRequired: false,
          collectionNotificationLevel: 'collected',
        );
      }
      _selectedItemIds.remove(id);
    });

    try {
      ApiClient.instance.clearCache();
      await ApiClient.instance.post('/daraz-sync/order-items/$id/mark-received', body: <String, dynamic>{});
      if (mounted) showAppSnackBar(context, 'Order #${item.orderNumber} marked as collected and removed from active list.');
    } on ApiException catch (e) {
      if (mounted) {
        showAppSnackBar(context, e.message, error: true);
        await _load(silent: true);
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'Failed to update collection status.', error: true);
        await _load(silent: true);
      }
    }
  }

  Future<void> _markSelectedItemsCollected() async {
    if (_selectedItemIds.isEmpty) return;

    final targetIds = Set<String>.from(_selectedItemIds);
    final count = targetIds.length;

    setState(() {
      _batchActionLoading = true;
      // Optimistically update all selected items to collected
      for (var i = 0; i < _items.length; i++) {
        if (targetIds.contains(_items[i].id)) {
          _items[i] = _items[i].copyWith(
            collectionStatus: 'collected',
            statusCategory: 'collected',
            collectedAt: DateTime.now(),
            daysLeftToCollect: 0,
            collectionActionRequired: false,
            collectionNotificationLevel: 'collected',
          );
        }
      }
      _selectedItemIds.clear();
    });

    try {
      ApiClient.instance.clearCache();
      await Future.wait<dynamic>(
        targetIds.map((id) => ApiClient.instance.post('/daraz-sync/order-items/$id/mark-received', body: <String, dynamic>{})),
      );
      if (mounted) {
        showAppSnackBar(context, '$count selected parcel${count > 1 ? 's' : ''} marked as collected and removed from active list.');
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Error updating some items. Refreshing...', error: true);
        await _load(silent: true);
      }
    } finally {
      if (mounted) setState(() => _batchActionLoading = false);
    }
  }

  void _toggleSelectAll(List<CentralOrderItem> currentActiveItems) {
    setState(() {
      final uncollectedItems = currentActiveItems.where((item) => !_isItemAlreadyReturned(item)).toList();
      final allSelected = uncollectedItems.isNotEmpty && uncollectedItems.every((item) => _selectedItemIds.contains(item.id));
      if (allSelected) {
        for (final item in uncollectedItems) {
          _selectedItemIds.remove(item.id);
        }
      } else {
        for (final item in uncollectedItems) {
          if (item.id.isNotEmpty) {
            _selectedItemIds.add(item.id);
          }
        }
      }
    });
  }

  List<CentralOrderItem> get _filteredItems {
    final query = _search.trim().toLowerCase();

    return _items.where((item) {
      // Exclude cancelled orders completely
      if (_isCancelledOrder(item)) return false;

      final isFailed = _isFailedDeliveryOrder(item);
      final isReturn = _isCustomerReturnOrder(item);
      final isCompleted = _isItemAlreadyReturned(item);
      final isScrapRisk = _isDay5OrScrapRisk(item);

      // 1. Separate by Primary Section
      if (_primarySection == 'failed_delivery') {
        if (!isFailed) return false;
        // Never show collected/package returned in active failed delivery tab
        if (_subFilter != 'collected' && isCompleted) return false;
      } else if (_primarySection == 'returns') {
        if (!isReturn) return false;
        // ONLY show customer returns from the last 40 days
        if (!_isWithinLast40Days(item)) return false;
        if (_subFilter != 'collected' && isCompleted) return false;
      } else if (_primarySection == 'at_risk') {
        if (isCompleted || !isScrapRisk) return false;
      }

      // 2. Sub-filter: Active (auto-hide completed), Scrap Risk, or Collected Archive
      if (_primarySection != 'at_risk') {
        if (_subFilter == 'active') {
          // Automatically exclude / remove orders that have been successfully collected/returned
          if (isCompleted) return false;
        } else if (_subFilter == 'scrap_risk') {
          if (isCompleted || !isScrapRisk) return false;
        } else if (_subFilter == 'collected') {
          if (!isCompleted) return false;
        }
      }

      // 3. Search query match
      if (query.isNotEmpty) {
        final storeDisplay = _getStoreDisplayName(item).toLowerCase();
        final matches = item.title.toLowerCase().contains(query) ||
            item.orderNumber.toLowerCase().contains(query) ||
            item.sellerSku.toLowerCase().contains(query) ||
            item.hubName.toLowerCase().contains(query) ||
            item.storeName.toLowerCase().contains(query) ||
            storeDisplay.contains(query) ||
            item.returnReason.toLowerCase().contains(query);
        if (!matches) return false;
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);

    // Calculate counts for active non-cancelled items (Returns limited to last 40 days)
    final nonCancelledItems = _items.where((i) => !_isCancelledOrder(i)).toList();
    final activeFailedCount = nonCancelledItems.where((i) => _isFailedDeliveryOrder(i) && !_isItemAlreadyReturned(i)).length;
    final activeReturnsCount = nonCancelledItems.where((i) => _isCustomerReturnOrder(i) && !_isItemAlreadyReturned(i) && _isWithinLast40Days(i)).length;
    final urgentScrapRiskCount = nonCancelledItems.where((i) => !_isItemAlreadyReturned(i) && _isDay5OrScrapRisk(i)).length;

    final filteredList = _filteredItems;
    final activeUncollectedInView = filteredList.where((item) => !_isItemAlreadyReturned(item)).toList();

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
                        subtitle: _primarySection == 'returns'
                            ? 'Customer return claims from the last 40 days'
                            : 'Separate tracking for Hub Failed Delivery and Customer Return Claims',
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
                      _primarySegmentSelector(activeFailedCount, activeReturnsCount, urgentScrapRiskCount),
                      if (_primarySection != 'at_risk') ...<Widget>[
                        const SizedBox(height: 14),
                        _subFilterChips(urgentScrapRiskCount),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          hintText: _primarySection == 'failed_delivery'
                              ? 'Search failed delivery by store, title, order #, or hub...'
                              : (_primarySection == 'returns'
                                  ? 'Search returns (last 40 days) by store, product, or reason...'
                                  : 'Search at-risk parcels...'),
                          prefixIcon: const Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _search = val),
                      ),
                      const SizedBox(height: 12),

                      // Multi-Select Batch Action Bar
                      if (_subFilter != 'collected' && activeUncollectedInView.isNotEmpty) ...<Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _selectedItemIds.isNotEmpty ? AppTheme.primary : AppTheme.borderColor(context),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Checkbox(
                                value: activeUncollectedInView.isNotEmpty &&
                                    activeUncollectedInView.every((i) => _selectedItemIds.contains(i.id)),
                                onChanged: (_) => _toggleSelectAll(activeUncollectedInView),
                                activeColor: AppTheme.primary,
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  _selectedItemIds.isEmpty
                                      ? 'Select all to mark collected (${activeUncollectedInView.length})'
                                      : '${_selectedItemIds.length} parcel${_selectedItemIds.length > 1 ? 's' : ''} selected',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: _selectedItemIds.isNotEmpty ? AppTheme.primary : AppTheme.textMutedColor(context),
                                  ),
                                ),
                              ),
                              if (_selectedItemIds.isNotEmpty) ...<Widget>[
                                TextButton(
                                  onPressed: () => setState(() => _selectedItemIds.clear()),
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                  ),
                                  child: const Text('Clear', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                                ),
                                const SizedBox(width: 6),
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _primarySection == 'returns' ? AppTheme.warning : AppTheme.primary,
                                    foregroundColor: Colors.white,
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  onPressed: _batchActionLoading ? null : _markSelectedItemsCollected,
                                  icon: _batchActionLoading
                                      ? const SizedBox(
                                          width: 13,
                                          height: 13,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Icon(Icons.check_circle_outline_rounded, size: 14),
                                  label: Text(
                                    'Mark Collected (${_selectedItemIds.length})',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      if (filteredList.isEmpty)
                        EmptyState(
                          title: _primarySection == 'failed_delivery'
                              ? (_subFilter == 'active' ? 'No Pending Failed Deliveries 🎉' : 'No records found')
                              : (_primarySection == 'returns'
                                  ? (_subFilter == 'active' ? 'No Customer Returns in Last 40 Days 🎉' : 'No return claims found')
                                  : 'No Parcels at Scrap Risk 🎉'),
                          message: _primarySection == 'at_risk'
                              ? 'None of your packages have been at the center for 5+ days. All parcels are safe.'
                              : (_subFilter == 'active'
                                  ? (_primarySection == 'returns'
                                      ? 'No pending return claims recorded in the last 40 days.'
                                      : 'All packages have either been successfully returned to your warehouse or there are no new orders at the Daraz hub.')
                                  : 'Try adjusting your search query or switching tabs.'),
                          icon: Icons.check_circle_outline_rounded,
                        )
                      else
                        ...filteredList.map(_buildSeparateParcelCard),
                    ],
                  ),
                ),
    );
  }

  Widget _primarySegmentSelector(int failedCount, int returnsCount, int scrapCount) {
    final isDark = AppTheme.isDark(context);

    Widget buildTab({
      required String key,
      required String label,
      required IconData icon,
      required int count,
      required Color color,
      required Color softColor,
    }) {
      final isSelected = _primarySection == key;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() {
            _primarySection = key;
            _subFilter = 'active';
            _selectedItemIds.clear();
          }),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            decoration: BoxDecoration(
              color: isSelected ? (isDark ? const Color(0xFF0F172A) : Colors.white) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              boxShadow: isSelected
                  ? <BoxShadow>[
                      BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2)),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(icon, size: 14, color: isSelected ? color : AppTheme.textMutedColor(context)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: isSelected ? AppTheme.textPrimaryColor(context) : AppTheme.textMutedColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: isSelected ? softColor : (isDark ? Colors.black38 : Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: isSelected ? color : AppTheme.textMutedColor(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Row(
        children: <Widget>[
          buildTab(
            key: 'failed_delivery',
            label: 'Failed Delivery',
            icon: Icons.local_shipping_rounded,
            count: failedCount,
            color: AppTheme.primary,
            softColor: AppTheme.primarySoft,
          ),
          buildTab(
            key: 'returns',
            label: 'Returns (40d)',
            icon: Icons.assignment_return_rounded,
            count: returnsCount,
            color: AppTheme.warning,
            softColor: AppTheme.warningSoft,
          ),
          buildTab(
            key: 'at_risk',
            label: '🚨 At Risk (Day 5+)',
            icon: Icons.warning_amber_rounded,
            count: scrapCount,
            color: AppTheme.danger,
            softColor: AppTheme.dangerSoft,
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
      onSelected: (_) => setState(() {
        _subFilter = key;
        _selectedItemIds.clear();
      }),
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
    final isDark = AppTheme.isDark(context);
    final isReturn = item.isReturn;
    final isCompleted = _isItemAlreadyReturned(item);
    final isSelected = _selectedItemIds.contains(item.id);
    final daysLeft = item.daysLeftToCollect;
    final hubName = item.hubName.isNotEmpty ? item.hubName : 'Daraz Logistics Center';
    final arrivalDate = item.hubArrivedAt ?? item.logisticFacilityAt;
    final deadlineDate = item.collectionDeadlineAt;
    final storeName = _getStoreDisplayName(item);
    final returnEventDate = _getReturnEventDate(item);

    // Calculate deadline & scrap urgency
    int daysElapsed = 0;
    if (arrivalDate != null) {
      daysElapsed = DateTime.now().difference(arrivalDate).inDays + 1;
    }
    final isDay5Or6 = daysElapsed >= 5 ||
        (daysLeft != null && daysLeft <= 1) ||
        item.collectionNotificationLevel == 'deadline' ||
        item.collectionNotificationLevel == 'one_day' ||
        item.collectionNotificationLevel == 'overdue';

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
      limitText = '🚨 Day 6/6: Due Today (Scrap Risk)';
    } else if (daysElapsed >= 5 || (daysLeft != null && daysLeft == 1)) {
      countdownColor = AppTheme.danger;
      countdownSoftColor = AppTheme.dangerSoft;
      limitText = '🚨 Day 5/6: 24h Before Scrap!';
    } else if (daysElapsed > 0 && daysLeft != null) {
      countdownColor = daysLeft <= 3 ? AppTheme.warning : AppTheme.info;
      countdownSoftColor = daysLeft <= 3 ? AppTheme.warningSoft : AppTheme.infoSoft;
      limitText = '⚠️ Day $daysElapsed of 6 ($daysLeft Days Left)';
    } else if (daysLeft != null) {
      countdownColor = AppTheme.info;
      countdownSoftColor = AppTheme.infoSoft;
      limitText = '📦 $daysLeft Days Left at Hub';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        borderColor: isSelected ? AppTheme.primary : (isDay5Or6 && !isCompleted ? AppTheme.danger.withValues(alpha: 0.5) : null),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Top Bar: Store Name Badge & Checkbox / Selection
            Row(
              children: <Widget>[
                if (!isCompleted) ...<Widget>[
                  InkWell(
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedItemIds.remove(item.id);
                        } else if (item.id.isNotEmpty) {
                          _selectedItemIds.add(item.id);
                        }
                      });
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        isSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                        color: isSelected ? AppTheme.primary : AppTheme.textMutedColor(context),
                        size: 20,
                      ),
                    ),
                  ),
                ],
                // Store Name Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFEEF2F6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.storefront_rounded, size: 13, color: AppTheme.primary),
                      const SizedBox(width: 5),
                      Text(
                        storeName,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (returnEventDate != null && isReturn)
                  Text(
                    'Return Date: ${Formatters.date(returnEventDate)}',
                    style: TextStyle(
                      color: AppTheme.textMutedColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            if (isDay5Or6 && !isCompleted) ...<Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.dangerSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: <Widget>[
                    Icon(Icons.warning_rounded, color: AppTheme.danger, size: 16),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Day 5+ Alert: Package at risk of being scrapped by Daraz Center!',
                        style: TextStyle(color: AppTheme.danger, fontSize: 11, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

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
                        'Order #${item.orderNumber.isNotEmpty ? item.orderNumber : item.externalOrderItemId}',
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
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        'Daraz Status: ${item.status.replaceAll('_', ' ').toUpperCase()}',
                        style: TextStyle(
                          color: AppTheme.textMutedColor(context),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  if (item.isUnknownReviewNeeded) ...<Widget>[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.warningSoft,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.rate_review_outlined, color: AppTheme.warning, size: 13),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '⚠️ Review Needed: ${item.reviewReason.isNotEmpty ? item.reviewReason : (item.originalDarazReason.isNotEmpty ? item.originalDarazReason : item.originalDarazStatus)}',
                              style: const TextStyle(color: AppTheme.warning, fontSize: 10, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (_getDisplayableReason(item) != null) ...<Widget>[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isReturn ? AppTheme.warningSoft : AppTheme.infoSoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Reason: ${_getDisplayableReason(item)!}',
                        style: TextStyle(
                          color: isReturn ? AppTheme.warning : AppTheme.info,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
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
