import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
      if (mounted) setState(() => _version = 'v1.1');
    } finally {
      if (mounted) setState(() => _loadingVersion = false);
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SectionHeader(
              title: 'Account',
              subtitle: 'Seller profile, theme appearance, and backend configuration',
            ),
            const SizedBox(height: 16),
            _profileCard(),
            const SizedBox(height: 16),
            _sectionLabel('Appearance'),
            const SizedBox(height: 8),
            _appearanceCard(context),
            const SizedBox(height: 16),
            _sectionLabel('Account & Session'),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _settingsTile(Icons.person_outline, 'Signed in as', widget.sessionManager.username, trailing: null),
                  _thinDivider(),
                  _settingsTile(
                    Icons.schedule_outlined,
                    'Session status',
                    widget.sessionManager.expiresAt != null
                        ? 'Expires: ${widget.sessionManager.expiresAt!.toLocal()}'
                        : 'Active secure session',
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
                    trailing: const StatusChip(label: 'Connected', color: AppTheme.success, softColor: AppTheme.successSoft),
                  ),
                  _thinDivider(),
                  InkWell(
                    onTap: _openApiSettings,
                    borderRadius: BorderRadius.circular(18),
                    child: _settingsTile(
                      Icons.edit_outlined,
                      'Change Backend URL',
                      'Switch between production, local server, or custom URL',
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
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
                trailing: Text(
                  'Up to date',
                  style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  side: BorderSide(color: AppTheme.borderColor(context)),
                  backgroundColor: AppTheme.cardColor(context),
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.logout_rounded, size: 17),
                label: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'Daraz Inventory & Profit Command Center · Multi-Store Control',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMutedColor(context), fontSize: 10, fontWeight: FontWeight.w700, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileCard() {
    final username = widget.sessionManager.username.isNotEmpty ? widget.sessionManager.username : 'Seller Admin';
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: AppTheme.heroGradient,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                username[0].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: AppTheme.textPrimaryColor(context),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Daraz Inventory Administrator',
                  style: TextStyle(
                    color: AppTheme.textMutedColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const StatusChip(
            label: 'Online',
            color: AppTheme.success,
            softColor: AppTheme.successSoft,
          ),
        ],
      ),
    );
  }

  Widget _appearanceCard(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              MiniIcon(
                icon: widget.sessionManager.themeMode == ThemeMode.dark
                    ? Icons.dark_mode_rounded
                    : widget.sessionManager.themeMode == ThemeMode.light
                        ? Icons.light_mode_rounded
                        : Icons.brightness_auto_rounded,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'App Theme',
                      style: TextStyle(
                        color: AppTheme.textPrimaryColor(context),
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Toggle between dark and light appearance across all screens',
                      style: TextStyle(
                        color: AppTheme.textMutedColor(context),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const <ButtonSegment<ThemeMode>>[
              ButtonSegment<ThemeMode>(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_rounded, size: 16),
                label: Text('System'),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_rounded, size: 16),
                label: Text('Light'),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_rounded, size: 16),
                label: Text('Dark'),
              ),
            ],
            selected: <ThemeMode>{widget.sessionManager.themeMode},
            onSelectionChanged: (Set<ThemeMode> selection) {
              if (selection.isNotEmpty) {
                widget.sessionManager.setThemeMode(selection.first);
                setState(() {});
              }
            },
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: AppTheme.primary,
              selectedForegroundColor: Colors.white,
              backgroundColor: AppTheme.cardColor(context),
              foregroundColor: AppTheme.textPrimaryColor(context),
              textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: AppTheme.textMutedColor(context),
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _settingsTile(IconData icon, String title, String subtitle, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          MiniIcon(icon: icon, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: AppTheme.textPrimaryColor(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppTheme.textMutedColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _thinDivider() {
    return Divider(height: 1, thickness: 1, color: AppTheme.borderColor(context));
  }
}
