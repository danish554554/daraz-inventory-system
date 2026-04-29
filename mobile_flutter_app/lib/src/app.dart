import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/session_manager.dart';
import 'widgets/app_theme.dart';

class DarazInventoryApp extends StatelessWidget {
  const DarazInventoryApp({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: sessionManager,
      builder: (context, _) {
        return MaterialApp(
          title: 'Daraz Inventory Control',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: sessionManager.isBootstrapping
              ? const _BootstrapScreen()
              : sessionManager.isAuthenticated
                  ? HomeShell(sessionManager: sessionManager)
                  : LoginScreen(sessionManager: sessionManager),
        );
      },
    );
  }
}

class _BootstrapScreen extends StatelessWidget {
  const _BootstrapScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
