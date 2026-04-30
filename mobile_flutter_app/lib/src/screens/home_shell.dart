import 'package:flutter/material.dart';

import '../services/session_manager.dart';
import 'dashboard_screen.dart';
import 'inventory_screen.dart';
import 'settings_screen.dart';
import 'stores_screen.dart';
import 'sync_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  late final List<Widget> _pages = <Widget>[
    DashboardScreen(sessionManager: widget.sessionManager),
    const StoresScreen(),
    const InventoryScreen(),
    const SyncScreen(),
    SettingsScreen(sessionManager: widget.sessionManager),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => setState(() => _currentIndex = index),
            destinations: const <Widget>[
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.storefront_outlined),
                selectedIcon: Icon(Icons.storefront),
                label: 'Stores',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2_rounded),
                label: 'Stock',
              ),
              NavigationDestination(
                icon: Icon(Icons.sync_outlined),
                selectedIcon: Icon(Icons.sync),
                label: 'Sync',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
