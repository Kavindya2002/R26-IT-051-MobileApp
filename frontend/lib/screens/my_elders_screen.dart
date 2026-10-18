import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/status_widgets.dart';
import 'emergency_root_shell.dart';
import 'login_screen.dart';
import 'profile_screen.dart';

/// Entry point for an EMERGENCY_PERSON account — deliberately NOT the
/// same EldersListScreen a Caregiver sees. A Caregiver owns/manages
/// elder profiles (add/edit/delete); an Emergency Person only sees
/// the elders a caregiver has explicitly linked them to, and only to
/// view Emergency Alerts — see conversation notes on least-privilege
/// design for this role.
class MyEldersScreen extends StatefulWidget {
  const MyEldersScreen({super.key});

  @override
  State<MyEldersScreen> createState() => _MyEldersScreenState();
}

class _MyEldersScreenState extends State<MyEldersScreen> {
  List<Map<String, dynamic>> _elders = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final elders = await ApiService.instance.getMyLinkedElders();
      if (!mounted) return;
      setState(() {
        _elders = elders;
        _loading = false;
      });

      // If there's exactly one linked elder, skip straight to their
      // feed — the same "don't make them tap through an unnecessary
      // list" principle used on the Caregiver side.
      if (_elders.length == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => EmergencyRootShell(elder: _elders.first),
            ),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    await ApiService.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Log out"),
        content: const Text("Are you sure you want to log out?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Log out"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AegisAppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Log out",
            onPressed: () => _confirmLogout(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingState()
            : _error != null
                ? ErrorStateView(
                    message: "Couldn't load your elders: $_error",
                    onRetry: _load)
                : _elders.isEmpty
                    ? const EmptyState(
                        icon: Icons.link_off,
                        message:
                            "Not linked to anyone yet\n\nAsk the caregiver to add you as an emergency contact from the elder's profile screen.")
                    : ListView.separated(
                        padding: const EdgeInsets.all(20),
                        itemCount: _elders.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final elder = _elders[index];
                          return Card(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        EmergencyRootShell(elder: elder)),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 24,
                                      backgroundColor: AppColors.medium
                                          .withValues(alpha: 0.15),
                                      child: Text(
                                        (elder["name"] ?? "?")
                                            .toString()
                                            .substring(0, 1)
                                            .toUpperCase(),
                                        style: const TextStyle(
                                            color: AppColors.medium,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(elder["name"] ?? "Unknown",
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          const SizedBox(height: 2),
                                          Text(
                                            "Age ${elder["age"] ?? "-"}",
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right,
                                        color: AppColors.textMuted),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}
