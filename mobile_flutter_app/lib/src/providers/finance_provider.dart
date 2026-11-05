import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';

class FinanceProvider extends ChangeNotifier {
  bool _loading = true;
  bool _syncing = false;
  String? _error;

  String _selectedPeriod = 'all';
  String _selectedStoreId = 'all';
  String _search = '';
  String _activeTab = 'all'; // all, orders, adjustments, pending_cost

  List<StatementPeriodModel> _periods = <StatementPeriodModel>[];
  List<StoreModel> _stores = <StoreModel>[];
  FinanceSummary _summary = FinanceSummary.empty();
  List<FinanceEntry> _entries = <FinanceEntry>[];
  List<FinanceEntry> _filteredEntries = <FinanceEntry>[];

  // Getters
  bool get loading => _loading;
  bool get syncing => _syncing;
  String? get error => _error;
  String get selectedPeriod => _selectedPeriod;
  String get selectedStoreId => _selectedStoreId;
  String get search => _search;
  String get activeTab => _activeTab;

  List<StatementPeriodModel> get periods => _periods;
  List<StoreModel> get stores => _stores;
  FinanceSummary get summary => _summary;
  List<FinanceEntry> get entries => _entries;
  List<FinanceEntry> get filteredEntries => _filteredEntries;

  int get orderCount => _entries.where((e) => e.isOrder || e.orderNumber.isNotEmpty).length;
  int get adjustmentCount => _entries.where((e) => e.isAdjustment || e.isPenaltyCharged || e.isPenaltyReturned).length;
  int get pendingCostCount => _entries.where((e) => e.isOrder && !e.isProfitReady && e.productPrice > 0 && !e.isPenaltyCharged && !e.isPenaltyReturned).length;

  void _computeFilteredEntries() {
    final query = _search.trim().toLowerCase();
    _filteredEntries = _entries.where((item) {
      if (_activeTab == 'orders' && !item.isOrder && item.orderNumber.isEmpty) return false;
      if (_activeTab == 'adjustments' && !item.isAdjustment && !item.isPenaltyCharged && !item.isPenaltyReturned) return false;
      if (_activeTab == 'pending_cost') {
        if (!item.isOrder || item.isProfitReady || item.productPrice == 0 || item.isPenaltyCharged || item.isPenaltyReturned) return false;
      }
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

  void setSearch(String query) {
    if (_search == query) return;
    _search = query;
    _computeFilteredEntries();
    notifyListeners();
  }

  void setTab(String tab) {
    if (_activeTab == tab) return;
    _activeTab = tab;
    _computeFilteredEntries();
    notifyListeners();
  }

  Future<void> setPeriod(String period) async {
    if (_selectedPeriod == period) return;
    _selectedPeriod = period;
    notifyListeners();
    await load(forceRefresh: true);
  }

  Future<void> setStore(String storeId) async {
    if (_selectedStoreId == storeId) return;
    _selectedStoreId = storeId;
    notifyListeners();
    await load(forceRefresh: true);
  }

  Future<void> load({bool silent = false, bool forceRefresh = false}) async {
    if (!silent) {
      _loading = true;
      _error = null;
      notifyListeners();
    }

    try {
      final periodParam = _selectedPeriod == 'all' ? '' : _selectedPeriod;
      final storeParam = _selectedStoreId == 'all' ? '' : _selectedStoreId;

      final futures = <Future<dynamic>>[
        ApiClient.instance.get(
          '/finance/summary',
          queryParameters: <String, dynamic>{
            if (periodParam.isNotEmpty) 'statement_period': periodParam,
            if (storeParam.isNotEmpty) 'store_id': storeParam,
          },
          bypassCache: forceRefresh,
        ),
        ApiClient.instance.get(
          '/finance',
          queryParameters: <String, dynamic>{
            if (periodParam.isNotEmpty) 'statement_period': periodParam,
            if (storeParam.isNotEmpty) 'store_id': storeParam,
          },
          bypassCache: forceRefresh,
        ),
      ];

      final needPeriods = _periods.isEmpty || forceRefresh;
      final needStores = _stores.isEmpty || forceRefresh;

      if (needPeriods) futures.add(ApiClient.instance.get('/finance/periods', bypassCache: forceRefresh));
      if (needStores) futures.add(ApiClient.instance.get('/stores', bypassCache: forceRefresh));

      final results = await Future.wait<dynamic>(futures);

      final summaryMap = JsonReaders.map(results[0]);
      final entriesList = JsonReaders.list(results[1]).map((e) => FinanceEntry.fromJson(JsonReaders.map(e))).toList();

      var nextIdx = 2;
      if (needPeriods) {
        final periodsData = JsonReaders.map(results[nextIdx++]);
        _periods = JsonReaders.list(periodsData['periods']).map((p) => StatementPeriodModel.fromJson(JsonReaders.map(p))).toList();
      }
      if (needStores) {
        _stores = JsonReaders.list(results[nextIdx++]).map((s) => StoreModel.fromJson(JsonReaders.map(s))).toList();
      }

      _summary = FinanceSummary.fromJson(summaryMap);
      _entries = entriesList;
      _computeFilteredEntries();
      _error = null;
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Failed to load finance records.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<String> syncFromDaraz({String? period}) async {
    final targetPeriod = period ?? _selectedPeriod;
    _syncing = true;
    notifyListeners();

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
      ApiClient.instance.clearCache();
      await load(silent: true, forceRefresh: true);
      return msg;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> recalculate() async {
    _syncing = true;
    notifyListeners();
    try {
      await ApiClient.instance.post(
        '/finance/recalculate',
        body: <String, dynamic>{
          if (_selectedPeriod != 'all') 'statement_period': _selectedPeriod,
        },
      );
      ApiClient.instance.clearCache();
      await load(silent: true, forceRefresh: true);
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> clearData({String? period}) async {
    final targetPeriod = period ?? _selectedPeriod;
    final queryParam = (targetPeriod != 'all') ? <String, dynamic>{'statement_period': targetPeriod} : null;
    await ApiClient.instance.delete('/finance/clear', queryParameters: queryParam);
    ApiClient.instance.clearCache();
    await load(silent: true, forceRefresh: true);
  }

  Future<void> setCostPrice({required String sellerSku, required double costPrice}) async {
    await ApiClient.instance.post(
      '/finance/set-cost',
      body: <String, dynamic>{
        'seller_sku': sellerSku,
        'cost_price': costPrice,
      },
    );
    ApiClient.instance.clearCache();
    await load(silent: true, forceRefresh: true);
  }
}
