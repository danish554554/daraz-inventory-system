import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/formatters.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  bool _loading = true;
  bool _importingProducts = false;
  String? _error;
  String _search = '';
  String _filter = 'all';

  List<StoreModel> _stores = <StoreModel>[];
  List<InventoryItem> _inventory = <InventoryItem>[];
  List<RestockEntry> _restocks = <RestockEntry>[];
  List<AdjustmentRequestModel> _adjustments = <AdjustmentRequestModel>[];
  InventorySummary? _summary;

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
      final params = <String, dynamic>{};
      if (_search.trim().isNotEmpty) params['search'] = _search.trim();
      if (_filter == 'low') params['low_stock'] = true;

      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        safe(ApiClient.instance.get('/central-inventory', queryParameters: params)),
        safe(ApiClient.instance.get('/central-inventory/summary', queryParameters: params)),
        safe(ApiClient.instance.get('/central-inventory/restocks', queryParameters: <String, dynamic>{'limit': 20})),
        safe(ApiClient.instance.get('/central-inventory/adjustment-requests', queryParameters: <String, dynamic>{'status': 'pending'})),
        safe(ApiClient.instance.get('/stores')),
      ]);

      final inventoryList = JsonReaders.list(results[0]);
      final summaryMap = JsonReaders.map(results[1]);
      if (inventoryList.isEmpty && summaryMap.isEmpty) {
        throw ApiException(message: 'Could not load inventory. Check the backend URL and session.');
      }

      final storesMap = JsonReaders.map(results[4]);
      setState(() {
        _stores = JsonReaders.list(storesMap['stores']).map((item) => StoreModel.fromJson(JsonReaders.map(item))).toList();
        _inventory = inventoryList.map((item) => InventoryItem.fromJson(JsonReaders.map(item))).toList();
        _summary = summaryMap.isEmpty ? null : InventorySummary.fromJson(summaryMap);
        _restocks = JsonReaders.list(results[2]).map((item) => RestockEntry.fromJson(JsonReaders.map(item))).toList();
        _adjustments = JsonReaders.list(results[3]).map((item) => AdjustmentRequestModel.fromJson(JsonReaders.map(item))).toList();
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Failed to load inventory.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<InventoryItem> get _visibleItems {
    final query = _search.trim().toLowerCase();
    final source = _inventory.where((item) {
      final matchesSearch = query.isEmpty ||
          item.productName.toLowerCase().contains(query) ||
          item.sellerSku.toLowerCase().contains(query) ||
          item.storeCode.toLowerCase().contains(query);
      if (!matchesSearch) return false;
      switch (_filter) {
        case 'critical':
          return item.isCritical;
        case 'instock':
          return item.isInStock;
        case 'low':
          return item.isLowStock;
        case 'out':
          return item.stock <= 0;
        default:
          return true;
      }
    }).toList();
    source.sort((a, b) => a.stock.compareTo(b.stock));
    return source;
  }

  Future<void> _importProducts() async {
    final connectedStores = _stores.where((store) => store.tokenConnected).toList();
    if (connectedStores.isEmpty) {
      showAppSnackBar(context, 'Connect a Daraz store before importing products.', error: true);
      return;
    }

    StoreModel? store;
    if (connectedStores.length == 1) {
      store = connectedStores.first;
    } else {
      store = await showModalBottomSheet<StoreModel>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => ProductImportStoreSheet(stores: connectedStores),
      );
    }

    if (store == null) return;
    setState(() => _importingProducts = true);
    try {
      await ApiClient.instance.post('/daraz-sync/import-products/${store.id}');
      await _load();
      if (mounted) showAppSnackBar(context, 'Active Daraz products imported successfully.');
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Failed to import Daraz products. Please try again.', error: true);
    } finally {
      if (mounted) setState(() => _importingProducts = false);
    }
  }

  Future<void> _openRestockSheet({InventoryItem? item}) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => RestockSheet(inventory: _inventory, selected: item),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Stock added successfully.');
    }
  }

  Future<void> _openQuickAdjustment({InventoryItem? item}) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => QuickAdjustmentSheet(inventory: _inventory, selected: item),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Inventory adjusted successfully.');
    }
  }

  Future<void> _openBulkRestockSheet() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const BulkRestockSheet(),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Bulk restock completed.');
    }
  }

  Future<void> _openAdjustmentQueue() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => AdjustmentQueueSheet(adjustments: _adjustments),
    );
    if (changed == true) await _load();
  }

  Future<void> _openReports() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => InventoryReportsSheet(search: _search.trim()),
    );
  }

  Future<void> _createAdjustmentRequest(InventoryItem item) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => AdjustmentRequestSheet(inventory: item),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Adjustment request created.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const AppLoader(label: 'Loading inventory...')
          : _error != null
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: EmptyState(title: 'Inventory unavailable', message: _error!, icon: Icons.inventory_2_outlined),
                  ),
                )
              : AppShell(
                  onRefresh: _load,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SectionHeader(
                        title: 'Inventory',
                        subtitle: 'Products & stock across stores',
                        action: CircleIconButton(
                          icon: Icons.download_rounded,
                          onPressed: _importingProducts ? null : _importProducts,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              decoration: const InputDecoration(
                                hintText: 'Search SKU or product',
                                prefixIcon: Icon(Icons.search_rounded),
                                isDense: true,
                              ),
                              onChanged: (value) => setState(() => _search = value),
                            ),
                          ),
                          const SizedBox(width: 10),
                          CircleIconButton(
                            icon: Icons.tune_rounded,
                            onPressed: _openReports,
                            background: Colors.white,
                            foreground: AppTheme.textPrimary,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _summaryCards(context),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            _filterChip('all', 'All'),
                            const SizedBox(width: 8),
                            _filterChip('instock', 'In Stock'),
                            const SizedBox(width: 8),
                            _filterChip('low', 'Low'),
                            const SizedBox(width: 8),
                            _filterChip('out', 'Out'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              'Showing ${_visibleItems.length} of ${_inventory.length}',
                              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w800),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _openRestockSheet,
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Restock', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
                          ),
                        ],
                      ),
                      if (_visibleItems.isEmpty)
                        const EmptyState(title: 'No products found', message: 'Import Daraz products or adjust your search filters.', icon: Icons.inventory_2_outlined)
                      else
                        ..._visibleItems.map(_buildInventoryCard),
                      const SizedBox(height: 8),
                      _quickActions(context),
                      const SizedBox(height: 18),
                      _sectionTitle('Recent restocks'),
                      const SizedBox(height: 10),
                      if (_restocks.isEmpty)
                        const EmptyState(title: 'No restocks yet', message: 'Manual purchase receipts will appear here.', icon: Icons.inventory_outlined)
                      else
                        ..._restocks.take(5).map(_buildRestockCard),
                      const SizedBox(height: 18),
                      _sectionTitle('Pending adjustments'),
                      const SizedBox(height: 10),
                      if (_adjustments.isEmpty)
                        const EmptyState(title: 'No pending requests', message: 'Stock adjustment requests need approval before changing stock.', icon: Icons.approval_outlined)
                      else
                        ..._adjustments.take(5).map(_buildAdjustmentCard),
                    ],
                  ),
                ),
    );
  }

  Widget _summaryCards(BuildContext context) {
    final summary = _summary;
    if (summary == null) return const SizedBox.shrink();
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 56) / 3;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        SizedBox(width: itemWidth, child: MetricCard(label: 'Total SKUs', value: '${summary.totalProducts}', icon: Icons.local_fire_department_outlined)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Low stock', value: '${summary.lowStockProducts}', icon: Icons.warning_amber_rounded, tint: AppTheme.warningSoft, iconColor: AppTheme.warning)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Out', value: '${summary.zeroStockProducts}', icon: Icons.dangerous_outlined, tint: AppTheme.dangerSoft, iconColor: AppTheme.danger)),
      ],
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _filter == value;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: AppTheme.primary,
      backgroundColor: Colors.white,
      labelStyle: TextStyle(color: selected ? Colors.white : AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w900),
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Widget _quickActions(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 360 ? width - 32 : (width - 44) / 2;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(width: itemWidth, child: ActionTile(title: 'Import Products', subtitle: 'Refresh active Daraz SKUs', icon: Icons.cloud_download_outlined, onTap: _importProducts, highlight: true, loading: _importingProducts)),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Bulk Restock', subtitle: 'Add new purchase stock', icon: Icons.add_box_outlined, onTap: _openBulkRestockSheet)),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Adjust Stock', subtitle: 'Manual correction', icon: Icons.tune_rounded, onTap: () => _openQuickAdjustment())),
        SizedBox(width: itemWidth, child: ActionTile(title: 'Approvals', subtitle: '${_adjustments.length} pending requests', icon: Icons.fact_check_outlined, onTap: _openAdjustmentQueue)),
      ],
    );
  }

  Widget _buildInventoryCard(InventoryItem item) {
    final statusText = item.isCritical ? 'Out of stock' : item.isLowStock ? 'Low stock' : 'Live stock';
    final color = item.isCritical ? AppTheme.danger : item.isLowStock ? AppTheme.warning : AppTheme.success;
    final softColor = item.isCritical ? AppTheme.dangerSoft : item.isLowStock ? AppTheme.warningSoft : AppTheme.successSoft;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        onTap: () async {
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (context) => InventoryItemActionsSheet(
              item: item,
              onRestock: () => _openRestockSheet(item: item),
              onAdjust: () => _openQuickAdjustment(item: item),
              onRequest: () => _createAdjustmentRequest(item),
            ),
          );
        },
        child: Row(
          children: <Widget>[
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: AppTheme.softGrey,
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(colors: <Color>[AppTheme.softGrey, Colors.grey.shade300]),
              ),
              child: const Icon(Icons.inventory_2_outlined, color: AppTheme.textMuted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(child: Text(item.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13))),
                      const SizedBox(width: 8),
                      Text('${item.stock}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text('${item.sellerSku} · ${item.storeCode}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      StatusChip(label: statusText, color: color, softColor: softColor),
                      const Spacer(),
                      _roundAction(Icons.remove_rounded, () => _openQuickAdjustment(item: item)),
                      const SizedBox(width: 8),
                      Text('${item.stock}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
                      const SizedBox(width: 8),
                      _roundAction(Icons.add_rounded, () => _openRestockSheet(item: item)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundAction(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: Icon(icon, size: 15, color: AppTheme.textPrimary),
      ),
    );
  }

  Widget _buildRestockCard(RestockEntry restock) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            const MiniIcon(icon: Icons.add_box_outlined, color: AppTheme.success, background: AppTheme.successSoft),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(restock.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('${restock.storeCode} · ${restock.sellerSku}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text('Supplier ${restock.supplierName.isEmpty ? '-' : restock.supplierName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text('+${restock.quantity}', style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text(Formatters.dateTime(restock.createdAt), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 10, fontWeight: FontWeight.w700)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdjustmentCard(AdjustmentRequestModel item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        onTap: _openAdjustmentQueue,
        child: Row(
          children: <Widget>[
            const MiniIcon(icon: Icons.approval_outlined, color: AppTheme.warning, background: AppTheme.warningSoft),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('${item.adjustmentType} ${item.quantity} · ${item.reasonCode}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const StatusChip(label: 'Pending', color: AppTheme.warning, softColor: AppTheme.warningSoft),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: -0.2));
  }
}

class ProductImportStoreSheet extends StatelessWidget {
  const ProductImportStoreSheet({super.key, required this.stores});

  final List<StoreModel> stores;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Import Daraz Products',
              subtitle: 'Choose the connected store to import active/live products from.',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const SizedBox(height: 16),
            ...stores.map(
              (store) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AppCard(
                  onTap: () => Navigator.pop(context, store),
                  child: Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.primarySoft,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.storefront_outlined,
                          color: AppTheme.primary,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              store.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${store.code} • ${store.country}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InventoryItemActionsSheet extends StatelessWidget {
  const InventoryItemActionsSheet({
    super.key,
    required this.item,
    required this.onRestock,
    required this.onAdjust,
    required this.onRequest,
  });

  final InventoryItem item;
  final VoidCallback onRestock;
  final VoidCallback onAdjust;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: item.productName,
              subtitle: '${item.sellerSku} • ${item.storeName}',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _metric('Stock', '${item.stock}'),
              _metric('Reserved', '${item.reservedStock}'),
              _metric('Available', '${item.availableStock}'),
              _metric('Low Limit', '${item.lowStockLimit}'),
            ],
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: 'Restock',
            onPressed: onRestock,
            icon: Icons.add_box_outlined,
            expanded: true,
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            label: 'Quick Adjust',
            onPressed: onAdjust,
            icon: Icons.tune_rounded,
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            label: 'Create Adjustment Request',
            onPressed: onRequest,
            icon: Icons.rule_folder_outlined,
          ),
        ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class RestockSheet extends StatefulWidget {
  const RestockSheet({super.key, required this.inventory, this.selected});

  final List<InventoryItem> inventory;
  final InventoryItem? selected;

  @override
  State<RestockSheet> createState() => _RestockSheetState();
}

class _RestockSheetState extends State<RestockSheet> {
  late InventoryItem? _selected;
  final _quantity = TextEditingController(text: '1');
  final _unitCost = TextEditingController(text: '0');
  final _supplier = TextEditingController();
  final _invoice = TextEditingController();
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected =
        widget.selected ??
        (widget.inventory.isNotEmpty ? widget.inventory.first : null);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _unitCost.dispose();
    _supplier.dispose();
    _invoice.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selected == null) {
      showAppSnackBar(context, 'Select an inventory row first.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.instance.post(
        '/central-inventory/restock',
        body: <String, dynamic>{
          'product_id': _selected!.id,
          'quantity': int.tryParse(_quantity.text.trim()) ?? 1,
          'unit_cost': double.tryParse(_unitCost.text.trim()) ?? 0,
          'supplier_name': _supplier.text.trim(),
          'invoice_number': _invoice.text.trim(),
          'note': _note.text.trim(),
          'receipt_type': 'purchase',
          'created_by': 'admin',
        },
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Restock Inventory',
              subtitle:
                  'Add stock back into the internal ledger using the existing restock endpoint.',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _selected?.id,
              decoration: const InputDecoration(labelText: 'Inventory row'),
              items:
                  widget.inventory
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Text(
                            '${item.productName} (${item.storeCode}:${item.sellerSku})',
                          ),
                        ),
                      )
                      .toList(),
              onChanged:
                  (value) => setState(() {
                    _selected = widget.inventory.firstWhere(
                      (item) => item.id == value,
                    );
                  }),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _quantity,
              labelText: 'Quantity',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _unitCost,
              labelText: 'Unit cost',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            const SizedBox(height: 12),
            AppTextField(controller: _supplier, labelText: 'Supplier name'),
            const SizedBox(height: 12),
            AppTextField(controller: _invoice, labelText: 'Invoice number'),
            const SizedBox(height: 12),
            AppTextField(controller: _note, labelText: 'Note', maxLines: 3),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Add Stock',
              onPressed: _submit,
              icon: Icons.check,
              expanded: true,
              loading: _saving,
            ),
          ],
        ),
      ),
    );
  }
}

class QuickAdjustmentSheet extends StatefulWidget {
  const QuickAdjustmentSheet({super.key, required this.inventory, this.selected});

  final List<InventoryItem> inventory;
  final InventoryItem? selected;

  @override
  State<QuickAdjustmentSheet> createState() => _QuickAdjustmentSheetState();
}

class _QuickAdjustmentSheetState extends State<QuickAdjustmentSheet> {
  late InventoryItem? _selected;
  final _quantity = TextEditingController(text: '1');
  final _note = TextEditingController();
  String _type = 'increase';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected =
        widget.selected ??
        (widget.inventory.isNotEmpty ? widget.inventory.first : null);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selected == null) {
      showAppSnackBar(context, 'Select an inventory row first.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.instance.post(
        '/central-inventory/adjust',
        body: <String, dynamic>{
          'inventory_id': _selected!.id,
          'quantity': int.tryParse(_quantity.text.trim()) ?? 1,
          'type': _type,
          'note': _note.text.trim(),
        },
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Quick Adjustment',
              subtitle: 'Immediate stock change using the same manual adjust API.',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _selected?.id,
              decoration: const InputDecoration(labelText: 'Inventory row'),
              items:
                  widget.inventory
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Text(
                            '${item.productName} (${item.storeCode}:${item.sellerSku})',
                          ),
                        ),
                      )
                      .toList(),
              onChanged:
                  (value) => setState(() {
                    _selected = widget.inventory.firstWhere(
                      (item) => item.id == value,
                    );
                  }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Adjustment type'),
              items:
                  const <String>['increase', 'decrease']
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
              onChanged: (value) => setState(() => _type = value ?? 'increase'),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _quantity,
              labelText: 'Quantity',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            AppTextField(controller: _note, labelText: 'Note', maxLines: 3),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Apply Adjustment',
              onPressed: _submit,
              icon: Icons.check,
              expanded: true,
              loading: _saving,
            ),
          ],
        ),
      ),
    );
  }
}

class BulkRestockSheet extends StatefulWidget {
  const BulkRestockSheet({super.key});

  @override
  State<BulkRestockSheet> createState() => _BulkRestockSheetState();
}

class _BulkRestockSheetState extends State<BulkRestockSheet> {
  final TextEditingController _rows = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _rows.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rows.text.trim().isEmpty) {
      showAppSnackBar(context, 'Paste at least one row.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.instance.post(
        '/central-inventory/restock/bulk',
        body: <String, dynamic>{'rows': _rows.text, 'created_by': 'admin'},
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Bulk Restock',
              subtitle:
                  'Format: storeCode,sellerSku,qty,cost,supplier,invoice,note,productName',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _rows,
              labelText: 'Rows',
              maxLines: 10,
              hintText:
                  'DZ-PK-001,SKU-123,10,450,Supplier,INV-1,Opening stock,Product Name',
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Process Bulk Restock',
              onPressed: _submit,
              icon: Icons.upload_file_outlined,
              expanded: true,
              loading: _saving,
            ),
          ],
        ),
      ),
    );
  }
}

class AdjustmentRequestSheet extends StatefulWidget {
  const AdjustmentRequestSheet({super.key, required this.inventory});

  final InventoryItem inventory;

  @override
  State<AdjustmentRequestSheet> createState() => _AdjustmentRequestSheetState();
}

class _AdjustmentRequestSheetState extends State<AdjustmentRequestSheet> {
  final _quantity = TextEditingController(text: '1');
  final _note = TextEditingController();
  String _type = 'decrease';
  String _reason = 'count_adjustment';
  bool _saving = false;

  @override
  void dispose() {
    _quantity.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    try {
      await ApiClient.instance.post(
        '/central-inventory/adjustment-requests',
        body: <String, dynamic>{
          'product_id': widget.inventory.id,
          'adjustment_type': _type,
          'quantity': int.tryParse(_quantity.text.trim()) ?? 1,
          'reason_code': _reason,
          'note': _note.text.trim(),
          'requested_by': 'admin',
        },
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Adjustment Request',
              subtitle: '${widget.inventory.productName} • ${widget.inventory.storeCode}',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Adjustment type'),
              items:
                  const <String>['increase', 'decrease']
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
              onChanged: (value) => setState(() => _type = value ?? 'decrease'),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _quantity,
              labelText: 'Quantity',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _reason,
              decoration: const InputDecoration(labelText: 'Reason'),
              items:
                  const <String>[
                    'purchase_correction',
                    'damaged_stock',
                    'missing_stock',
                    'count_adjustment',
                    'return_out',
                    'other',
                  ]
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value.replaceAll('_', ' ')),
                        ),
                      )
                      .toList(),
              onChanged:
                  (value) => setState(() => _reason = value ?? 'count_adjustment'),
            ),
            const SizedBox(height: 12),
            AppTextField(controller: _note, labelText: 'Note', maxLines: 3),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Create Request',
              onPressed: _submit,
              icon: Icons.rule_folder_outlined,
              expanded: true,
              loading: _saving,
            ),
          ],
        ),
      ),
    );
  }
}

class AdjustmentQueueSheet extends StatefulWidget {
  const AdjustmentQueueSheet({super.key, required this.adjustments});

  final List<AdjustmentRequestModel> adjustments;

  @override
  State<AdjustmentQueueSheet> createState() => _AdjustmentQueueSheetState();
}

class _AdjustmentQueueSheetState extends State<AdjustmentQueueSheet> {
  bool _working = false;

  Future<void> _action(AdjustmentRequestModel item, String action) async {
    setState(() => _working = true);
    try {
      await ApiClient.instance.post(
        '/central-inventory/adjustment-requests/${item.id}/$action',
        body: <String, dynamic>{'approved_by': 'admin'},
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        children: <Widget>[
          SectionHeader(
            title: 'Adjustment Queue',
            subtitle: 'Approve or reject pending stock changes.',
            action: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child:
                widget.adjustments.isEmpty
                    ? const EmptyState(
                      title: 'Queue is empty',
                      message: 'Pending requests will appear here.',
                      icon: Icons.approval_outlined,
                    )
                    : ListView.builder(
                      itemCount: widget.adjustments.length,
                      itemBuilder: (context, index) {
                        final item = widget.adjustments[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  item.productName,
                                  style: const TextStyle(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${item.adjustmentType} ${item.quantity} • ${item.reasonCode}',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${item.storeName} • current stock ${item.currentStock}',
                                  style: const TextStyle(color: AppTheme.textMuted),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: PrimaryButton(
                                        label: 'Approve',
                                        onPressed:
                                            _working
                                                ? null
                                                : () => _action(item, 'approve'),
                                        icon: Icons.check,
                                        expanded: true,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: SecondaryButton(
                                        label: 'Reject',
                                        onPressed:
                                            _working
                                                ? null
                                                : () => _action(item, 'reject'),
                                        icon: Icons.close,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

class InventoryReportsSheet extends StatefulWidget {
  const InventoryReportsSheet({super.key, required this.search});

  final String search;

  @override
  State<InventoryReportsSheet> createState() => _InventoryReportsSheetState();
}

class _InventoryReportsSheetState extends State<InventoryReportsSheet> {
  bool _loading = true;
  String _date = DateTime.now().toIso8601String().slice(0, 10);
  String _analyticsStart = DateTime.now()
      .subtract(const Duration(days: 29))
      .toIso8601String()
      .slice(0, 10);
  String _analyticsEnd = DateTime.now().toIso8601String().slice(0, 10);
  String _supplier = '';

  DailyReport? _dailyReport;
  PurchaseAnalytics? _analytics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        ApiClient.instance.get(
          '/central-inventory/daily-report',
          queryParameters: <String, dynamic>{
            'date': _date,
            if (widget.search.isNotEmpty) 'search': widget.search,
          },
        ),
        ApiClient.instance.get(
          '/central-inventory/analytics/purchases',
          queryParameters: <String, dynamic>{
            'start': _analyticsStart,
            'end': _analyticsEnd,
            if (_supplier.trim().isNotEmpty) 'supplier': _supplier.trim(),
          },
        ),
      ]);
      setState(() {
        _dailyReport = DailyReport.fromJson(JsonReaders.map(results[0]));
        _analytics = PurchaseAnalytics.fromJson(JsonReaders.map(results[1]));
      });
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _shareCsv(String endpoint, String filename) async {
    try {
      final csv = await ApiClient.instance.getText(endpoint);
      await Share.share(
        csv,
        subject: filename,
      );
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        children: <Widget>[
          SectionHeader(
            title: 'Reports & Exports',
            subtitle: 'Daily movement, supplier purchases, and CSV export actions.',
            action: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child:
                _loading
                    ? const AppLoader(label: 'Loading reports...')
                    : ListView(
                      children: <Widget>[
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Daily Report',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 12),
                              AppTextField(
                                labelText: 'Date (YYYY-MM-DD)',
                                hintText: _date,
                                onChanged:
                                    (value) =>
                                        _date = value.trim().isEmpty
                                            ? _date
                                            : value.trim(),
                              ),
                              const SizedBox(height: 12),
                              SecondaryButton(
                                label: 'Reload Daily Report',
                                onPressed: _load,
                                icon: Icons.refresh,
                              ),
                              const SizedBox(height: 12),
                              if (_dailyReport != null) ...<Widget>[
                                Text(
                                  'Products: ${_dailyReport!.totals.products}',
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Opening ${_dailyReport!.totals.openingStock} • Sold ${_dailyReport!.totals.soldQty} • Closing ${_dailyReport!.totals.closingStock}',
                                  style: const TextStyle(color: AppTheme.textMuted),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Supplier Analytics',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 12),
                              AppTextField(
                                labelText: 'Start date',
                                hintText: _analyticsStart,
                                onChanged:
                                    (value) =>
                                        _analyticsStart = value.trim().isEmpty
                                            ? _analyticsStart
                                            : value.trim(),
                              ),
                              const SizedBox(height: 12),
                              AppTextField(
                                labelText: 'End date',
                                hintText: _analyticsEnd,
                                onChanged:
                                    (value) =>
                                        _analyticsEnd = value.trim().isEmpty
                                            ? _analyticsEnd
                                            : value.trim(),
                              ),
                              const SizedBox(height: 12),
                              AppTextField(
                                labelText: 'Supplier filter',
                                hintText: 'Optional supplier name',
                                onChanged: (value) => _supplier = value,
                              ),
                              const SizedBox(height: 12),
                              SecondaryButton(
                                label: 'Reload Analytics',
                                onPressed: _load,
                                icon: Icons.refresh,
                              ),
                              const SizedBox(height: 12),
                              if (_analytics != null) ...<Widget>[
                                Text(
                                  'Suppliers: ${_analytics!.totals.suppliers}',
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Qty ${_analytics!.totals.totalQuantity} • Cost ${Formatters.money(_analytics!.totals.totalCost)}',
                                  style: const TextStyle(color: AppTheme.textMuted),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Exports',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 12),
                              PrimaryButton(
                                label: 'Share Inventory CSV',
                                onPressed:
                                    () => _shareCsv(
                                      '/central-inventory/export/inventory.csv',
                                      'inventory-report.csv',
                                    ),
                                icon: Icons.ios_share,
                                expanded: true,
                              ),
                              const SizedBox(height: 12),
                              SecondaryButton(
                                label: 'Share Restocks CSV',
                                onPressed:
                                    () => _shareCsv(
                                      '/central-inventory/export/restocks.csv',
                                      'restock-report.csv',
                                    ),
                                icon: Icons.ios_share,
                              ),
                              const SizedBox(height: 12),
                              SecondaryButton(
                                label: 'Share Purchase Analytics CSV',
                                onPressed:
                                    () => _shareCsv(
                                      '/central-inventory/export/purchase-analytics.csv?start=$_analyticsStart&end=$_analyticsEnd&supplier=$_supplier',
                                      'purchase-analytics.csv',
                                    ),
                                icon: Icons.ios_share,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String slice(int start, int end) {
    if (start >= length) return '';
    if (end > length) return substring(start);
    return substring(start, end);
  }
}
