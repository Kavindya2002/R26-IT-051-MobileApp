import 'package:flutter/material.dart';
import 'elder_details_readonly_screen.dart';
import 'emergency_alerts_feed_screen.dart';
import 'profile_screen.dart';

/// Emergency Person's bottom navigation — deliberately different tabs
/// from the Caregiver's Home/History/Account (see conversation notes
/// on least-privilege role design): Elder Details / Alerts / Account.
class EmergencyRootShell extends StatefulWidget {
  final Map<String, dynamic> elder;
  const EmergencyRootShell({super.key, required this.elder});

  @override
  State<EmergencyRootShell> createState() => _EmergencyRootShellState();
}

class _EmergencyRootShellState extends State<EmergencyRootShell> {
  int _index = 1; // land on "Alerts" by default — the most relevant tab

  @override
  Widget build(BuildContext context) {
    final pages = [
      ElderDetailsReadOnlyScreen(elder: widget.elder),
      EmergencyAlertsFeedScreen(elder: widget.elder),
      const ProfileScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: "Elder Details"),
          BottomNavigationBarItem(
              icon: Icon(Icons.shield_outlined),
              activeIcon: Icon(Icons.shield),
              label: "Alerts"),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.account_circle),
              label: "Account"),
        ],
      ),
    );
  }
}
