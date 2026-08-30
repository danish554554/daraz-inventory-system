import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/formatters.dart';
import '../services/report_generator_service.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  String _search = '';
  String _activeTab = 'all'; // all, orders, adjustments, pending_cost

  String _selectedPeriod = 'all';
  String _selectedStoreId = 'all';

  List<StatementPeriodModel> _periods = <StatementPeriodModel>[];
  List<StoreModel> _stores = <StoreModel>[];
  FinanceSummary _summary = FinanceSummary.empty();
  List<FinanceEntry> _entries = <FinanceEntry>[];
  List<InventoryItem> _inventory = <InventoryItem>[];

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
      final periodParam = _selectedPeriod == 'all' ? '' : _selectedPeriod;
      final storeParam = _selectedStoreId == 'all' ? '' : _selectedStoreId;

      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        ApiClient.instance.get(
          '/finance/summary',
          queryParameters: <String, dynamic>{
            if (periodParam.isNotEmpty) 'statement_period': periodParam,
            if (storeParam.isNotEmpty) 'store_id': storeParam,
          },
          bypassCache: true,
        ),
        ApiClient.instance.get(
          '/finance',
          queryParameters: <String, dynamic>{
            if (periodParam.isNotEmpty) 'statement_period': periodParam,
            if (storeParam.isNotEmpty) 'store_id': storeParam,
          },
          bypassCache: true,
        ),
        ApiClient.instance.get('/finance/periods'),
        ApiClient.instance.get('/stores'),
        ApiClient.instance.get('/central-inventory'),
      ]);

      final summaryMap = JsonReaders.map(results[0]);
      final entriesList = JsonReaders.list(results[1]).map((e) => FinanceEntry.fromJson(JsonReaders.map(e))).toList();
      final periodsData = JsonReaders.map(results[2]);
      final periodsList = JsonReaders.list(periodsData['periods']).map((p) => StatementPeriodModel.fromJson(JsonReaders.map(p))).toList();
      final storesList = JsonReaders.list(results[3]).map((s) => StoreModel.fromJson(JsonReaders.map(s))).toList();
      final invList = JsonReaders.list(results[4]).map((e) => InventoryItem.fromJson(JsonReaders.map(e))).toList();

      if (mounted) {
        setState(() {
          _summary = FinanceSummary.fromJson(summaryMap);
          _entries = entriesList;
          _periods = periodsList;
          _stores = storesList;
          _inventory = invList;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed to load finance records.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncFromDaraz({String? period, bool silent = false}) async {
    final targetPeriod = period ?? _selectedPeriod;
    if (!silent && mounted) {
      showAppSnackBar(context, 'Connecting to Daraz API & importing statement...');
    }
    setState(() => _syncing = true);
    try {
      final response = await ApiClient.instance.post(
        '/finance/sync',
        body: <String, dynamic>{
          if (targetPeriod != 'all') 'statement_period': targetPeriod,
          if (_selectedStoreId != 'all') 'store_id': _selectedStoreId,
        },
        timeout: const Duration(seconds: 90),
      );
      final respMap = JsonReaders.map(response);
      final msg = JsonReaders.string(respMap, 'message', 'Statements synchronized successfully.');
      if (mounted) {
        showAppSnackBar(context, msg);
      }
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed to sync from Daraz API: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  List<FinanceEntry> get _filteredEntries {
    final query = _search.trim().toLowerCase();
    return _entries.where((item) {
      // Filter by tab
      if (_activeTab == 'orders' && !item.isOrder) return false;
      if (_activeTab == 'adjustments' && !item.isAdjustment) return false;
      if (_activeTab == 'pending_cost') {
        if (!item.isOrder || item.isProfitReady || item.productPrice == 0) return false;
      }

      // Filter by search
      if (query.isNotEmpty) {
        final matches = item.orderNumber.toLowerCase().contains(query) ||
            item.orderLineId.toLowerCase().contains(query) ||
            item.sellerSku.toLowerCase().contains(query) ||
            item.productName.toLowerCase().contains(query) ||
            item.adjustmentReason.toLowerCase().contains(query) ||
            item.storeName.toLowerCase().contains(query);
        if (!matches) return false;
      }

      return true;
    }).toList();
  }

  void _openPeriodPickerSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.cardColor(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        'Statement Period',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.textPrimaryColor(context),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  Text(
                    'Select a weekly payout cycle (Monday - Sunday) to filter statements & profit',
                    style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: <Widget>[
                        _periodTile(
                          title: 'All Statement Cycles (Consolidated)',
                          isSelected: _selectedPeriod == 'all',
                          hasData: true,
                          onTap: () {
                            setState(() => _selectedPeriod = 'all');
                            Navigator.pop(context);
                            _load();
                          },
                        ),
                        const Divider(height: 12),
                        ..._periods.map((p) {
                          final isSel = _selectedPeriod == p.statementPeriod;
                          return _periodTile(
                            title: p.statementPeriod,
                            isCurrent: p.isCurrent,
                            hasData: p.hasData,
                            isSelected: isSel,
                            onTap: () async {
                              final targetPeriod = p.statementPeriod;
                              setState(() => _selectedPeriod = targetPeriod);
                              Navigator.pop(context);
                              // Automatically import statement from Daraz for this cycle
                              await _syncFromDaraz(period: targetPeriod);
                            },
                          );
                        }),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _periodTile({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
    bool isCurrent = false,
    bool hasData = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.12)
              : hasData
                  ? AppTheme.softGreyColor(context)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? AppTheme.primary
                : hasData
                    ? AppTheme.borderColor(context)
                    : Colors.transparent,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isSelected ? Icons.radio_button_checked_rounded : Icons.calendar_today_outlined,
              size: 18,
              color: isSelected ? AppTheme.primary : AppTheme.textMutedColor(context),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.w700,
                  fontSize: 13,
                  color: isSelected ? AppTheme.primary : AppTheme.textPrimaryColor(context),
                ),
              ),
            ),
            if (isCurrent)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.infoSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'CURRENT',
                  style: TextStyle(color: AppTheme.info, fontSize: 10, fontWeight: FontWeight.w900),
                ),
              ),
            if (hasData && !isCurrent)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.successSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'DATA',
                  style: TextStyle(color: AppTheme.success, fontSize: 10, fontWeight: FontWeight.w900),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openImportSheet() async {
    final imported = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.cardColor(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => FinanceCsvImportSheet(stores: _stores),
    );
    if (imported == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Weekly finance statement imported and profits calculated.');
    }
  }

  Future<void> _openSetCostDialog(FinanceEntry entry) async {
    final sku = entry.sellerSku.trim();
    final name = entry.productName.isNotEmpty ? entry.productName : sku;
    final costController = TextEditingController();

    // Look for matching inventory item
    final matched = _inventory.where((i) => i.sellerSku.toLowerCase() == sku.toLowerCase()).firstOrNull;
    if (matched != null && (matched.costPrice > 0 || matched.purchasePrice > 0)) {
      final c = matched.costPrice > 0 ? matched.costPrice : matched.purchasePrice;
      costController.text = c.toStringAsFixed(c.truncateToDouble() == c ? 0 : 2);
    } else if (entry.costPrice > 0) {
      costController.text = entry.costPrice.toStringAsFixed(entry.costPrice.truncateToDouble() == entry.costPrice ? 0 : 2);
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.cardColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.price_change_outlined, color: AppTheme.primary, size: 20),
            ),
            const SizedBox(width: 10),
            Text(
              'Set Purchase Cost Price',
              style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textPrimaryColor(context), fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'SKU: $sku',
              style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: costController,
              labelText: 'Purchase / Restock Cost per item (PKR)',
              hintText: 'e.g. 350',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            Text(
              'Saving will update your Central Inventory and instantly recalculate net profit across all statements.',
              style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save & Recalculate Profit'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final cost = double.tryParse(costController.text.trim()) ?? 0;
      if (cost <= 0) {
        if (mounted) showAppSnackBar(context, 'Please enter a valid cost price.', error: true);
        return;
      }

      try {
        await ApiClient.instance.post(
          '/finance/set-cost',
          body: <String, dynamic>{
            'seller_sku': sku,
            'cost_price': cost,
          },
        );
        await _load(silent: true);
        if (mounted) showAppSnackBar(context, 'Cost price saved! Profits recalculated for SKU $sku.');
      } catch (e) {
        if (mounted) showAppSnackBar(context, 'Error updating cost: $e', error: true);
      }
    }
  }

  void _openFeeBreakdownModal(FinanceEntry item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.cardColor(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        final isProfitReady = item.isProfitReady;
        final netProfit = item.netProfit ?? 0;
        final margin = item.profitMargin;

        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.isAdjustment ? 'Adjustment Details' : 'Profit & Settlement Details',
                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: AppTheme.textPrimaryColor(context)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.isAdjustment ? 'Statement #${item.statementNumber}' : 'Order #${item.orderNumber}',
                          style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                ],
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    _breakdownHeader(item),
                    const SizedBox(height: 14),
                    // High-Impact Profit Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: AppTheme.heroGradient,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              Text(
                                item.isAdjustment ? 'ADJUSTMENT IMPACT' : 'TRUE NET PROFIT',
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              if (isProfitReady)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    gradient: AppTheme.profitGradient,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${margin >= 0 ? '+' : ''}${margin.toStringAsFixed(1)}% Margin',
                                    style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w900),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            item.isAdjustment
                                ? 'PKR ${Formatters.money(item.netSettlement)}'
                                : (isProfitReady ? 'PKR ${Formatters.money(netProfit)}' : 'Cost Not Set'),
                            style: TextStyle(
                              color: item.isAdjustment
                                  ? (item.netSettlement >= 0 ? AppTheme.success : AppTheme.danger)
                                  : (isProfitReady ? (netProfit >= 0 ? AppTheme.success : AppTheme.danger) : Colors.white),
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Net Received: PKR ${Formatters.money(item.netSettlement)}',
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
                                ),
                                if (isProfitReady) ...<Widget>[
                                  const SizedBox(height: 3),
                                  Text(
                                    'Stock Cost (COGS): -PKR ${Formatters.money(item.totalCost)}',
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11, fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _breakdownSectionTitle('Financial Summary'),
                    _breakdownRow('Gross Sales Amount', '+PKR ${Formatters.money(item.grossAmount)}', isBold: true, color: AppTheme.success),
                    if (item.totalFees > 0)
                      _breakdownRow('Daraz Marketplace Fees', '-PKR ${Formatters.money(item.totalFees)}', color: AppTheme.danger),
                    if (item.totalTaxes > 0)
                      _breakdownRow('Taxes & Withholdings (WHT / VAT)', '-PKR ${Formatters.money(item.totalTaxes)}', color: AppTheme.warning),
                    _breakdownRow(
                      item.orderStatus.toLowerCase().contains('return') ? 'Net Return Settlement' : 'Net Settlement Payout',
                      '${item.netSettlement >= 0 ? '' : '-'}PKR ${Formatters.money(item.netSettlement.abs())}',
                      isBold: true,
                      color: item.netSettlement >= 0 ? AppTheme.primary : AppTheme.danger,
                    ),
                    if (item.isOrder) ...<Widget>[
                      if (item.orderStatus.toLowerCase().contains('return'))
                        _breakdownRow('Stock Cost (COGS)', 'PKR 0.00 (Restocked)', color: AppTheme.info)
                      else
                        _breakdownRow('Stock Purchase Cost (COGS)', '-PKR ${Formatters.money(item.totalCost)}', color: isProfitReady ? AppTheme.danger : AppTheme.textMutedColor(context)),
                      _breakdownRow(
                        item.orderStatus.toLowerCase().contains('return') ? 'Exact Return Result' : 'True Net Profit',
                        isProfitReady ? '${netProfit >= 0 ? '+' : ''}PKR ${Formatters.money(netProfit)}' : 'Set purchase price to see profit',
                        isBold: true,
                        color: isProfitReady ? (netProfit >= 0 ? AppTheme.success : AppTheme.danger) : AppTheme.danger,
                      ),
                    ],
                    if (item.adjustmentReason.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 14),
                      _breakdownSectionTitle('Adjustment Reason / Comments'),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.warningSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          item.adjustmentReason,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.warning),
                        ),
                      ),
                    ],
                    if (item.feeBreakdown.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      _breakdownSectionTitle('Itemized Statement Breakdown'),
                      ...item.feeBreakdown.entries.map((e) {
                        final val = e.value;
                        return _breakdownRow(
                          e.key,
                          '${val >= 0 ? '+' : ''}PKR ${Formatters.money(val)}',
                          color: val >= 0 ? AppTheme.success : AppTheme.danger,
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _breakdownHeader(FinanceEntry item) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.softGreyColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (item.productName.isNotEmpty) ...<Widget>[
            Text(
              item.productName,
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: AppTheme.textPrimaryColor(context)),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'SKU: ${item.sellerSku.isEmpty ? 'N/A' : item.sellerSku}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              if (item.storeName.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      '🏬 ${item.storeName}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.primary, fontSize: 10, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (item.statementPeriod.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text('Period: ${item.statementPeriod}', style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }

  Widget _breakdownSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: AppTheme.textMutedColor(context), letterSpacing: 0.5),
      ),
    );
  }

  Widget _breakdownRow(String label, String value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
              color: isBold ? AppTheme.textPrimaryColor(context) : AppTheme.textMutedColor(context),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isBold ? FontWeight.w900 : FontWeight.w700,
              color: color ?? (isBold ? AppTheme.textPrimaryColor(context) : AppTheme.textPrimaryColor(context)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearData() async {
    final isPeriodSelected = _selectedPeriod != 'all';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.cardColor(context),
        title: Text(
          isPeriodSelected ? 'Clear "$_selectedPeriod" Data?' : 'Clear All Finance Statements?',
          style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900),
        ),
        content: Text(
          isPeriodSelected
              ? 'This will remove all imported finance records for this weekly statement cycle.'
              : 'This will permanently remove all imported finance statements and profit calculations.',
          style: TextStyle(color: AppTheme.textMutedColor(context)),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final queryParam = isPeriodSelected ? <String, dynamic>{'statement_period': _selectedPeriod} : null;
        await ApiClient.instance.delete('/finance/clear', queryParameters: queryParam);
        await _load(silent: true);
        if (mounted) showAppSnackBar(context, 'Finance data cleared successfully.');
      } catch (e) {
        if (mounted) showAppSnackBar(context, 'Failed to clear finance data: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading weekly financial statements...')
          : _error != null
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: EmptyState(
                      title: 'Finance center unavailable',
                      message: _error!,
                      icon: Icons.account_balance_wallet_outlined,
                    ),
                  ),
                )
              : AppShell(
                  onRefresh: () => _load(silent: true),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SectionHeader(
                        title: 'Finance & Profit',
                        subtitle: 'Daraz weekly settlement cycles, fee itemization & true profit',
                        action: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            CircleIconButton(
                              icon: Icons.sync_rounded,
                              onPressed: _syncing ? null : () => _syncFromDaraz(),
                              background: AppTheme.primary,
                              foreground: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            CircleIconButton(
                              icon: Icons.upload_file_rounded,
                              onPressed: _openImportSheet,
                              background: AppTheme.softGreyColor(context),
                              foreground: AppTheme.textPrimaryColor(context),
                            ),
                            const SizedBox(width: 8),
                            CircleIconButton(
                              icon: Icons.delete_sweep_rounded,
                              onPressed: _confirmClearData,
                              background: AppTheme.dangerSoft,
                              foreground: AppTheme.danger,
                            ),
                            const SizedBox(width: 8),
                            CircleIconButton(
                              icon: Icons.share_rounded,
                              onPressed: () {
                                ReportGeneratorService.shareDailySummary(
                                  historySummary: <String, dynamic>{
                                    'total_orders': _summary.totalOrders,
                                    'gross_amount': _summary.grossAmount,
                                    'net_settlement': _summary.netSettlement,
                                    'net_profit': _summary.netProfit,
                                    'final_profit_after_adjustments': _summary.finalProfitAfterAdjustments,
                                  },
                                  orders: const <CentralOrder>[],
                                  lowStockItems: const <InventoryItem>[],
                                  period: _selectedPeriod == 'all' ? 'All Cycles' : _selectedPeriod,
                                  connectedStoresCount: _stores.length,
                                  totalStoresCount: _stores.length,
                                );
                              },
                              background: AppTheme.success,
                              foreground: Colors.white,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _periodSelectorBar(),
                      const SizedBox(height: 12),
                      if (_stores.length > 1) ...<Widget>[
                        _storeSelectorBar(),
                        const SizedBox(height: 12),
                      ],
                      _heroFinanceCard(),
                      const SizedBox(height: 14),
                      _feeBreakdownGrid(context),
                      const SizedBox(height: 16),
                      _filterTabs(),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Search order #, line ID, SKU, product, or reason...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          isDense: true,
                          filled: true,
                          fillColor: AppTheme.cardColor(context),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.borderColor(context))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.borderColor(context))),
                        ),
                        onChanged: (val) => setState(() => _search = val),
                      ),
                      const SizedBox(height: 14),
                      if (_filteredEntries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 20),
                          child: EmptyState(
                            title: _entries.isEmpty ? 'No statement records found' : 'No matching entries',
                            message: _entries.isEmpty
                                ? (_selectedPeriod != 'all'
                                    ? 'No imported records for "$_selectedPeriod". Tap below to automatically sync this payout cycle directly from Daraz Seller Center.'
                                    : 'Import statement records from Daraz API or select a weekly cycle above.')
                                : 'Try changing your search keywords or filter tab.',
                            icon: Icons.receipt_long_outlined,
                            action: _entries.isEmpty
                                ? PrimaryButton(
                                    label: _syncing ? 'Syncing statement...' : 'Sync Statement via Daraz API',
                                    icon: Icons.sync_rounded,
                                    loading: _syncing,
                                    onPressed: () => _syncFromDaraz(),
                                  )
                                : null,
                          ),
                        )
                      else
                        ..._filteredEntries.map(_buildFinanceRow),
                    ],
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openImportSheet,
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.upload_file_rounded),
        label: const Text('Import Statement CSV', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }

  Widget _periodSelectorBar() {
    final isPeriodActive = _selectedPeriod != 'all';
    return InkWell(
      onTap: _openPeriodPickerSheet,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isPeriodActive ? AppTheme.primary.withValues(alpha: 0.1) : AppTheme.cardColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPeriodActive ? AppTheme.primary : AppTheme.borderColor(context),
            width: isPeriodActive ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isPeriodActive ? AppTheme.primary : AppTheme.softGreyColor(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.calendar_month_rounded,
                size: 18,
                color: isPeriodActive ? Colors.white : AppTheme.textPrimaryColor(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'STATEMENT PERIOD',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: isPeriodActive ? AppTheme.primary : AppTheme.textMutedColor(context),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isPeriodActive ? _selectedPeriod : 'All Weekly Cycles (Consolidated)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: isPeriodActive ? AppTheme.primary : AppTheme.textPrimaryColor(context),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              color: isPeriodActive ? AppTheme.primary : AppTheme.textMutedColor(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _storeSelectorBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _storeChip('all', '🏬 All Stores'),
          ..._stores.map((s) => _storeChip(s.id, '🏬 ${s.name}')),
        ],
      ),
    );
  }

  Widget _storeChip(String storeId, String label) {
    final selected = _selectedStoreId == storeId;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) {
          setState(() => _selectedStoreId = storeId);
          _load();
        },
        selectedColor: AppTheme.primary,
        backgroundColor: AppTheme.cardColor(context),
        labelStyle: TextStyle(
          color: selected ? Colors.white : AppTheme.textPrimaryColor(context),
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
        side: BorderSide(color: selected ? AppTheme.primary : AppTheme.borderColor(context)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  Widget _heroFinanceCard() {
    final netSettlement = _summary.netSettlement;
    final finalProfit = _summary.finalProfitAfterAdjustments;
    final grossAmount = _summary.grossAmount;
    final totalDeductions = _summary.totalDeductions;
    final totalOrders = _summary.totalOrders;
    final pendingCost = _summary.pendingCostOrders;
    final margin = _summary.marginPercent;

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
                    child: const Icon(Icons.account_balance_wallet_rounded, color: AppTheme.success, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'DARAZ NET SETTLEMENT',
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
                ),
                child: Text(
                  margin != 0 ? '${margin > 0 ? '+' : ''}${margin.toStringAsFixed(1)}% Margin' : 'Margin --',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'PKR ${Formatters.money(netSettlement)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'True Net Profit: PKR ${Formatters.money(finalProfit)} · Gross: PKR ${Formatters.money(grossAmount)}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                _statMini('Total Orders', '$totalOrders'),
                _verticalBar(),
                _statMini('Daraz Deductions', 'PKR ${Formatters.money(totalDeductions)}'),
                _verticalBar(),
                _statMini('Pending Cost', '$pendingCost SKUs', isAlert: pendingCost > 0),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statMini(String label, String val, {bool isAlert = false}) {
    return Column(
      children: <Widget>[
        Text(val, style: TextStyle(color: isAlert ? AppTheme.warning : Colors.white, fontWeight: FontWeight.w900, fontSize: 13)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 10, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _verticalBar() {
    return Container(width: 1, height: 24, color: Colors.white.withValues(alpha: 0.15));
  }

  Widget _feeBreakdownGrid(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 44) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Gross Sales',
            value: 'PKR ${Formatters.money(_summary.grossAmount)}',
            icon: Icons.storefront_outlined,
            tint: AppTheme.primarySoft,
            iconColor: AppTheme.primary,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Daraz Fees',
            value: 'PKR ${Formatters.money(_summary.totalFees)}',
            icon: Icons.receipt_outlined,
            tint: AppTheme.dangerSoft,
            iconColor: AppTheme.danger,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Taxes (WHT / VAT)',
            value: 'PKR ${Formatters.money(_summary.totalTaxes)}',
            icon: Icons.account_balance_outlined,
            tint: AppTheme.warningSoft,
            iconColor: AppTheme.warning,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Net Settlement (Payout)',
            value: 'PKR ${Formatters.money(_summary.netSettlement)}',
            icon: Icons.payments_outlined,
            tint: AppTheme.successSoft,
            iconColor: AppTheme.success,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Stock Cost (COGS)',
            value: 'PKR ${Formatters.money(_summary.totalCost)}',
            icon: Icons.inventory_2_outlined,
            tint: AppTheme.infoSoft,
            iconColor: AppTheme.info,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'True Profit Realized',
            value: 'PKR ${Formatters.money(_summary.finalProfitAfterAdjustments)}',
            icon: Icons.trending_up_rounded,
            tint: _summary.finalProfitAfterAdjustments >= 0 ? AppTheme.successSoft : AppTheme.dangerSoft,
            iconColor: _summary.finalProfitAfterAdjustments >= 0 ? AppTheme.success : AppTheme.danger,
          ),
        ),
      ],
    );
  }

  Widget _filterTabs() {
    final pendingCount = _summary.pendingCostOrders;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _tabChip('all', 'All Entries (${_entries.length})'),
          const SizedBox(width: 8),
          _tabChip('orders', 'Orders (${_summary.totalOrders})'),
          const SizedBox(width: 8),
          _tabChip('adjustments', 'Adjustments (${_summary.totalAdjustments})'),
          if (pendingCount > 0) ...<Widget>[
            const SizedBox(width: 8),
            _tabChip('pending_cost', '⚠️ Needs Cost ($pendingCount)'),
          ],
        ],
      ),
    );
  }

  Widget _tabChip(String key, String label) {
    final selected = _activeTab == key;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _activeTab = key),
      selectedColor: AppTheme.primary,
      backgroundColor: AppTheme.cardColor(context),
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppTheme.textPrimaryColor(context),
        fontSize: 12,
        fontWeight: FontWeight.w900,
      ),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.borderColor(context)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Widget _buildFinanceRow(FinanceEntry item) {
    final isAdjustment = item.isAdjustment;
    final isReturned = item.orderStatus.toLowerCase().contains('return') ||
        item.orderStatus.toLowerCase().contains('cancel') ||
        item.adjustmentReason.toLowerCase().contains('return');
    final orderNum = item.orderNumber;
    final sku = item.sellerSku;
    final storeName = item.storeName;
    final prodName = item.productName.isNotEmpty ? item.productName : sku;
    final netSettlement = item.netSettlement;
    final netProfit = item.netProfit;
    final isProfitReady = item.isProfitReady;
    final totalCost = item.totalCost;
    final margin = item.profitMargin;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        onTap: () => _openFeeBreakdownModal(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Left Column: Order #, Store Name, and Product/SKU
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(
                            isAdjustment
                                ? (item.adjustmentReason.isNotEmpty ? item.adjustmentReason : 'Financial Adjustment')
                                : 'Order #$orderNum',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              color: AppTheme.textPrimaryColor(context),
                            ),
                          ),
                          if (isReturned) ...<Widget>[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: AppTheme.warningSoft,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
                              ),
                              child: const Text(
                                'RETURNED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  color: AppTheme.warning,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      if (storeName.isNotEmpty) ...<Widget>[
                        Text(
                          '🏬 $storeName',
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                      if (!isAdjustment && prodName.isNotEmpty)
                        Text(
                          prodName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.textMutedColor(context),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (sku.isNotEmpty && sku != prodName)
                        Text(
                          'SKU: $sku',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.textMutedColor(context),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Right Column: Final Received Amount (Green/Red) & Purchasing Price (Red)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    // Final Received Sold Amount
                    Text(
                      '${netSettlement >= 0 ? '' : '-'}PKR ${Formatters.money(netSettlement.abs())}',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: netSettlement >= 0 ? AppTheme.success : AppTheme.danger,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      isReturned
                          ? 'Net Return Settlement'
                          : (isAdjustment ? 'Adjustment Net' : 'Final Received Payout'),
                      style: TextStyle(
                        color: netSettlement >= 0 ? AppTheme.success : AppTheme.danger,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Purchasing Price
                    if (!isAdjustment) ...<Widget>[
                      if (isReturned)
                        const Text(
                          'Stock: PKR 0 (Restocked)',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 10.5,
                            color: AppTheme.info,
                          ),
                        )
                      else if (isProfitReady)
                        Text(
                          'Cost: -PKR ${Formatters.money(totalCost)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 11.5,
                            color: AppTheme.danger,
                          ),
                        )
                      else
                        InkWell(
                          onTap: () => _openSetCostDialog(item),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.dangerSoft,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(Icons.edit_note_rounded, size: 12, color: AppTheme.danger),
                                SizedBox(width: 2),
                                Text(
                                  'Set Cost',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.danger,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ],
            ),
            if (!isAdjustment && isProfitReady && netProfit != null) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: (netProfit >= 0 ? AppTheme.success : AppTheme.danger).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (netProfit >= 0 ? AppTheme.success : AppTheme.danger).withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          isReturned ? 'Net Return Loss: ' : 'Exact True Profit: ',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textMutedColor(context),
                          ),
                        ),
                        Text(
                          '${netProfit >= 0 ? '+' : ''}PKR ${Formatters.money(netProfit)}',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            color: netProfit >= 0 ? AppTheme.success : AppTheme.danger,
                          ),
                        ),
                      ],
                    ),
                    if (!isReturned)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (margin >= 0 ? AppTheme.success : AppTheme.danger).withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${margin >= 0 ? '+' : ''}${margin.toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: margin >= 0 ? AppTheme.success : AppTheme.danger,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class FinanceCsvImportSheet extends StatefulWidget {
  const FinanceCsvImportSheet({super.key, this.stores = const <StoreModel>[]});

  final List<StoreModel> stores;

  @override
  State<FinanceCsvImportSheet> createState() => _FinanceCsvImportSheetState();
}

class _FinanceCsvImportSheetState extends State<FinanceCsvImportSheet> {
  final _csvController = TextEditingController();
  String? _selectedStoreId;
  bool _importing = false;
  int _parsedRowsCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.stores.isNotEmpty) {
      _selectedStoreId = widget.stores.first.id;
    }
  }

  @override
  void dispose() {
    _csvController.dispose();
    super.dispose();
  }

  String _pickedFileName = '';

  void _onTextChange(String val) {
    final rows = _parseCsv(val);
    setState(() => _parsedRowsCount = rows.length);
  }

  Future<void> _pickCsvFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['csv', 'txt'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final path = file.path;
      if (path == null) return;

      final content = await File(path).readAsString();
      _csvController.text = content;
      _onTextChange(content);
      setState(() => _pickedFileName = file.name);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed to read CSV file: $e', error: true);
      }
    }
  }

  List<Map<String, String>> _parseCsv(String text) {
    final lines = text.replaceAll('\r', '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length < 2) return <Map<String, String>>[];

    final delimiter = lines[0].contains(';') ? ';' : ',';
    final headers = _splitLine(lines[0], delimiter);

    final rows = <Map<String, String>>[];
    for (int i = 1; i < lines.length; i++) {
      final values = _splitLine(lines[i], delimiter);
      final row = <String, String>{};
      for (int h = 0; h < headers.length; h++) {
        row[headers[h]] = h < values.length ? values[h] : '';
      }
      rows.add(row);
    }
    return rows;
  }

  List<String> _splitLine(String line, String delimiter) {
    final result = <String>[];
    String current = '';
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == delimiter && !inQuotes) {
        result.add(current.trim());
        current = '';
      } else {
        current += char;
      }
    }
    result.add(current.trim());
    return result;
  }

  Future<void> _submit() async {
    final text = _csvController.text.trim();
    if (text.isEmpty) {
      showAppSnackBar(context, 'Please paste your Daraz weekly finance statement CSV text.', error: true);
      return;
    }

    final rows = _parseCsv(text);
    if (rows.isEmpty) {
      showAppSnackBar(context, 'Could not parse any valid CSV rows. Check CSV headers.', error: true);
      return;
    }

    setState(() => _importing = true);
    try {
      await ApiClient.instance.post(
        '/finance/import-csv',
        body: <String, dynamic>{
          'rows': rows,
          if (_selectedStoreId != null) 'store_id': _selectedStoreId,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Failed to import statement CSV.', error: true);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Import Weekly Statement',
              subtitle: 'Pick a CSV file or paste CSV text from Daraz Seller Center Finance export.',
              action: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ),
            if (widget.stores.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _selectedStoreId,
                decoration: InputDecoration(
                  labelText: 'Assign to Store',
                  filled: true,
                  fillColor: AppTheme.softGreyColor(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppTheme.borderColor(context))),
                ),
                items: widget.stores.map((s) {
                  return DropdownMenuItem<String>(
                    value: s.id,
                    child: Text('🏬 ${s.name} (${s.code})'),
                  );
                }).toList(),
                onChanged: (val) => setState(() => _selectedStoreId = val),
              ),
            ],
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickCsvFile,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  color: _pickedFileName.isNotEmpty
                      ? AppTheme.primary.withValues(alpha: 0.08)
                      : AppTheme.softGreyColor(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _pickedFileName.isNotEmpty ? AppTheme.primary : AppTheme.borderColor(context),
                    width: _pickedFileName.isNotEmpty ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _pickedFileName.isNotEmpty ? AppTheme.primary : AppTheme.softGreyColor(context),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.file_open_rounded,
                        size: 20,
                        color: _pickedFileName.isNotEmpty ? Colors.white : AppTheme.textMutedColor(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _pickedFileName.isNotEmpty ? _pickedFileName : 'Pick CSV File from Device',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: _pickedFileName.isNotEmpty ? AppTheme.primary : AppTheme.textPrimaryColor(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _pickedFileName.isNotEmpty ? 'Tap to change file' : 'Select .csv export from Downloads',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textMutedColor(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _pickedFileName.isNotEmpty ? Icons.check_circle_rounded : Icons.arrow_forward_ios_rounded,
                      size: 18,
                      color: _pickedFileName.isNotEmpty ? AppTheme.success : AppTheme.textMutedColor(context),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(child: Divider(color: AppTheme.borderColor(context))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR paste CSV text', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textMutedColor(context))),
                ),
                Expanded(child: Divider(color: AppTheme.borderColor(context))),
              ],
            ),
            const SizedBox(height: 10),
            AppTextField(
              controller: _csvController,
              labelText: 'Paste Daraz Statement CSV content',
              hintText: 'Statement Period,Statement Number,Order Number,Order Line ID,Seller SKU,Fee Name,Amount(Include Tax)...',
              maxLines: 6,
              onChanged: _onTextChange,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  '💡 Daraz Seller Center ➔ Finance ➔ Export CSV',
                  style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
                ),
                if (_parsedRowsCount > 0)
                  Text(
                    '$_parsedRowsCount rows detected',
                    style: const TextStyle(color: AppTheme.success, fontSize: 11, fontWeight: FontWeight.w900),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Process & Import Statement',
              onPressed: _submit,
              icon: Icons.check_circle_outline,
              expanded: true,
              loading: _importing,
            ),
          ],
        ),
      ),
    );
  }
}
