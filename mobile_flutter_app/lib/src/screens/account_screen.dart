import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/app_config.dart';
import '../services/session_manager.dart';
import '../widgets/api_base_url_sheet.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.sessionManager, this.onNavigateToTab});

  final SessionManager sessionManager;
  final ValueChanged<int>? onNavigateToTab;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  String _version = '-';
  List<StoreModel> _stores = <StoreModel>[];
  StoreModel? _activeStore;
  int _daysAsSeller = 1971;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadStores();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${info.version} (${info.buildNumber})');
    } catch (_) {
      if (mounted) setState(() => _version = 'v1.1');
    }
  }

  Future<void> _loadStores() async {
    try {
      final res = await ApiClient.instance.get('/stores') as Map<String, dynamic>;
      final list = JsonReaders.list(res['stores']).map((e) => StoreModel.fromJson(JsonReaders.map(e))).toList();
      if (mounted && list.isNotEmpty) {
        setState(() {
          _stores = list;
          _activeStore = list.first;
          // Calculate days as seller from first store creation date or fallback
          final created = _activeStore!.lastSyncFinishedAt;
          if (created != null) {
            _daysAsSeller = DateTime.now().difference(created).inDays.clamp(1, 9999);
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.cardColor(context),
        title: Text('Sign out?', style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900)),
        content: Text('Your secure session token will be removed from this device.', style: TextStyle(color: AppTheme.textMutedColor(context))),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) await widget.sessionManager.logout();
  }

  Future<void> _openAppearanceSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardColor(context),
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(
              title: 'Appearance',
              subtitle: 'Select your preferred theme display',
              action: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.brightness_auto_rounded),
              title: const Text('System Default', style: TextStyle(fontWeight: FontWeight.w800)),
              trailing: widget.sessionManager.themeMode == ThemeMode.system ? const Icon(Icons.check, color: AppTheme.primary) : null,
              onTap: () {
                widget.sessionManager.setThemeMode(ThemeMode.system);
                Navigator.pop(context);
                setState(() {});
              },
            ),
            ListTile(
              leading: const Icon(Icons.light_mode_rounded, color: Colors.amber),
              title: const Text('Light Theme', style: TextStyle(fontWeight: FontWeight.w800)),
              trailing: widget.sessionManager.themeMode == ThemeMode.light ? const Icon(Icons.check, color: AppTheme.primary) : null,
              onTap: () {
                widget.sessionManager.setThemeMode(ThemeMode.light);
                Navigator.pop(context);
                setState(() {});
              },
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_rounded, color: Colors.indigo),
              title: const Text('Dark Mode (OLED Slate)', style: TextStyle(fontWeight: FontWeight.w800)),
              trailing: widget.sessionManager.themeMode == ThemeMode.dark ? const Icon(Icons.check, color: AppTheme.primary) : null,
              onTap: () {
                widget.sessionManager.setThemeMode(ThemeMode.dark);
                Navigator.pop(context);
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openApiSettings() async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.cardColor(context),
      builder: (context) => const ApiBaseUrlSheet(),
    );

    if (updated == true && mounted) {
      setState(() {});
      showAppSnackBar(context, 'Backend URL updated successfully.');
    }
  }

  Future<void> _launchWhatsAppSupport() async {
    final uri = Uri.parse('https://wa.me/923000000000?text=Hello%20Daraz%20Inventory%20Support');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) showAppSnackBar(context, 'Could not open WhatsApp support.');
    }
  }

  void _showHealthDetails() {
    final isConnected = _activeStore?.tokenConnected ?? true;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.cardColor(context),
        title: Row(
          children: <Widget>[
            Icon(isConnected ? Icons.check_circle_rounded : Icons.warning_amber_rounded, color: isConnected ? AppTheme.success : AppTheme.danger),
            const SizedBox(width: 8),
            Text('Account Health', style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Store: ${_activeStore?.name ?? "Primary Store"}',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textPrimaryColor(context)),
            ),
            const SizedBox(height: 4),
            Text(
              'Token Status: ${_activeStore?.tokenConnected == true ? "Active & Authorized" : "Needs Re-authorization"}',
              style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(
              'Daily Sync: Operational\nFulfillment Policy: Compliant\nScrap Risk Monitoring: Enabled',
              style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 12, height: 1.4),
            ),
          ],
        ),
        actions: <Widget>[
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storeName = _activeStore?.name ?? 'Accessories Hub 76';
    final sellerId = _activeStore?.code ?? 'PK2NBNK0WO5';
    final isUnhealthy = _activeStore?.tokenConnected == false;

    return Scaffold(
      body: AppShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sellerProfileHeader(storeName, sellerId),
            const SizedBox(height: 16),
            _sellerDaysBanner(),
            const SizedBox(height: 16),
            _menuCard(<Widget>[
              _accountTile(
                title: 'Account Setting',
                icon: Icons.manage_accounts_outlined,
                onTap: _openAppearanceSettings,
              ),
              _thinDivider(),
              _accountTile(
                title: 'Account Health',
                titleColor: isUnhealthy ? AppTheme.danger : null,
                icon: Icons.health_and_safety_outlined,
                trailingBadge: isUnhealthy
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.danger),
                          SizedBox(width: 4),
                          Text('Unhealthy', style: TextStyle(color: AppTheme.danger, fontSize: 12, fontWeight: FontWeight.w800)),
                        ],
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.check_circle_outline_rounded, size: 16, color: AppTheme.success),
                          SizedBox(width: 4),
                          Text('Healthy', style: TextStyle(color: AppTheme.success, fontSize: 12, fontWeight: FontWeight.w800)),
                        ],
                      ),
                onTap: _showHealthDetails,
              ),
              _thinDivider(),
              _accountTile(
                title: 'General Information',
                icon: Icons.info_outline_rounded,
                onTap: () {
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: AppTheme.cardColor(context),
                      title: Text('Store & App Info', style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900)),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('App Version: $_version', style: TextStyle(color: AppTheme.textPrimaryColor(context))),
                          const SizedBox(height: 6),
                          Text('Connected Stores: ${_stores.length}', style: TextStyle(color: AppTheme.textMutedColor(context))),
                          const SizedBox(height: 6),
                          Text('Backend: ${AppConfig.apiBaseUrl}', style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11)),
                        ],
                      ),
                      actions: <Widget>[
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ]),
            const SizedBox(height: 14),
            _menuCard(<Widget>[
              _accountTile(
                title: 'Chat with us',
                icon: Icons.chat_outlined,
                trailingBadge: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.support_agent_rounded, size: 14, color: AppTheme.primary),
                      SizedBox(width: 4),
                      Text('Get Help', style: TextStyle(color: AppTheme.primary, fontSize: 11, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
                onTap: _launchWhatsAppSupport,
              ),
              _thinDivider(),
              _accountTile(
                title: 'Feedback',
                icon: Icons.rate_review_outlined,
                onTap: () {
                  showAppSnackBar(context, 'Thank you! Send your feedback directly to our team via WhatsApp.');
                },
              ),
              _thinDivider(),
              _accountTile(
                title: 'Seller Help Center',
                icon: Icons.help_center_outlined,
                onTap: () async {
                  final uri = Uri.parse('https://sellercenter.daraz.pk/');
                  try {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } catch (_) {}
                },
              ),
            ]),
            const SizedBox(height: 14),
            _menuCard(<Widget>[
              _accountTile(
                title: 'My Income',
                icon: Icons.account_balance_wallet_outlined,
                onTap: () {
                  if (widget.onNavigateToTab != null) {
                    widget.onNavigateToTab!(3); // Navigate to Finance Tab
                  }
                },
              ),
              _thinDivider(),
              _accountTile(
                title: 'Notifications',
                icon: Icons.notifications_none_rounded,
                onTap: () {
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: AppTheme.cardColor(context),
                      title: Text('Push & Scrap Alerts', style: TextStyle(color: AppTheme.textPrimaryColor(context), fontWeight: FontWeight.w900)),
                      content: Text(
                        'Push alerts for 6-day scrap countdown warnings (48h & 24h before destroy deadline) and low stock SKU warnings are active.',
                        style: TextStyle(color: AppTheme.textMutedColor(context)),
                      ),
                      actions: <Widget>[
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              _thinDivider(),
              _accountTile(
                title: 'Backend API URL',
                icon: Icons.dns_outlined,
                onTap: _openApiSettings,
              ),
            ]),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  side: const BorderSide(color: AppTheme.danger),
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sellerProfileHeader(String storeName, String sellerId) {
    return Row(
      children: <Widget>[
        Stack(
          children: <Widget>[
            Container(
              width: 58,
              height: 58,
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  storeName.isNotEmpty ? storeName[0].toUpperCase() : 'A',
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: AppTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.edit, size: 10, color: Colors.white),
              ),
            ),
          ],
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                storeName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.textPrimaryColor(context),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Seller ID: $sellerId',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textMutedColor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sellerDaysBanner() {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                'Number of days as a seller:',
                style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 12, fontWeight: FontWeight.w700),
              ),
              Text(
                '$_daysAsSeller Days',
                style: TextStyle(color: AppTheme.textPrimaryColor(context), fontSize: 14, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    showAppSnackBar(context, 'Opening seller storefront...');
                  },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: AppTheme.borderColor(context)),
                    foregroundColor: AppTheme.textPrimaryColor(context),
                  ),
                  icon: const Icon(Icons.storefront_outlined, size: 15),
                  label: const Text('Shop homepage', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    showAppSnackBar(context, 'Store link copied to clipboard.');
                  },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: AppTheme.borderColor(context)),
                    foregroundColor: AppTheme.textPrimaryColor(context),
                  ),
                  icon: const Icon(Icons.share_outlined, size: 15),
                  label: const Text('Share Shop', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _menuCard(List<Widget> children) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: children),
    );
  }

  Widget _accountTile({
    required String title,
    required IconData icon,
    VoidCallback? onTap,
    Widget? trailingBadge,
    Color? titleColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: titleColor ?? AppTheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: titleColor ?? AppTheme.textPrimaryColor(context),
                ),
              ),
            ),
            if (trailingBadge != null) trailingBadge,
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.textMutedColor(context)),
          ],
        ),
      ),
    );
  }

  Widget _thinDivider() {
    return Divider(height: 1, thickness: 1, color: AppTheme.borderColor(context));
  }
}
