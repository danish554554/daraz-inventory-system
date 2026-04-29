import 'package:flutter/material.dart';

import '../services/app_config.dart';
import 'app_theme.dart';
import 'common_widgets.dart';

class ApiBaseUrlSheet extends StatefulWidget {
  const ApiBaseUrlSheet({super.key});

  @override
  State<ApiBaseUrlSheet> createState() => _ApiBaseUrlSheetState();
}

class _ApiBaseUrlSheetState extends State<ApiBaseUrlSheet> {
  late final TextEditingController _controller;
  bool _working = false;
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: AppConfig.apiBaseUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _working = true;
      _status = null;
      _statusIsError = false;
    });

    final message = await AppConfig.testApiBaseUrl(_controller.text);
    if (!mounted) return;

    setState(() {
      _working = false;
      _status = message ?? 'Connection successful.';
      _statusIsError = message != null;
    });
  }

  Future<void> _save() async {
    setState(() {
      _working = true;
      _status = null;
      _statusIsError = false;
    });

    final message = await AppConfig.testApiBaseUrl(_controller.text);
    if (message != null) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _status = message;
        _statusIsError = true;
      });
      return;
    }

    await AppConfig.updateApiBaseUrl(_controller.text);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _reset() async {
    await AppConfig.resetApiBaseUrl();
    if (!mounted) return;
    _controller.text = AppConfig.defaultApiBaseUrl;
    setState(() {
      _status = 'Reset to the default build URL.';
      _statusIsError = false;
    });
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
              title: 'Backend URL',
              subtitle: 'Use your computer LAN IP on a real phone. Example: 192.168.1.10:5000/api',
              action: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _controller,
              labelText: 'API base URL',
              hintText: AppConfig.defaultApiBaseUrl,
              keyboardType: TextInputType.url,
              prefixIcon: Icons.link,
            ),
            const SizedBox(height: 12),
            const Text(
              'Android emulator: 10.0.2.2 • iOS simulator: 127.0.0.1 • Real phone: your computer IP',
              style: TextStyle(color: AppTheme.textMuted, height: 1.4),
            ),
            if (_status != null) ...<Widget>[
              const SizedBox(height: 14),
              InfoBanner(
                text: _status!,
                background: _statusIsError ? AppTheme.dangerSoft : AppTheme.successSoft,
                foreground: _statusIsError ? AppTheme.danger : AppTheme.success,
                icon: _statusIsError ? Icons.error_outline : Icons.check_circle_outline,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                Expanded(
                  child: SecondaryButton(
                    label: 'Test',
                    onPressed: _working ? null : _test,
                    icon: Icons.wifi_tethering,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryButton(
                    label: 'Save',
                    onPressed: _working ? null : _save,
                    icon: Icons.save_outlined,
                    loading: _working,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _working ? null : _reset,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset to default'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
