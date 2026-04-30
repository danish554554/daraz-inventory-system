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
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _version = 'dev');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingVersion = false);
      }
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

    if (confirmed == true) {
      await widget.sessionManager.logout();
    }
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
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          children: <Widget>[
            const SectionHeader(
              title: 'Settings',
              subtitle: 'Manage your login session and backend connection.',
            ),
            const SizedBox(height: 18),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  _settingRow('Signed in as', widget.sessionManager.username),
                  const SizedBox(height: 10),
                  _settingRow('Session expires', widget.sessionManager.expiresAt?.toLocal().toString() ?? 'Server-controlled token'),
                  const SizedBox(height: 16),
                  PrimaryButton(label: 'Sign Out', onPressed: _logout, icon: Icons.logout_rounded, expanded: true),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Backend / Environment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  _settingRow('API base URL', AppConfig.apiBaseUrl),
                  const SizedBox(height: 10),
                  SecondaryButton(
                    label: 'Change Backend URL',
                    onPressed: _openApiSettings,
                    icon: Icons.edit_location_alt_outlined,
                  ),
                  const SizedBox(height: 10),
                  _settingRow('App build/version', _loadingVersion ? 'Loading...' : _version),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('App Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  SizedBox(height: 14),
                  Text(
                    'Use this page to manage your login session and backend connection.',
                    style: TextStyle(color: AppTheme.textMuted, height: 1.45),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Daraz store connection is managed from the Stores screen.',
                    style: TextStyle(color: AppTheme.textMuted, height: 1.45),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Inventory and product import are managed from the Inventory screen.',
                    style: TextStyle(color: AppTheme.textMuted, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: const TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
