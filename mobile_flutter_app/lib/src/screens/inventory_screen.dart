import 'package:flutter/material.dart';

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
  String? _error;
  String _search = '';
  String _filter = 'all';
  final Set<String> _selected = <String>{};
  List<ProductItemModel> _products = <ProductItemModel>[];
  List<StoreModel> _stores = <StoreModel>[];

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

    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        ApiClient.instance.get('/products', queryParameters: <String, dynamic>{
          if (_search.trim().isNotEmpty) 'search': _search.trim(),
          'filter': _filter,
        }),
        ApiClient.instance.get('/stores'),
      ]);

      setState(() {
        _products = JsonReaders.list(results[0])
            .map((item) => ProductItemModel.fromJson(JsonReaders.map(item)))
            .toList();
        _stores = JsonReaders.list(JsonReaders.map(results[1])['stores'])
            .map((item) => StoreModel.fromJson(JsonReaders.map(item)))
            .toList();
        _selected.removeWhere((id) => !_products.any((item) => item.id == id));
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = 'Failed to load products.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalStock => _products.fold(0, (sum, item) => sum + item.stock);
  int get _lowCount => _products.where((item) => item.isLowStock).length;
  int get _outCount => _products.where((item) => item.isOutOfStock).length;
  int get _buyAgainCount => _products.where((item) => item.buyAgainQty > 0).length;

  Future<void> _openProductForm({ProductItemModel? product}) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ProductFormSheet(product: product, stores: _stores),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, product == null ? 'Product added.' : 'Product updated.');
    }
  }

  Future<void> _openImportSheet() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ImportProductsSheet(stores: _stores),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Products imported.');
    }
  }

  Future<void> _openStockSheet(ProductItemModel product) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StockUpdateSheet(product: product),
    );
    if (done == true) {
      await _load();
      if (mounted) showAppSnackBar(context, 'Stock updated.');
    }
  }

  Future<void> _mergeSelected() async {
    if (_selected.length < 2) {
      showAppSnackBar(context, 'Select at least two products to merge.');
      return;
    }

    final selectedProducts = _products.where((item) => _selected.contains(item.id)).toList();
    final master = await showModalBottomSheet<ProductItemModel>(
      context: context,
      useSafeArea: true,
      builder: (context) => MasterProductPicker(products: selectedProducts),
    );
    if (master == null) return;

    try {
      await ApiClient.instance.post('/products/merge', body: <String, dynamic>{
        'product_ids': _selected.toList(),
        'master_product_id': master.id,
      });
      _selected.clear();
      await _load();
      if (mounted) showAppSnackBar(context, 'SKUs merged into ${master.name}.');
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  Future<void> _deleteProduct(ProductItemModel product) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete product?'),
        content: Text('This will remove ${product.name} and all linked store SKUs.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await ApiClient.instance.delete('/products/${product.id}');
      await _load();
      if (mounted) showAppSnackBar(context, 'Product deleted.');
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Products & Stock'),
        actions: <Widget>[
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openProductForm(),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Product'),
      ),
      body: SafeArea(
        child: _loading
            ? const AppLoader(label: 'Loading products...')
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: EmptyState(title: 'Products unavailable', message: _error!, icon: Icons.inventory_2_outlined),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 110),
                      children: <Widget>[
                        _buildActions(),
                        const SizedBox(height: 16),
                        _buildMetrics(),
                        const SizedBox(height: 16),
                        _buildSearchAndFilters(),
                        const SizedBox(height: 16),
                        ..._products.map(_buildProductCard),
                        if (_products.isEmpty)
                          const EmptyState(title: 'No products yet', message: 'Add products manually or import active listings from a store.', icon: Icons.add_box_outlined),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _buildActions() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader(title: 'Inventory Products', subtitle: 'One master product can hold SKUs from all connected stores.'),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton.icon(onPressed: () => _openProductForm(), icon: const Icon(Icons.add_rounded), label: const Text('Add Product')),
              OutlinedButton.icon(onPressed: _openImportSheet, icon: const Icon(Icons.download_rounded), label: const Text('Import Products')),
              OutlinedButton.icon(onPressed: _selected.length >= 2 ? _mergeSelected : null, icon: const Icon(Icons.merge_type_rounded), label: Text('Merge SKUs (${_selected.length})')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetrics() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.35,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      children: <Widget>[
        MetricCard(label: 'Products', value: '${_products.length}', icon: Icons.category_outlined),
        MetricCard(label: 'Total Stock', value: '$_totalStock', icon: Icons.inventory_2_outlined),
        MetricCard(label: 'Buy Again', value: '$_buyAgainCount', icon: Icons.shopping_cart_checkout_rounded, tint: AppTheme.warningSoft, iconColor: AppTheme.warning),
        MetricCard(label: 'Out of Stock', value: '$_outCount', icon: Icons.error_outline_rounded, tint: AppTheme.dangerSoft, iconColor: AppTheme.danger),
      ],
    );
  }

  Widget _buildSearchAndFilters() {
    return Column(
      children: <Widget>[
        TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search product, master SKU, or store SKU'),
          onSubmitted: (value) {
            _search = value;
            _load();
          },
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              _filterChip('all', 'All'),
              _filterChip('low', 'Low Stock'),
              _filterChip('out', 'Out of Stock'),
              _filterChip('instock', 'In Stock'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String value, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: _filter == value,
        label: Text(label),
        onSelected: (_) {
          setState(() => _filter = value);
          _load();
        },
      ),
    );
  }

  Widget _buildProductCard(ProductItemModel product) {
    final selected = _selected.contains(product.id);
    final status = product.isOutOfStock
        ? StatusChip(label: 'Out', color: AppTheme.danger, softColor: AppTheme.dangerSoft)
        : product.isLowStock
            ? StatusChip(label: 'Low', color: AppTheme.warning, softColor: AppTheme.warningSoft)
            : const StatusChip(label: 'OK', color: AppTheme.success, softColor: AppTheme.successSoft);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        borderColor: selected ? AppTheme.primary : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Checkbox(value: selected, onChanged: (_) => setState(() => selected ? _selected.remove(product.id) : _selected.add(product.id))),
                ProductThumb(url: product.imageUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text('Master SKU: ${product.masterSku}', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    ],
                  ),
                ),
                status,
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                InfoPill(label: 'Stock', value: '${product.stock}'),
                InfoPill(label: 'Available', value: '${product.availableStock}'),
                InfoPill(label: 'Low Limit', value: '${product.lowStockLimit}'),
                InfoPill(label: 'Buy Again', value: '${product.buyAgainQty}'),
                InfoPill(label: 'Cost', value: Formatters.money(product.purchasePrice)),
                InfoPill(label: 'Stores', value: '${product.linkedSkus.length} SKUs'),
              ],
            ),
            if (product.linkedSkus.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: product.linkedSkus.take(6).map((map) => Chip(label: Text('${map.storeName.isEmpty ? 'Store' : map.storeName}: ${map.sku}'))).toList(),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(child: OutlinedButton.icon(onPressed: () => _openStockSheet(product), icon: const Icon(Icons.add_chart_rounded), label: const Text('Update Stock'))),
                const SizedBox(width: 8),
                IconButton(onPressed: () => _openProductForm(product: product), icon: const Icon(Icons.edit_outlined)),
                IconButton(onPressed: () => _deleteProduct(product), icon: const Icon(Icons.delete_outline_rounded), color: AppTheme.danger),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ProductThumb extends StatelessWidget {
  const ProductThumb({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(16)),
      child: const Icon(Icons.inventory_2_outlined, color: AppTheme.primary),
    );
    if (url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.network(url, width: 58, height: 58, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder),
    );
  }
}

class InfoPill extends StatelessWidget {
  const InfoPill({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: RichText(text: TextSpan(style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12), children: <TextSpan>[
        TextSpan(text: '$label: ', style: const TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w600)),
        TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ])),
    );
  }
}

class ProductFormSheet extends StatefulWidget {
  const ProductFormSheet({super.key, this.product, required this.stores});
  final ProductItemModel? product;
  final List<StoreModel> stores;

  @override
  State<ProductFormSheet> createState() => _ProductFormSheetState();
}

class _ProductFormSheetState extends State<ProductFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _stock;
  late final TextEditingController _price;
  late final TextEditingController _lowLimit;
  late final TextEditingController _image;
  final List<_SkuInput> _skuInputs = <_SkuInput>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _name = TextEditingController(text: p?.name ?? '');
    _sku = TextEditingController(text: p?.masterSku ?? '');
    _stock = TextEditingController(text: p == null ? '0' : '${p.stock}');
    _price = TextEditingController(text: p == null ? '0' : '${p.purchasePrice}');
    _lowLimit = TextEditingController(text: p == null ? '5' : '${p.lowStockLimit}');
    _image = TextEditingController(text: p?.imageUrl ?? '');
    if (p != null) {
      for (final map in p.linkedSkus) {
        _skuInputs.add(_SkuInput.fromMap(map));
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _stock.dispose();
    _price.dispose();
    _lowLimit.dispose();
    _image.dispose();
    for (final input in _skuInputs) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'master_sku': _sku.text.trim(),
      'stock': int.tryParse(_stock.text.trim()) ?? 0,
      'purchase_price': double.tryParse(_price.text.trim()) ?? 0,
      'low_stock_limit': int.tryParse(_lowLimit.text.trim()) ?? 5,
      'image_url': _image.text.trim(),
      'linked_skus': _skuInputs.where((item) => item.sku.text.trim().isNotEmpty).map((item) => item.toJson()).toList(),
    };

    try {
      if (widget.product == null) {
        await ApiClient.instance.post('/products/add-product', body: body);
      } else {
        await ApiClient.instance.put('/products/${widget.product!.id}', body: body);
      }
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
      padding: EdgeInsets.only(left: 18, right: 18, top: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            SectionHeader(title: widget.product == null ? 'Add Product' : 'Edit Product', subtitle: 'Keep one master product for all store SKUs.'),
            const SizedBox(height: 16),
            TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Product name'), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 10),
            TextFormField(controller: _sku, decoration: const InputDecoration(labelText: 'Master SKU'), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 10),
            Row(children: <Widget>[
              Expanded(child: TextFormField(controller: _stock, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Physical stock'))),
              const SizedBox(width: 10),
              Expanded(child: TextFormField(controller: _lowLimit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Low stock limit'))),
            ]),
            const SizedBox(height: 10),
            TextFormField(controller: _price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Purchase price')),
            const SizedBox(height: 10),
            TextFormField(controller: _image, decoration: const InputDecoration(labelText: 'Image URL')),
            const SizedBox(height: 16),
            Row(children: <Widget>[
              const Expanded(child: Text('Linked store SKUs', style: TextStyle(fontWeight: FontWeight.w800))),
              TextButton.icon(onPressed: () => setState(() => _skuInputs.add(_SkuInput())), icon: const Icon(Icons.add_rounded), label: const Text('Add SKU')),
            ]),
            ..._skuInputs.asMap().entries.map((entry) => _LinkedSkuInputRow(input: entry.value, stores: widget.stores, onRemove: () => setState(() { entry.value.dispose(); _skuInputs.removeAt(entry.key); }))),
            const SizedBox(height: 18),
            PrimaryButton(label: 'Save Product', onPressed: _save, loading: _saving, expanded: true),
          ],
        ),
      ),
    );
  }
}

class _SkuInput {
  _SkuInput();
  _SkuInput.fromMap(LinkedSkuModel map) {
    sku.text = map.sku;
    storeName.text = map.storeName;
    storeId = map.storeId;
  }
  final TextEditingController sku = TextEditingController();
  final TextEditingController storeName = TextEditingController();
  String storeId = '';
  void dispose() { sku.dispose(); storeName.dispose(); }
  Map<String, dynamic> toJson() => <String, dynamic>{'sku': sku.text.trim(), 'store_id': storeId.isEmpty ? null : storeId, 'store_name': storeName.text.trim()};
}

class _LinkedSkuInputRow extends StatelessWidget {
  const _LinkedSkuInputRow({required this.input, required this.stores, required this.onRemove});
  final _SkuInput input;
  final List<StoreModel> stores;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: <Widget>[
        Expanded(child: TextField(controller: input.sku, decoration: const InputDecoration(labelText: 'Store SKU'))),
        const SizedBox(width: 8),
        Expanded(child: DropdownButtonFormField<String>(
          value: input.storeId.isEmpty ? null : input.storeId,
          decoration: const InputDecoration(labelText: 'Store'),
          items: stores.map((store) => DropdownMenuItem(value: store.id, child: Text(store.name))).toList(),
          onChanged: (value) {
            input.storeId = value ?? '';
            final matches = stores.where((item) => item.id == value).toList();
            input.storeName.text = matches.isEmpty ? '' : matches.first.name;
          },
        )),
        IconButton(onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
      ]),
    );
  }
}

class StockUpdateSheet extends StatefulWidget {
  const StockUpdateSheet({super.key, required this.product});
  final ProductItemModel product;

  @override
  State<StockUpdateSheet> createState() => _StockUpdateSheetState();
}

class _StockUpdateSheetState extends State<StockUpdateSheet> {
  final _qty = TextEditingController(text: '1');
  final _price = TextEditingController();
  String _type = 'add';
  bool _saving = false;

  @override
  void dispose() { _qty.dispose(); _price.dispose(); super.dispose(); }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ApiClient.instance.post('/products/${widget.product.id}/stock', body: <String, dynamic>{
        'type': _type,
        'quantity': int.tryParse(_qty.text.trim()) ?? 1,
        if (_price.text.trim().isNotEmpty) 'purchase_price': double.tryParse(_price.text.trim()) ?? widget.product.purchasePrice,
      });
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
      padding: EdgeInsets.only(left: 18, right: 18, top: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        SectionHeader(title: 'Update Stock', subtitle: widget.product.name),
        const SizedBox(height: 16),
        SegmentedButton<String>(segments: const <ButtonSegment<String>>[
          ButtonSegment(value: 'add', label: Text('Add Stock'), icon: Icon(Icons.add_rounded)),
          ButtonSegment(value: 'deduct', label: Text('Deduct'), icon: Icon(Icons.remove_rounded)),
        ], selected: <String>{_type}, onSelectionChanged: (set) => setState(() => _type = set.first)),
        const SizedBox(height: 12),
        TextField(controller: _qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity')),
        const SizedBox(height: 10),
        TextField(controller: _price, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Purchase price', hintText: '${widget.product.purchasePrice}')),
        const SizedBox(height: 18),
        PrimaryButton(label: 'Update Stock', onPressed: _save, loading: _saving, expanded: true),
      ]),
    );
  }
}

class ImportProductsSheet extends StatefulWidget {
  const ImportProductsSheet({super.key, required this.stores});
  final List<StoreModel> stores;

  @override
  State<ImportProductsSheet> createState() => _ImportProductsSheetState();
}

class _ImportProductsSheetState extends State<ImportProductsSheet> {
  StoreModel? _store;
  bool _loading = false;
  bool _saving = false;
  List<ImportProductPreviewModel> _items = <ImportProductPreviewModel>[];
  final Set<String> _selected = <String>{};

  Future<void> _fetch() async {
    if (_store == null) return;
    setState(() { _loading = true; _items = []; _selected.clear(); });
    try {
      final result = await ApiClient.instance.get('/products/import-preview', queryParameters: <String, dynamic>{'store_id': _store!.id});
      final items = JsonReaders.list(JsonReaders.map(result)['products']).map((item) => ImportProductPreviewModel.fromJson(JsonReaders.map(item))).toList();
      setState(() {
        _items = items;
        _selected.addAll(items.where((item) => !item.alreadyImported).map((item) => item.sku));
      });
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    if (_store == null || _selected.isEmpty) return;
    setState(() => _saving = true);
    try {
      final products = _items.where((item) => _selected.contains(item.sku)).map((item) => item.toImportPayload()).toList();
      await ApiClient.instance.post('/products/import', body: <String, dynamic>{'store_id': _store!.id, 'products': products});
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
      padding: EdgeInsets.only(left: 18, right: 18, top: 18, bottom: MediaQuery.of(context).viewInsets.bottom + 18),
      child: ListView(shrinkWrap: true, children: <Widget>[
        const SectionHeader(title: 'Import Products', subtitle: 'Select a store and import active listings as inventory products.'),
        const SizedBox(height: 16),
        DropdownButtonFormField<StoreModel>(
          value: _store,
          decoration: const InputDecoration(labelText: 'Store'),
          items: widget.stores.map((store) => DropdownMenuItem(value: store, child: Text(store.name))).toList(),
          onChanged: (value) => setState(() => _store = value),
        ),
        const SizedBox(height: 12),
        PrimaryButton(label: 'Fetch Active Products', icon: Icons.download_rounded, onPressed: _store == null ? null : _fetch, loading: _loading, expanded: true),
        const SizedBox(height: 16),
        ..._items.map((item) => CheckboxListTile(
          value: _selected.contains(item.sku),
          onChanged: item.alreadyImported ? null : (_) => setState(() => _selected.contains(item.sku) ? _selected.remove(item.sku) : _selected.add(item.sku)),
          title: Text(item.suggestedName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${item.sku} • Stock ${item.stock}${item.alreadyImported ? ' • Already imported' : ''}'),
          secondary: ProductThumb(url: item.imageUrl),
        )),
        if (_items.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          PrimaryButton(label: 'Import Selected (${_selected.length})', onPressed: _selected.isEmpty ? null : _import, loading: _saving, expanded: true),
        ],
      ]),
    );
  }
}

class MasterProductPicker extends StatelessWidget {
  const MasterProductPicker({super.key, required this.products});
  final List<ProductItemModel> products;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        shrinkWrap: true,
        children: <Widget>[
          const SectionHeader(title: 'Choose Master Product', subtitle: 'The selected product name and master SKU will remain after merge.'),
          const SizedBox(height: 12),
          ...products.map((product) => ListTile(
            leading: ProductThumb(url: product.imageUrl),
            title: Text(product.name),
            subtitle: Text('${product.masterSku} • Stock ${product.stock}'),
            onTap: () => Navigator.pop(context, product),
          )),
        ],
      ),
    );
  }
}
