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
  void initState() {
    super.initState();
    widget.sessionManager.readPreference('saved_login_username').then((value) {
      if (!mounted) return;
      if (value != null && value.isNotEmpty) {
        _usernameController.text = value;
      }
    });
  }

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
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 30),
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(22),
                        topRight: Radius.circular(22),
                      ),
                    ),
                    child: Stack(
                      children: <Widget>[
                        Positioned(
                          right: -28,
                          top: -42,
                          child: Container(
                            width: 142,
                            height: 142,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: const Icon(Icons.inventory_2_outlined, color: Colors.white, size: 17),
                                ),
                                const SizedBox(width: 9),
                                const Text(
                                  'Daraz Control',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13),
                                ),
                              ],
                            ),
                            const SizedBox(height: 26),
                            const Text(
                              'Welcome back',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.8,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Sign in to manage your stores, inventory and Daraz syncs.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.88),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  AppCard(
                    radius: 0,
                    shadow: false,
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                    borderColor: Colors.transparent,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        AppTextField(
                          controller: _usernameController,
                          labelText: 'Email',
                          hintText: 'admin@karachistore.pk',
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
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: Checkbox(
                                value: _rememberMe,
                                activeColor: AppTheme.primary,
                                onChanged: (value) => setState(() => _rememberMe = value ?? true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Remember this admin account',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        if (_error != null) ...<Widget>[
                          const SizedBox(height: 12),
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
                          icon: Icons.arrow_forward_rounded,
                          expanded: true,
                          loading: _loading,
                          onPressed: _submit,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const <Widget>[
                            Icon(Icons.lock_outline, size: 14, color: AppTheme.textMuted),
                            SizedBox(width: 5),
                            Text(
                              'Secure session — encrypted in transit',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  AppCard(
                    radius: 0,
                    shadow: false,
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                    borderColor: Colors.transparent,
                    child: AppCard(
                      padding: const EdgeInsets.all(13),
                      backgroundColor: AppTheme.background,
                      shadow: false,
                      child: Row(
                        children: <Widget>[
                          const MiniIcon(icon: Icons.dns_outlined, size: 34),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Text('API endpoint', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                                const SizedBox(height: 3),
                                Text(
                                  AppConfig.apiBaseUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: _loading ? null : _openServerSettings,
                            child: const Text('Change', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(22),
                        bottomRight: Radius.circular(22),
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'v2.4.1 · Daraz Inventory Control',
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w700),
                      ),
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
