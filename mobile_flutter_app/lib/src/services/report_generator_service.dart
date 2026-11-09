import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/app_models.dart';
import 'formatters.dart';

class ReportGeneratorService {
  static String generateDailySummaryText({
    required Map<String, dynamic> historySummary,
    required List<CentralOrder> orders,
    required List<InventoryItem> lowStockItems,
    required String period,
    required int connectedStoresCount,
    required int totalStoresCount,
  }) {
    final now = DateTime.now();
    final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(now);
    final periodLabel = period.replaceAll('_', ' ').toUpperCase();

    final revenue = JsonReaders.number(
      historySummary,
      'revenue',
      JsonReaders.number(historySummary, 'gross_amount', 0.0),
    );
    final totalCost = JsonReaders.number(historySummary, 'total_cost', 0.0);
    final totalOrders = JsonReaders.integer(historySummary, 'total_orders', orders.length);
    final returns = JsonReaders.integer(historySummary, 'returns', 0);
    final failedDeliveries = JsonReaders.integer(historySummary, 'failed_deliveries', 0);

    final buffer = StringBuffer();
    buffer.writeln('📊 *DARAZ DAILY SALES & DISPATCH REPORT*');
    buffer.writeln('📅 *Date:* $dateStr');
    buffer.writeln('⏱️ *Period:* $periodLabel');
    buffer.writeln('🏪 *Connected Stores:* $connectedStoresCount / $totalStoresCount Active');
    buffer.writeln('');
    buffer.writeln('💰 *SALES & REVENUE:*');
    buffer.writeln('• Gross Sales Value: PKR ${Formatters.money(revenue)}');
    if (totalCost > 0) {
      buffer.writeln('• Est. Product Cost (COGS): PKR ${Formatters.money(totalCost)}');
    }
    buffer.writeln('');
    buffer.writeln('📦 *ORDER & DISPATCH METRICS:*');
    buffer.writeln('• Total Orders Processed: ${Formatters.quantity(totalOrders)}');
    buffer.writeln('• Customer Returns: ${Formatters.quantity(returns)}');
    buffer.writeln('• Failed Delivery Parcels: ${Formatters.quantity(failedDeliveries)}');

    final pendingParcels = failedDeliveries + returns;
    if (pendingParcels > 0) {
      buffer.writeln('');
      buffer.writeln('⚠️ *Hub Notice:* $pendingParcels return parcel(s) pending collection from Daraz logistics hub.');
    }

    return buffer.toString();
  }

  static Future<void> shareDailySummary({
    required Map<String, dynamic> historySummary,
    required List<CentralOrder> orders,
    required List<InventoryItem> lowStockItems,
    required String period,
    required int connectedStoresCount,
    required int totalStoresCount,
  }) async {
    final text = generateDailySummaryText(
      historySummary: historySummary,
      orders: orders,
      lowStockItems: lowStockItems,
      period: period,
      connectedStoresCount: connectedStoresCount,
      totalStoresCount: totalStoresCount,
    );

    await Share.share(
      text,
      subject: 'Daraz Daily Sales Report - ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
    );
  }
}
