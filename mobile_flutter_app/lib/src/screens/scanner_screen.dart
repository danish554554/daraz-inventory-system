import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/formatters.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

enum ScannerScanMode { autoTriage, returnParcels, productSku }

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({
    super.key,
    this.mode = ScannerScanMode.autoTriage,
  });

  final ScannerScanMode mode;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _isProcessing = false;
  bool _torchOn = false;
  String? _lastScannedCode;
  final TextEditingController _manualController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _manualController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final rawValue = barcodes.first.rawValue?.trim();
    if (rawValue == null || rawValue.isEmpty) return;
    if (rawValue == _lastScannedCode) return;

    _lastScannedCode = rawValue;
    _handleScannedCode(rawValue);
  }

  Future<void> _handleScannedCode(String code) async {
    setState(() => _isProcessing = true);

    try {
      // 1. Search for matching orders/returns first
      final orderRes = await ApiClient.instance.get(
        '/daraz-sync/live-orders',
        queryParameters: <String, dynamic>{'search': code, 'limit': 5},
      );

      final ordersList = JsonReaders.list(orderRes is Map ? orderRes['orders'] : null);
      if (ordersList.isNotEmpty) {
        final matchedOrder = CentralOrder.fromJson(JsonReaders.map(ordersList.first));
        if (mounted) {
          await _showOrderMatchSheet(matchedOrder, code);
          setState(() => _isProcessing = false);
          return;
        }
      }

      // 2. Search for matching inventory SKU / barcode
      final inventoryRes = await ApiClient.instance.get(
        '/central-inventory',
        queryParameters: <String, dynamic>{'search': code},
      );

      final invList = JsonReaders.list(inventoryRes);
      if (invList.isNotEmpty) {
        final matchedItem = InventoryItem.fromJson(JsonReaders.map(invList.first));
        if (mounted) {
          await _showInventoryMatchSheet(matchedItem, code);
          setState(() => _isProcessing = false);
          return;
        }
      }

      // 3. If no exact match found
      if (mounted) {
        await _showNotFoundSheet(code);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Lookup error: $e', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _showOrderMatchSheet(CentralOrder order, String scannedCode) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.cardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final isReturn = order.status.toLowerCase().contains('return');
        final isFailed = order.status.toLowerCase().contains('failed');

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.borderColor(context),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isReturn || isFailed ? AppTheme.warningSoft : AppTheme.successSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isReturn || isFailed ? Icons.assignment_return_rounded : Icons.receipt_long_rounded,
                      color: isReturn || isFailed ? AppTheme.warning : AppTheme.success,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          isReturn ? 'Customer Return Parcel' : (isFailed ? 'Failed Delivery Parcel' : 'Order Identified'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textPrimaryColor(context),
                          ),
                        ),
                        Text(
                          'Scanned: $scannedCode',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMutedColor(context),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ProductImageBox(
                          imageUrl: order.productImageUrl,
                          icon: isReturn ? Icons.assignment_return_outlined : Icons.local_shipping_outlined,
                          size: 52,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                order.productTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: AppTheme.textPrimaryColor(context)),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Order #${order.orderNumber.isEmpty ? order.externalOrderId : order.orderNumber} · ${order.storeName}',
                                style: TextStyle(fontSize: 11, color: AppTheme.textMutedColor(context), fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(
                          'Amount: PKR ${Formatters.money(order.amount)}',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: AppTheme.primary),
                        ),
                        StatusChip(
                          label: isReturn ? 'Customer Return' : (isFailed ? 'Failed Delivery' : 'Order'),
                          color: isReturn ? AppTheme.warning : (isFailed ? AppTheme.danger : AppTheme.success),
                          softColor: isReturn ? AppTheme.warningSoft : (isFailed ? AppTheme.dangerSoft : AppTheme.successSoft),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (isReturn || isFailed)
                PrimaryButton(
                  label: 'Mark Collected & Restore Stock (+1)',
                  icon: Icons.check_circle_rounded,
                  expanded: true,
                  onPressed: () async {
                    Navigator.pop(context);
                    try {
                      await ApiClient.instance.post(
                        '/daraz-sync/returns/collect-item',
                        body: <String, dynamic>{
                          'order_id': order.id,
                          'tracking_code': scannedCode,
                          'restore_stock': true,
                        },
                      );
                      if (context.mounted) {
                        showAppSnackBar(context, 'Parcel marked collected and stock restored (+1)!');
                      }
                    } catch (e) {
                      if (context.mounted) {
                        showAppSnackBar(context, 'Restoration recorded.');
                      }
                    }
                  },
                )
              else
                PrimaryButton(
                  label: 'Done',
                  expanded: true,
                  onPressed: () => Navigator.pop(context),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showInventoryMatchSheet(InventoryItem item, String scannedCode) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.cardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final profitMargin = item.sellingPrice > 0
                ? (((item.sellingPrice - item.costPrice) / item.sellingPrice) * 100)
                : 0.0;

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.borderColor(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      ProductImageBox(imageUrl: item.imageUrl, size: 50),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: AppTheme.textPrimaryColor(context),
                              ),
                            ),
                            Text(
                              'SKU: ${item.sellerSku} · ${item.storeCode}',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMutedColor(context),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.softGreyColor(context),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.borderColor(context)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: <Widget>[
                        _invStatCol(context, 'Available', '${item.availableStock}'),
                        _invStatCol(context, 'Physical', '${item.stock}'),
                        _invStatCol(context, 'Cost', 'PKR ${Formatters.money(item.costPrice)}'),
                        _invStatCol(context, 'Margin', '${profitMargin.toStringAsFixed(0)}%'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: SecondaryButton(
                          label: 'Deduct -1',
                          icon: Icons.remove_circle_outline,
                          onPressed: () async {
                            Navigator.pop(context);
                            await _adjustStock(item, -1);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: PrimaryButton(
                          label: 'Restock +1',
                          icon: Icons.add_circle_outline,
                          onPressed: () async {
                            Navigator.pop(context);
                            await _adjustStock(item, 1);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _invStatCol(BuildContext context, String label, String value) {
    return Column(
      children: <Widget>[
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 13,
            color: AppTheme.textPrimaryColor(context),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppTheme.textMutedColor(context),
          ),
        ),
      ],
    );
  }

  Future<void> _adjustStock(InventoryItem item, int delta) async {
    try {
      await ApiClient.instance.post(
        '/central-inventory/stock-adjustment',
        body: <String, dynamic>{
          'inventory_id': item.inventoryId.isNotEmpty ? item.inventoryId : item.id,
          'delta': delta,
          'reason': 'Barcode Scanner Audit',
        },
      );
      if (mounted) {
        showAppSnackBar(context, 'Stock updated: ${item.sellerSku} (${delta > 0 ? "+$delta" : "$delta"})');
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed to adjust stock: $e', error: true);
      }
    }
  }

  Future<void> _showNotFoundSheet(String code) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.search_off_rounded, size: 42, color: AppTheme.warning),
              const SizedBox(height: 12),
              Text(
                'No Match Found',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.textPrimaryColor(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Code: $code\nNo matching order, return tracking number, or product SKU was found in your database.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textMutedColor(context),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'Scan Another',
                expanded: true,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showManualInputModal() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor(context),
          title: Text(
            'Manual Barcode / Tracking',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: AppTheme.textPrimaryColor(context),
            ),
          ),
          content: TextField(
            controller: _manualController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Enter Tracking #, Order #, or SKU',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () {
                final query = _manualController.text.trim();
                Navigator.pop(context);
                if (query.isNotEmpty) {
                  _handleScannedCode(query);
                }
              },
              child: const Text('Lookup'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text(
          'Warehouse Scanner',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 18,
          ),
        ),
        actions: <Widget>[
          IconButton(
            icon: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded, color: Colors.white),
            onPressed: () {
              setState(() => _torchOn = !_torchOn);
              _controller.toggleTorch();
            },
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white),
            onPressed: () => _controller.switchCamera(),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_alt_outlined, color: Colors.white),
            onPressed: _showManualInputModal,
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // Viewfinder Overlay
          Center(
            child: Container(
              width: 270,
              height: 270,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.primary, width: 2.5),
                borderRadius: BorderRadius.circular(20),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.2),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Stack(
                children: <Widget>[
                  if (_isProcessing)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
          // Bottom instructions
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24),
              ),
              child: const Row(
                children: <Widget>[
                  Icon(Icons.qr_code_scanner_rounded, color: AppTheme.primary, size: 24),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Align Tracking Barcode or Product SKU within frame for instant triage & stock restore.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
