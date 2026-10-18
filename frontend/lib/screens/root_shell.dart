import 'package:flutter/material.dart';
import '../models/elder.dart';
import '../theme/app_theme.dart';
import 'home_dashboard_screen.dart';
import 'analytics_screen.dart';
import 'elder_details_screen.dart';

/// Owns the bottom navigation for a single selected elder's context.
/// Reached from ElderDetailsScreen's "Open dashboard" button.
///
/// RECOVERY NOTE: this file's real content had been accidentally
/// overwritten on disk with a duplicate copy of HomeDashboardScreen
/// (pasted into the wrong tab), which left no `RootShell` class
/// defined at all and broke every screen that imports it
/// (LoginScreen, SplashScreen, AddEditElderScreen, ElderDetailsScreen).
/// This restores the real RootShell implementation.
///
/// UPDATE (caregiver request): "Fall Detection" tab removed — Fall
/// Detection status is still visible on Home's own summary card, and
/// FallDetectionScreen itself is untouched (still reachable from that
/// card), just no longer a top-level tab. 3 tabs now: Home | Analytics
/// | Elder Profile.
class RootShell extends StatefulWidget {
  final Elder elder;
  const RootShell({super.key, required this.elder});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  late final List<Widget> _pages = [
    HomeDashboardScreen(elder: widget.elder),
    AnalyticsScreen(elder: widget.elder),
    ElderDetailsScreen(elder: widget.elder),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textSecondary,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home_rounded),
            label: "Home",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart_outlined),
            activeIcon: Icon(Icons.bar_chart_rounded),
            label: "Analytics",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person_rounded),
            label: "Elder Profile",
          ),
        ],
      ),
    );
  }
}
