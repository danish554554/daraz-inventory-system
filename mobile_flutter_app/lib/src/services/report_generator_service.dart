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
    final periodLabel = period.toUpperCase();

    final revenue = JsonReaders.number(historySummary, 'revenue', 0.0);
    final totalCost = JsonReaders.number(historySummary, 'total_cost', 0.0);
    final profit = JsonReaders.number(historySummary, 'profit', revenue - totalCost);
    final profitMargin = JsonReaders.number(
      historySummary,
      'profit_margin',
      revenue > 0 ? (((revenue - totalCost) / revenue) * 100) : 0,
    );
    final totalOrders = JsonReaders.integer(historySummary, 'total_orders', orders.length);
    final returns = JsonReaders.integer(historySummary, 'returns', 0);
    final failedDeliveries = JsonReaders.integer(historySummary, 'failed_deliveries', 0);

    final buffer = StringBuffer();
    buffer.writeln('📊 *DARAZ EXECUTIVE PROFIT REPORT*');
    buffer.writeln('⏱️ Period: $periodLabel | Generated: $dateStr');
    buffer.writeln('🏪 Active Stores: $connectedStoresCount / $totalStoresCount Connected');
    buffer.writeln('');
    buffer.writeln('💰 *FINANCIAL METRICS:*');
    buffer.writeln('• Gross Revenue: PKR ${Formatters.money(revenue)}');
    buffer.writeln('• Product Cost (COGS): PKR ${Formatters.money(totalCost)}');
    buffer.writeln('• *Net True Profit:* *PKR ${Formatters.money(profit)}*');
    buffer.writeln('• *Profit Margin:* *${profitMargin > 0 ? profitMargin.toStringAsFixed(1) : "0.0"}%*');
    buffer.writeln('');
    buffer.writeln('📦 *ORDER VOLUME:*');
    buffer.writeln('• Total Orders Processed: ${Formatters.quantity(totalOrders)}');
    buffer.writeln('• Customer Returns: ${Formatters.quantity(returns)}');
    buffer.writeln('• Failed Delivery Parcels: ${Formatters.quantity(failedDeliveries)}');
    buffer.writeln('');
    buffer.writeln('⚠️ *INVENTORY & LOGISTICS RADAR:*');
    if (lowStockItems.isEmpty) {
      buffer.writeln('• ✅ All warehouse inventory stock levels are healthy.');
    } else {
      buffer.writeln('• 🚨 ${lowStockItems.length} SKU(s) below reorder threshold:');
      for (final item in lowStockItems.take(5)) {
        buffer.writeln('  - ${item.title} (${item.sellerSku}): *${item.stock} left*');
      }
      if (lowStockItems.length > 5) {
        buffer.writeln('  - ... and ${lowStockItems.length - 5} more items.');
      }
    }
    if (failedDeliveries > 0 || returns > 0) {
      buffer.writeln('');
      buffer.writeln('🚨 *ACTION REQUIRED:* ${failedDeliveries + returns} return parcels pending collection at Daraz logistics hub. Collect before 6-day scrap deadline.');
    }
    buffer.writeln('');
    buffer.writeln('🚀 _Powered by Daraz Multi-Store Profit Command Center v1.1_');

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
      subject: 'Daraz Executive Daily Profit Report - ${DateFormat('dd MMM').format(DateTime.now())}',
    );
  }
}
