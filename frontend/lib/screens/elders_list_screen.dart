import 'package:flutter/material.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import 'add_edit_elder_screen.dart';
import 'elder_details_screen.dart';
import 'profile_screen.dart';

class EldersListScreen extends StatefulWidget {
  const EldersListScreen({super.key});

  @override
  State<EldersListScreen> createState() => _EldersListScreenState();
}

class _EldersListScreenState extends State<EldersListScreen> {
  List<Elder> _elders = [];
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
      final raw = await ApiService.instance.listElders();
      final elders =
          raw.map((e) => Elder.fromJson(Map<String, dynamic>.from(e))).toList();
      if (!mounted) return;
      setState(() {
        _elders = elders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  IconData _deviceIcon(String device) {
    switch (device.toLowerCase()) {
      case "walker":
        return Icons.accessible;
      case "cane":
        return Icons.hiking;
      case "wheelchair":
        return Icons.accessible_forward;
      default:
        return Icons.check_circle_outline;
    }
  }

  Color _fallsColor(int falls) {
    if (falls >= 3) return AppColors.high;
    if (falls >= 1) return AppColors.medium;
    return AppColors.textMuted;
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
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorState(message: _error!, onRetry: _load)
                : _elders.isEmpty
                    ? _EmptyState(onAdd: _goToAdd)
                    : ListView.separated(
                        padding: const EdgeInsets.all(20),
                        itemCount: _elders.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final elder = _elders[index];
                          return Card(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          ElderDetailsScreen(elder: elder)),
                                );
                                _load();
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 26,
                                      backgroundColor: AppColors.primaryLight,
                                      child: Text(
                                        elder.name.isNotEmpty
                                            ? elder.name[0].toUpperCase()
                                            : "?",
                                        style: const TextStyle(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 20,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(elder.name,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Text("Age ${elder.age}",
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium),
                                              const SizedBox(width: 10),
                                              Icon(
                                                  _deviceIcon(
                                                      elder.assistiveDevice),
                                                  size: 16,
                                                  color:
                                                      AppColors.textSecondary),
                                              const SizedBox(width: 4),
                                              Text(elder.assistiveDevice,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: _fallsColor(elder.previousFalls)
                                            .withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        "${elder.previousFalls} falls",
                                        style: TextStyle(
                                          color:
                                              _fallsColor(elder.previousFalls),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
      ),
      floatingActionButton: _elders.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _goToAdd,
              label: const Text("Add elder"),
              icon: const Icon(Icons.add),
            )
          : null,
    );
  }

  Future<void> _goToAdd() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AddEditElderScreen()),
    );
    _load();
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                  color: AppColors.primaryLight, shape: BoxShape.circle),
              child: const Icon(Icons.favorite_border,
                  color: AppColors.primary, size: 36),
            ),
            const SizedBox(height: 20),
            Text("No elders yet",
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              "Add the person you're caring for to start monitoring their safety.",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text("Add your first elder"),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 16),
            Text("Couldn't load your elders",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: onRetry, child: const Text("Try again")),
          ],
        ),
      ),
    );
  }
}
