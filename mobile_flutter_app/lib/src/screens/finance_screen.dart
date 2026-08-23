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

class _FinanceScreenState extends State<FinanceScreen> with SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _error;
  String _search = '';
  String _activeTab = 'all'; // all, orders, adjustments, pending_cost

  Map<String, dynamic> _summary = <String, dynamic>{};
  List<Map<String, dynamic>> _entries = <Map<String, dynamic>>[];
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
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        ApiClient.instance.get('/finance/summary', bypassCache: true),
        ApiClient.instance.get('/finance', bypassCache: true),
        ApiClient.instance.get('/central-inventory', bypassCache: true),
      ]);

      final summaryMap = JsonReaders.map(results[0]);
      final entriesList = JsonReaders.list(results[1]).map((e) => JsonReaders.map(e)).toList();
      final invList = JsonReaders.list(results[2]).map((e) => InventoryItem.fromJson(JsonReaders.map(e))).toList();

      if (mounted) {
        setState(() {
          _summary = summaryMap;
          _entries = entriesList;
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

  List<Map<String, dynamic>> get _filteredEntries {
    final query = _search.trim().toLowerCase();
    return _entries.where((item) {
      final type = (item['entry_type'] ?? 'order').toString();
      final orderNum = (item['order_number'] ?? '').toString().toLowerCase();
      final sku = (item['seller_sku'] ?? '').toString().toLowerCase();
      final prodName = (item['product_name'] ?? '').toString().toLowerCase();
      final reason = (item['adjustment_reason'] ?? '').toString().toLowerCase();
      final isProfitReady = item['profit_ready'] == true;
      final price = (double.tryParse((item['product_price'] ?? 0).toString()) ?? 0);

      // Filter by tab
      if (_activeTab == 'orders' && type != 'order') return false;
      if (_activeTab == 'adjustments' && type != 'adjustment') return false;
      if (_activeTab == 'pending_cost') {
        if (type != 'order' || isProfitReady || price == 0) return false;
      }

      // Filter by search
      if (query.isNotEmpty) {
        final matches = orderNum.contains(query) ||
            sku.contains(query) ||
            prodName.contains(query) ||
            reason.contains(query);
        if (!matches) return false;
      }

      return true;
    }).toList();
  }

  Future<void> _openImportSheet() async {
    final imported = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.cardColor(context),
      builder: (context) => const FinanceCsvImportSheet(),
    );
    if (imported == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Finance statement imported successfully.');
    }
  }

  Future<void> _openSetCostDialog(Map<String, dynamic> entry) async {
    final sku = (entry['seller_sku'] ?? '').toString();
    final name = (entry['product_name'] ?? sku).toString();
    final costController = TextEditingController();

    // Look for matching inventory item
    final matched = _inventory.where((i) => i.sellerSku.toLowerCase() == sku.toLowerCase()).firstOrNull;
    if (matched != null && (matched.costPrice > 0 || matched.purchasePrice > 0)) {
      final c = matched.costPrice > 0 ? matched.costPrice : matched.purchasePrice;
      costController.text = c.toStringAsFixed(c.truncateToDouble() == c ? 0 : 2);
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.cardColor(context),
        title: Text(
          'Set Purchase Cost Price',
          style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900),
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
              labelText: 'Purchase Price per piece (PKR)',
              hintText: 'e.g. 350',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 6),
            Text(
              'This will instantly recalculate profit across all orders for this product.',
              style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save & Calculate Profit'),
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
        if (matched != null) {
          final id = matched.inventoryId.isNotEmpty ? matched.inventoryId : matched.id;
          await ApiClient.instance.put(
            '/central-inventory/$id/prices',
            body: <String, dynamic>{'purchase_price': cost, 'cost_price': cost},
          );
        }
        await _load(silent: true);
        if (mounted) showAppSnackBar(context, 'Cost price saved and profits recalculated.');
      } catch (e) {
        if (mounted) showAppSnackBar(context, 'Error updating cost: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading financial statements...')
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
                        title: 'Finance',
                        subtitle: 'Daraz fee deductions, settlement payouts & profit records',
                        action: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            CircleIconButton(
                              icon: Icons.upload_file_rounded,
                              onPressed: _openImportSheet,
                              background: AppTheme.primary,
                              foreground: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            CircleIconButton(
                              icon: Icons.share_rounded,
                              onPressed: () {
                                ReportGeneratorService.shareDailySummary(
                                  historySummary: _summary,
                                  orders: const <CentralOrder>[],
                                  lowStockItems: const <InventoryItem>[],
                                  period: 'statement',
                                  connectedStoresCount: 1,
                                  totalStoresCount: 1,
                                );
                              },
                              background: AppTheme.success,
                              foreground: Colors.white,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _heroFinanceCard(),
                      const SizedBox(height: 14),
                      _feeBreakdownGrid(context),
                      const SizedBox(height: 16),
                      _filterTabs(),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search order #, SKU, or item',
                          prefixIcon: Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _search = val),
                      ),
                      const SizedBox(height: 14),
                      if (_filteredEntries.isEmpty)
                        EmptyState(
                          title: _entries.isEmpty ? 'No finance statements yet' : 'No matching entries',
                          message: _entries.isEmpty
                              ? 'Import your weekly Daraz payment statement CSV or sync orders to see detailed fee breakdowns and true profit.'
                              : 'Try changing your search keywords or filter tab.',
                          icon: Icons.receipt_long_outlined,
                        )
                      else
                        ..._filteredEntries.map(_buildFinanceRow),
                    ],
                  ),
                ),
    );
  }

  Widget _heroFinanceCard() {
    final netSettlement = JsonReaders.number(_summary, 'net_settlement');
    final netProfit = JsonReaders.number(_summary, 'net_profit');
    final finalProfit = JsonReaders.number(_summary, 'final_profit_after_adjustments', netProfit);
    final grossAmount = JsonReaders.number(_summary, 'gross_amount');
    final totalDeductions = JsonReaders.number(_summary, 'total_deductions');
    final totalOrders = JsonReaders.integer(_summary, 'total_orders');
    final pendingCost = JsonReaders.integer(_summary, 'pending_cost_orders');

    final profitMargin = grossAmount > 0 ? ((finalProfit / grossAmount) * 100) : 0.0;

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
                  profitMargin > 0 ? '+${profitMargin.toStringAsFixed(1)}% Margin' : 'Margin --',
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
    final totalFees = JsonReaders.number(_summary, 'total_fees');
    final totalTaxes = JsonReaders.number(_summary, 'total_taxes');
    final adjImpact = JsonReaders.number(_summary, 'adjustment_impact');
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 44) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Daraz Fees',
            value: 'PKR ${Formatters.money(totalFees)}',
            icon: Icons.receipt_outlined,
            tint: AppTheme.dangerSoft,
            iconColor: AppTheme.danger,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Taxes (WHT / VAT)',
            value: 'PKR ${Formatters.money(totalTaxes)}',
            icon: Icons.account_balance_outlined,
            tint: AppTheme.warningSoft,
            iconColor: AppTheme.warning,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Adjustments / Claims',
            value: 'PKR ${Formatters.money(adjImpact)}',
            icon: Icons.sync_alt_rounded,
            tint: AppTheme.infoSoft,
            iconColor: AppTheme.info,
          ),
        ),
        SizedBox(
          width: itemWidth,
          child: MetricCard(
            label: 'Net Profit Realized',
            value: 'PKR ${Formatters.money(JsonReaders.number(_summary, 'net_profit'))}',
            icon: Icons.trending_up_rounded,
            tint: AppTheme.successSoft,
            iconColor: AppTheme.success,
          ),
        ),
      ],
    );
  }

  Widget _filterTabs() {
    final pendingCount = JsonReaders.integer(_summary, 'pending_cost_orders');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _tabChip('all', 'All Entries (${_entries.length})'),
          const SizedBox(width: 8),
          _tabChip('orders', 'Orders'),
          const SizedBox(width: 8),
          _tabChip('adjustments', 'Adjustments & Penalties'),
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

  Widget _buildFinanceRow(Map<String, dynamic> item) {
    final isAdjustment = (item['entry_type'] ?? '') == 'adjustment';
    final orderNum = (item['order_number'] ?? '').toString();
    final sku = (item['seller_sku'] ?? '').toString();
    final prodName = (item['product_name'] ?? sku).toString();
    final netSettlement = JsonReaders.number(item, 'net_settlement');
    final netProfit = item['net_profit'];
    final isProfitReady = item['profit_ready'] == true;
    final deductions = JsonReaders.number(item, 'total_deductions');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(13),
        onTap: () {
          if (!isProfitReady && !isAdjustment) {
            _openSetCostDialog(item);
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isAdjustment
                        ? AppTheme.warningSoft
                        : isProfitReady
                            ? AppTheme.successSoft
                            : AppTheme.primarySoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isAdjustment
                        ? Icons.sync_alt_rounded
                        : isProfitReady
                            ? Icons.verified_rounded
                            : Icons.help_outline_rounded,
                    size: 16,
                    color: isAdjustment
                        ? AppTheme.warning
                        : isProfitReady
                            ? AppTheme.success
                            : AppTheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        isAdjustment
                            ? (item['adjustment_reason'] ?? 'Financial Adjustment')
                            : (prodName.isNotEmpty ? prodName : 'Order #$orderNum'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: AppTheme.textPrimaryColor(context)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isAdjustment
                            ? 'Statement ${item['statement_number'] ?? '-'}'
                            : 'Order #$orderNum · SKU: $sku',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      'PKR ${Formatters.money(netSettlement)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        color: netSettlement >= 0 ? AppTheme.primary : AppTheme.danger,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Payout',
                      style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: AppTheme.softGreyColor(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    'Fees & Tax: -PKR ${Formatters.money(deductions)}',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMutedColor(context), fontWeight: FontWeight.w700),
                  ),
                  if (isAdjustment)
                    const StatusChip(label: 'Adjustment', color: AppTheme.warning, softColor: AppTheme.warningSoft)
                  else if (isProfitReady && netProfit != null)
                    Text(
                      'Profit: PKR ${Formatters.money(double.tryParse(netProfit.toString()) ?? 0)}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w900),
                    )
                  else
                    InkWell(
                      onTap: () => _openSetCostDialog(item),
                      child: const Row(
                        children: <Widget>[
                          Icon(Icons.edit_note_rounded, size: 14, color: AppTheme.warning),
                          SizedBox(width: 3),
                          Text(
                            'Set Unit Cost',
                            style: TextStyle(fontSize: 11, color: AppTheme.warning, fontWeight: FontWeight.w900),
                          ),
                        ],
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

class FinanceCsvImportSheet extends StatefulWidget {
  const FinanceCsvImportSheet({super.key});

  @override
  State<FinanceCsvImportSheet> createState() => _FinanceCsvImportSheetState();
}

class _FinanceCsvImportSheetState extends State<FinanceCsvImportSheet> {
  final _csvController = TextEditingController();
  bool _importing = false;

  @override
  void dispose() {
    _csvController.dispose();
    super.dispose();
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
        body: <String, dynamic>{'rows': rows},
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Failed to import CSV.', error: true);
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
              subtitle: 'Paste your Daraz Seller Center Finance CSV export to calculate true profit.',
              action: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _csvController,
              labelText: 'Paste Daraz Finance Statement CSV content',
              hintText: 'Order Number,Order Line ID,Seller SKU,Fee Name,Amount(Include Tax)...',
              maxLines: 8,
            ),
            const SizedBox(height: 8),
            Text(
              '💡 In Daraz Seller Center ➔ Finance ➔ Account Statements ➔ Export CSV. Paste the full CSV rows here.',
              style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w700),
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
