import 'package:flutter/material.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../services/app_config.dart';
import '../services/formatters.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class StoresScreen extends StatefulWidget {
  const StoresScreen({super.key});

  @override
  State<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends State<StoresScreen> {
  bool _loading = true;
  String? _error;
  String _search = '';
  List<StoreModel> _stores = <StoreModel>[];
  StoreSummary? _summary;

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
      final response = await ApiClient.instance.get('/stores') as Map<String, dynamic>;
      setState(() {
        _stores = JsonReaders.list(response['stores'])
            .map((item) => StoreModel.fromJson(JsonReaders.map(item)))
            .toList();
        _summary = StoreSummary.fromJson(JsonReaders.map(response['summary']));
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Failed to load stores.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<StoreModel> get _filteredStores {
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return _stores;
    return _stores.where((store) {
      return store.name.toLowerCase().contains(query) ||
          store.code.toLowerCase().contains(query) ||
          store.country.toLowerCase().contains(query) ||
          store.healthLabel.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _openCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const StoreFormSheet(),
    );
    if (created == true) {
      await _load();
    }
  }

  Future<void> _openEditSheet(StoreModel store) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StoreFormSheet(store: store),
    );
    if (updated == true) {
      await _load();
    }
  }

  Future<void> _connectStore(StoreModel store) async {
    try {
      final response = await ApiClient.instance.get(
        '/stores/oauth/${store.id}/connect',
        queryParameters: <String, dynamic>{
          'client_redirect_uri': AppConfig.oauthCallbackUrl,
          'force_auth': true,
        },
      ) as Map<String, dynamic>;
      final url = response['authorize_url']?.toString();
      if (url == null || url.isEmpty) {
        throw ApiException(message: 'Daraz authorization URL was not returned.');
      }

      final callbackUrl = await FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: AppConfig.oauthCallbackScheme,
      );

      final callback = Uri.parse(callbackUrl);
      final oauthStatus = callback.queryParameters['oauth'];
      final message = callback.queryParameters['message']?.trim() ?? '';

      if (oauthStatus == 'success') {
        await _load();
        if (mounted) {
          showAppSnackBar(context, '${store.name} connected to Daraz successfully.');
        }
        return;
      }

      if (mounted) {
        showAppSnackBar(
          context,
          message.isNotEmpty ? message : 'Daraz connection was not completed.',
          error: true,
        );
      }
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (mounted) {
        showAppSnackBar(
          context,
          message.contains('canceled') || message.contains('cancelled')
              ? 'Daraz connection was cancelled.'
              : 'Failed to start Daraz connection.',
          error: true,
        );
      }
    }
  }

  Future<void> _validateStore(StoreModel store) async {
    try {
      await ApiClient.instance.post('/stores/${store.id}/validate-connection');
      await _load();
      if (mounted) showAppSnackBar(context, 'Store connection checked.');
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  Future<void> _disconnectStore(StoreModel store) async {
    final confirmed = await _confirm(
      title: 'Disconnect ${store.name}?',
      message: 'This removes the saved Daraz access token for the store.',
      confirmText: 'Disconnect',
    );
    if (!confirmed) return;

    try {
      await ApiClient.instance.post('/stores/${store.id}/disconnect');
      await _load();
      if (mounted) showAppSnackBar(context, 'Store disconnected successfully.');
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  Future<void> _deleteStore(StoreModel store) async {
    final confirmed = await _confirm(
      title: 'Delete ${store.name}?',
      message: 'This also removes synced orders, inventory rows, transactions, and store sync logs.',
      confirmText: 'Delete',
    );
    if (!confirmed) return;

    try {
      await ApiClient.instance.delete('/stores/${store.id}');
      await _load();
      if (mounted) showAppSnackBar(context, 'Store deleted successfully.');
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  Future<void> _syncStore(StoreModel store) async {
    try {
      final response = await ApiClient.instance.post('/daraz-sync/run-store/${store.id}') as Map<String, dynamic>;
      await _load();
      if (mounted) showAppSnackBar(context, response['message']?.toString() ?? 'Store sync completed.');
    } on ApiException catch (error) {
      if (mounted) showAppSnackBar(context, error.message, error: true);
    }
  }

  Future<void> _importProductsForStore(StoreModel store) async {
    try {
      await ApiClient.instance.post('/daraz-sync/import-products/${store.id}');
      await _load();
      if (mounted) {
        showAppSnackBar(context, 'Active Daraz products imported successfully.');
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Failed to import Daraz products. Please try again.',
          error: true,
        );
      }
    }
  }

  Future<bool> _confirm({required String title, required String message, required String confirmText}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stores'),
        actions: <Widget>[
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateSheet,
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Store'),
      ),
      body: SafeArea(
        child: _loading
            ? const AppLoader(label: 'Loading stores...')
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: EmptyState(
                      title: 'Could not load stores',
                      message: _error!,
                      icon: Icons.store_mall_directory_outlined,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                      children: <Widget>[
                        const SectionHeader(
                          title: 'Stores',
                          subtitle: 'Configure Daraz stores, health, token status, and sync behavior.',
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search stores...',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (value) => setState(() => _search = value),
                        ),
                        const SizedBox(height: 18),
                        _summaryCards(context),
                        const SizedBox(height: 20),
                        if (_filteredStores.isEmpty)
                          const EmptyState(
                            title: 'No stores found',
                            message: 'Create a store first, then connect it to Daraz from this screen.',
                            icon: Icons.storefront_outlined,
                          )
                        else
                          ..._filteredStores.map(_buildStoreCard),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _summaryCards(BuildContext context) {
    final summary = _summary;
    if (summary == null) return const SizedBox.shrink();
    final width = MediaQuery.of(context).size.width;
    final itemWidth = width < 380 ? width - 40 : (width - 56) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(width: itemWidth, child: MetricCard(label: 'Configured', value: '${summary.totalStores}', icon: Icons.storefront_outlined)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Connected', value: '${summary.connectedStores}', icon: Icons.link_rounded, tint: AppTheme.successSoft, iconColor: AppTheme.success)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Healthy', value: '${summary.healthyStores}', icon: Icons.check_circle_outline, tint: AppTheme.successSoft, iconColor: AppTheme.success)),
        SizedBox(width: itemWidth, child: MetricCard(label: 'Needs Setup', value: '${summary.setupRequired + summary.reconnectRequired}', icon: Icons.warning_amber_rounded, tint: AppTheme.warningSoft, iconColor: AppTheme.warning)),
      ],
    );
  }

  Widget _buildStoreCard(StoreModel store) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: AppCard(
        onTap: () async {
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (context) => StoreDetailSheet(
              store: store,
              onEdit: () async {
                Navigator.pop(context);
                await _openEditSheet(store);
              },
              onConnect: () => _connectStore(store),
              onValidate: () => _validateStore(store),
              onDisconnect: () => _disconnectStore(store),
              onDelete: () => _deleteStore(store),
              onSync: () => _syncStore(store),
              onImportProducts: () => _importProductsForStore(store),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      store.country,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 4),
                      Text('${store.code} • ${store.account.isEmpty ? 'Seller not linked' : store.account}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                _healthChip(store),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                _tag(store.tokenConnected ? 'Connected' : 'Disconnected', store.tokenConnected ? AppTheme.success : AppTheme.danger, store.tokenConnected ? AppTheme.successSoft : AppTheme.dangerSoft),
                _tag('Token ${store.tokenStatus.replaceAll('_', ' ')}', AppTheme.primary, AppTheme.primarySoft),
                _tag('${store.syncIntervalMinutes} min interval', AppTheme.textPrimary, AppTheme.background),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              store.healthReason.isEmpty ? 'No issues reported.' : store.healthReason,
              style: const TextStyle(color: AppTheme.textMuted, height: 1.35),
            ),
            const SizedBox(height: 12),
            Text(
              'Last sync: ${Formatters.dateTime(store.lastSyncFinishedAt)}',
              style: const TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }

  Widget _healthChip(StoreModel store) {
    switch (store.healthState) {
      case 'healthy':
        return const StatusChip(label: 'Active', color: AppTheme.success, softColor: AppTheme.successSoft);
      case 'attention':
      case 'setup_required':
      case 'not_connected':
        return const StatusChip(label: 'Attention', color: AppTheme.warning, softColor: AppTheme.warningSoft);
      case 'reconnect_required':
      case 'sync_error':
        return const StatusChip(label: 'Issue', color: AppTheme.danger, softColor: AppTheme.dangerSoft);
      default:
        return const StatusChip(label: 'Inactive', color: AppTheme.textMuted, softColor: AppTheme.background);
    }
  }
}

class StoreFormSheet extends StatefulWidget {
  const StoreFormSheet({super.key, this.store});

  final StoreModel? store;

  @override
  State<StoreFormSheet> createState() => _StoreFormSheetState();
}

class _StoreFormSheetState extends State<StoreFormSheet> {
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _notesController = TextEditingController();
  final _syncIntervalController = TextEditingController();

  String _platform = 'daraz';
  String _country = 'PK';
  String _status = 'active';
  String _deductStage = 'ready_to_ship';
  bool _restoreOnCancel = true;
  bool _saving = false;

  bool get _isEditing => widget.store != null;

  @override
  void initState() {
    super.initState();
    final store = widget.store;
    _nameController.text = store?.name ?? '';
    _codeController.text = store?.code ?? '';
    _notesController.text = store?.notes ?? '';
    _syncIntervalController.text = (store?.syncIntervalMinutes ?? 5).toString();
    _platform = store?.platform ?? 'daraz';
    _country = store?.country ?? 'PK';
    _status = store?.status ?? 'active';
    _deductStage = store?.deductStage ?? 'ready_to_ship';
    _restoreOnCancel = store?.restoreOnCancel ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _notesController.dispose();
    _syncIntervalController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameController.text.trim().isEmpty || (!_isEditing && _codeController.text.trim().isEmpty)) {
      showAppSnackBar(context, 'Store name and code are required.', error: true);
      return;
    }

    setState(() => _saving = true);
    final payload = <String, dynamic>{
      'name': _nameController.text.trim(),
      'code': _codeController.text.trim(),
      'platform': _platform,
      'country': _country,
      'status': _status,
      'deduct_stage': _deductStage,
      'restore_on_cancel': _restoreOnCancel,
      'sync_interval_minutes': int.tryParse(_syncIntervalController.text.trim()) ?? 5,
      'notes': _notesController.text.trim(),
    };

    try {
      if (_isEditing) {
        await ApiClient.instance.put('/stores/${widget.store!.id}', body: payload);
      } else {
        await ApiClient.instance.post('/stores', body: payload);
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
              title: _isEditing ? 'Edit Store' : 'Add Store',
              subtitle: 'Set the same store sync rules already used by your backend.',
              action: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ),
            const SizedBox(height: 16),
            AppTextField(controller: _nameController, labelText: 'Store name', hintText: 'DZ Pakistan Main'),
            const SizedBox(height: 12),
            AppTextField(controller: _codeController, labelText: 'Store code', hintText: 'DZ-PK-001', enabled: !_isEditing),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _country,
              decoration: const InputDecoration(labelText: 'Country'),
              items: const <String>['PK', 'BD', 'LK', 'NP', 'MM']
                  .map((value) => DropdownMenuItem<String>(value: value, child: Text(value)))
                  .toList(),
              onChanged: (value) => setState(() => _country = value ?? 'PK'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const <String>['active', 'inactive']
                  .map((value) => DropdownMenuItem<String>(value: value, child: Text(value)))
                  .toList(),
              onChanged: (value) => setState(() => _status = value ?? 'active'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _deductStage,
              decoration: const InputDecoration(labelText: 'Deduct stage'),
              items: const <String>['created', 'pending', 'unpaid', 'packed', 'ready_to_ship', 'shipped', 'delivered']
                  .map((value) => DropdownMenuItem<String>(value: value, child: Text(value.replaceAll('_', ' '))))
                  .toList(),
              onChanged: (value) => setState(() => _deductStage = value ?? 'ready_to_ship'),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _syncIntervalController,
              labelText: 'Sync interval (minutes)',
              keyboardType: TextInputType.number,
              hintText: '5',
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _restoreOnCancel,
              activeThumbColor: AppTheme.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('Restore stock on cancel', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Matches the server-side store behavior.'),
              onChanged: (value) => setState(() => _restoreOnCancel = value),
            ),
            const SizedBox(height: 12),
            AppTextField(controller: _notesController, labelText: 'Notes', maxLines: 3, hintText: 'Any internal notes for this store'),
            const SizedBox(height: 20),
            PrimaryButton(
              label: _isEditing ? 'Save Store' : 'Create Store',
              icon: Icons.check_circle_outline,
              expanded: true,
              loading: _saving,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class StoreDetailSheet extends StatefulWidget {
  const StoreDetailSheet({
    super.key,
    required this.store,
    required this.onEdit,
    required this.onConnect,
    required this.onValidate,
    required this.onDisconnect,
    required this.onDelete,
    required this.onSync,
    required this.onImportProducts,
  });

  final StoreModel store;
  final VoidCallback onEdit;
  final VoidCallback onConnect;
  final VoidCallback onValidate;
  final VoidCallback onDisconnect;
  final VoidCallback onDelete;
  final VoidCallback onSync;
  final VoidCallback onImportProducts;

  @override
  State<StoreDetailSheet> createState() => _StoreDetailSheetState();
}

class _StoreDetailSheetState extends State<StoreDetailSheet> {
  bool _loading = true;
  StoreHealthDetail? _detail;
  String? _error;

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
      final response = await ApiClient.instance.get('/stores/${widget.store.id}/health', queryParameters: <String, dynamic>{'limit': 10}) as Map<String, dynamic>;
      setState(() => _detail = StoreHealthDetail.fromJson(response));
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: widget.store.name,
              subtitle: '${widget.store.code} • ${widget.store.country}',
              action: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ),
            const SizedBox(height: 18),
            if (_loading)
              const AppLoader(label: 'Loading store health...')
            else if (_error != null)
              EmptyState(title: 'Store health unavailable', message: _error!, icon: Icons.error_outline)
            else ...<Widget>[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        _infoPill('Health', _detail!.store.healthLabel),
                        _infoPill('Token', _detail!.store.tokenStatus.replaceAll('_', ' ')),
                        _infoPill('Deduct Stage', _detail!.store.deductStage.replaceAll('_', ' ')),
                        _infoPill('Interval', '${_detail!.store.syncIntervalMinutes} min'),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(_detail!.store.healthReason, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted, height: 1.4)),
                    const SizedBox(height: 10),
                    Text('Last sync: ${Formatters.dateTime(_detail!.store.lastSyncFinishedAt)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('Latest status: ${_detail!.store.lastSyncMessage.isEmpty ? 'No sync message' : _detail!.store.lastSyncMessage}', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  SizedBox(width: 160, child: PrimaryButton(label: 'Sync Now', onPressed: widget.onSync, icon: Icons.sync, expanded: true)),
                  SizedBox(width: 160, child: SecondaryButton(label: 'Import Products', onPressed: widget.store.tokenConnected ? widget.onImportProducts : null, icon: Icons.cloud_download_outlined)),
                  SizedBox(width: 160, child: SecondaryButton(label: 'Validate', onPressed: widget.onValidate, icon: Icons.verified_outlined)),
                  SizedBox(width: 160, child: SecondaryButton(label: 'Edit', onPressed: widget.onEdit, icon: Icons.edit_outlined)),
                  SizedBox(width: 160, child: SecondaryButton(label: widget.store.tokenConnected ? 'Disconnect' : 'Connect Daraz', onPressed: widget.store.tokenConnected ? widget.onDisconnect : widget.onConnect, icon: widget.store.tokenConnected ? Icons.link_off_outlined : Icons.link_rounded)),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Recent Sync Logs', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 10),
              if (_detail!.syncLogs.isEmpty)
                const EmptyState(title: 'No sync logs yet', message: 'Logs will appear here after scheduler or manual sync runs.', icon: Icons.history_toggle_off)
              else
                ..._detail!.syncLogs.map((log) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(log.summaryMessage.isEmpty ? 'Sync run' : log.summaryMessage, style: const TextStyle(fontWeight: FontWeight.w800)),
                                ),
                                StatusChip(
                                  label: log.success == true ? 'Success' : log.success == false ? 'Failed' : 'Unknown',
                                  color: log.success == true ? AppTheme.success : AppTheme.danger,
                                  softColor: log.success == true ? AppTheme.successSoft : AppTheme.dangerSoft,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text('Started ${Formatters.dateTime(log.syncStartedAt)} • ${Formatters.durationMs(log.durationMs)}', style: const TextStyle(color: AppTheme.textMuted)),
                            const SizedBox(height: 8),
                            Text('Processed ${log.processed} • Deducted ${log.deducted} • Restored ${log.restored} • Failed ${log.failed}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    )),
              const SizedBox(height: 10),
              SecondaryButton(label: 'Delete Store', onPressed: widget.onDelete, icon: Icons.delete_outline),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(16)),
      child: Text('$label: $value', style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}
