import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_config.dart';
import '../services/session_manager.dart';
import '../widgets/api_base_url_sheet.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '-';
  bool _loadingVersion = true;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${info.version} (${info.buildNumber})');
    } catch (_) {
      if (mounted) setState(() => _version = 'dev');
    } finally {
      if (mounted) setState(() => _loadingVersion = false);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Your secure session token will be removed from the device.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) await widget.sessionManager.logout();
  }

  Future<void> _openApiSettings() async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const ApiBaseUrlSheet(),
    );

    if (updated == true && mounted) {
      setState(() {});
      showAppSnackBar(context, 'Backend URL updated successfully.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SectionHeader(
              title: 'Settings',
              subtitle: 'Account and backend configuration',
            ),
            const SizedBox(height: 16),
            _profileCard(),
            const SizedBox(height: 16),
            _sectionLabel('Account'),
            const SizedBox(height: 8),
            AppCard(
              padding: const EdgeInsets.all(0),
              child: Column(
                children: <Widget>[
                  _settingsTile(Icons.person_outline, 'Signed in as', widget.sessionManager.username, trailing: null),
                  _thinDivider(),
                  _settingsTile(
                    Icons.schedule_outlined,
                    'Session expires',
                    widget.sessionManager.expiresAt?.toLocal().toString() ?? 'Server-controlled token',
                    trailing: const StatusChip(label: 'Active', color: AppTheme.success, softColor: AppTheme.successSoft),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _sectionLabel('Backend / Environment'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _settingsTile(
                    Icons.dns_outlined,
                    'API base URL',
                    AppConfig.apiBaseUrl,
                    trailing: const StatusChip(label: 'Online', color: AppTheme.success, softColor: AppTheme.successSoft),
                  ),
                  _thinDivider(),
                  InkWell(
                    onTap: _openApiSettings,
                    borderRadius: BorderRadius.circular(18),
                    child: _settingsTile(Icons.edit_outlined, 'Change Backend URL', 'Switch between production, staging, or local API', trailing: const Icon(Icons.chevron_right_rounded)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _sectionLabel('About'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: _settingsTile(
                Icons.info_outline,
                'App version',
                _loadingVersion ? 'Loading...' : _version,
                trailing: const Text('Up to date', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  side: const BorderSide(color: AppTheme.border),
                  backgroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.logout_rounded, size: 17),
                label: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
            const SizedBox(height: 12),
            const Center(
              child: Text(
                '© Daraz Control · Inventory and product import are managed from the Inventory screen.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10, fontWeight: FontWeight.w700, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileCard() {
    final username = widget.sessionManager.username.isEmpty ? 'Admin' : widget.sessionManager.username;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(18),
        boxShadow: <BoxShadow>[BoxShadow(color: AppTheme.primary.withOpacity(0.14), blurRadius: 16, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: <Widget>[
          const CircleAvatar(
            radius: 24,
            backgroundColor: Colors.white24,
            child: Text('AR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)),
                const SizedBox(height: 3),
                Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 11)),
              ],
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 12), minimumSize: const Size(0, 34), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: _logout,
            child: const Text('Seller', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }

  Widget _settingsTile(IconData icon, String label, String value, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.all(13),
      child: Row(
        children: <Widget>[
          MiniIcon(icon: icon, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: AppTheme.textPrimary));
  }

  Widget _thinDivider() {
    return const Divider(height: 1, thickness: 1, indent: 58, color: AppTheme.border);
  }
}
