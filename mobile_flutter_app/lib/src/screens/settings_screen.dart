import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      showAppSnackBar(context, 'Could not open $url', error: true);
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
              subtitle: 'Session, environment, and app details for the mobile client.',
            ),
            const SizedBox(height: 16),
            const InfoBanner(
              text: 'This Flutter app keeps the original server logic intact. Orders, sync scheduling, inventory deductions, and audit records still live on your existing Node.js backend.',
              background: AppTheme.infoSoft,
              foreground: AppTheme.info,
              icon: Icons.info_outline,
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
                  const Text('Environment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  _settingRow('API base URL', AppConfig.apiBaseUrl),
                  const SizedBox(height: 10),
                  SecondaryButton(
                    label: 'Change Backend URL',
                    onPressed: _openApiSettings,
                    icon: Icons.edit_location_alt_outlined,
                  ),
                  const SizedBox(height: 10),
                  _settingRow('App build', _loadingVersion ? 'Loading...' : _version),
                  const SizedBox(height: 10),
                  _settingRow('Mode', 'Material 3 mobile client'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Quick Links', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  SecondaryButton(
                    label: 'Open Backend Base URL',
                    onPressed: () => _openUrl(AppConfig.apiBaseUrl.replaceFirst('/api', '')),
                    icon: Icons.open_in_browser,
                  ),
                  const SizedBox(height: 12),
                  SecondaryButton(
                    label: 'Open Flutter Documentation',
                    onPressed: () => _openUrl('https://docs.flutter.dev/'),
                    icon: Icons.menu_book_outlined,
                  ),
                  const SizedBox(height: 12),
                  SecondaryButton(
                    label: 'Open Pub.dev Packages',
                    onPressed: () => _openUrl('https://pub.dev/'),
                    icon: Icons.extension_outlined,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Notes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  SizedBox(height: 14),
                  Text(
                    'Connect Daraz from the Stores screen. The app now starts the backend OAuth flow and returns straight back into the mobile app after seller authorization.',
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
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}
