import 'package:flutter/material.dart';

import '../services/session_manager.dart';
import '../widgets/app_theme.dart';
import 'account_screen.dart';
import 'dashboard_screen.dart';
import 'finance_screen.dart';
import 'inventory_screen.dart';
import 'stores_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.sessionManager});

  final SessionManager sessionManager;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;
  final Set<int> _visitedIndices = <int>{0};

  late final List<Widget> _pages = <Widget>[
    DashboardScreen(sessionManager: widget.sessionManager),
    const StoresScreen(),
    const InventoryScreen(),
    const FinanceScreen(),
    AccountScreen(
      sessionManager: widget.sessionManager,
      onNavigateToTab: (tabIndex) {
        setState(() {
          _visitedIndices.add(tabIndex);
          _currentIndex = tabIndex;
        });
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    _visitedIndices.add(_currentIndex);
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: List<Widget>.generate(_pages.length, (index) {
          if (!_visitedIndices.contains(index)) {
            return const SizedBox.shrink();
          }
          return _pages[index];
        }),
      ),
      bottomNavigationBar: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        decoration: BoxDecoration(
          color: AppTheme.cardColor(context),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AppTheme.borderColor(context)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppTheme.isDark(context)
                  ? Colors.black.withValues(alpha: 0.4)
                  : Colors.black.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => setState(() => _currentIndex = index),
            destinations: const <Widget>[
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.store_mall_directory_outlined),
                selectedIcon: Icon(Icons.store_mall_directory_rounded),
                label: 'Stores',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2_rounded),
                label: 'Stock',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: Icon(Icons.account_balance_wallet_rounded),
                label: 'Finance',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Account',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

