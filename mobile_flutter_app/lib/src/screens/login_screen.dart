import 'package:flutter/material.dart';

import '../services/api_exception.dart';
import '../services/app_config.dart';
import '../services/session_manager.dart';
import '../widgets/api_base_url_sheet.dart';
import '../widgets/app_theme.dart';
import '../widgets/common_widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _rememberMe = true;
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await widget.sessionManager.login(
        username: _usernameController.text,
        password: _passwordController.text,
      );

      if (_rememberMe) {
        await widget.sessionManager.writePreference(
          'saved_login_username',
          _usernameController.text.trim(),
        );
      } else {
        await widget.sessionManager.writePreference('saved_login_username', '');
      }
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Login failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.sessionManager.readPreference('saved_login_username').then((value) {
      if (!mounted) return;
      if (value != null && value.isNotEmpty) {
        _usernameController.text = value;
      }
    });
  }



  Future<void> _openServerSettings() async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const ApiBaseUrlSheet(),
    );

    if (updated == true && mounted) {
      showAppSnackBar(context, 'Backend URL updated. Sign in again using the new server address.');
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                children: <Widget>[
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.primary,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Icon(Icons.inventory_2_outlined, color: Colors.white),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'Daraz Inventory Control',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Internal stock management',
                                    style: TextStyle(
                                      color: AppTheme.textMuted,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'Admin Login',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.9,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Sign in to your operations dashboard',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 24),
                        AppTextField(
                          controller: _usernameController,
                          labelText: 'Email / Username',
                          hintText: 'admin@company.com',
                          prefixIcon: Icons.mail_outline,
                        ),
                        const SizedBox(height: 14),
                        AppTextField(
                          controller: _passwordController,
                          labelText: 'Password',
                          hintText: '••••••••',
                          obscureText: _obscure,
                          prefixIcon: Icons.lock_outline,
                          suffix: IconButton(
                            onPressed: () => setState(() => _obscure = !_obscure),
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            Checkbox(
                              value: _rememberMe,
                              activeColor: AppTheme.primary,
                              onChanged: (value) {
                                setState(() => _rememberMe = value ?? true);
                              },
                            ),
                            const Text(
                              'Remember me',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        if (_error != null) ...<Widget>[
                          const SizedBox(height: 6),
                          InfoBanner(
                            text: _error!,
                            background: AppTheme.dangerSoft,
                            foreground: AppTheme.danger,
                            icon: Icons.error_outline,
                          ),
                        ],
                        const SizedBox(height: 16),
                        PrimaryButton(
                          label: 'Sign In',
                          icon: Icons.login_rounded,
                          expanded: true,
                          loading: _loading,
                          onPressed: _submit,
                        ),
                        const SizedBox(height: 18),
                        const Center(
                          child: Text(
                            'Manual admin access only. Credentials are validated by the existing Node.js backend.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Column(
                            children: <Widget>[
                              Text(
                                'Backend: ${AppConfig.apiBaseUrl}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextButton.icon(
                                onPressed: _loading ? null : _openServerSettings,
                                icon: const Icon(Icons.settings_ethernet_outlined),
                                label: const Text('Change backend URL'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'SSL • Secured Login',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
