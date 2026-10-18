import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

class HistoryScreen extends StatefulWidget {
  final Elder elder;
  const HistoryScreen({super.key, required this.elder});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _alerts = [];
  bool _loading = true;
  String? _error;
  String _filter = "All";

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final alerts = await ApiService.instance.getAlertHistory(widget.elder.id);
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _dateGroup(DateTime dt) {
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(dt.year, dt.month, dt.day))
        .inDays;
    if (diff == 0) return "Today";
    if (diff == 1) return "Yesterday";
    return DateFormat("MMM d").format(dt);
  }

  Widget _buildBody(List<Map<String, dynamic>> filtered) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 40, color: AppColors.textMuted),
              const SizedBox(height: 12),
              Text("Couldn't load history",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text("Try again")),
            ],
          ),
        ),
      );
    }

    if (filtered.isEmpty) {
      return const _EmptyHistory();
    }

    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final a in filtered) {
      final dt = DateTime.parse(a["created_at"]);
      final label = _dateGroup(dt);
      grouped.putIfAbsent(label, () => []).add(a);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: grouped.entries.expand((entry) {
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child:
                Text(entry.key, style: Theme.of(context).textTheme.titleMedium),
          ),
          ...entry.value.map(
            (a) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _AlertHistoryCard(alert: a),
            ),
          ),
        ];
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter == "All"
        ? _alerts
        : _alerts.where((a) => a["alert_type"] == _filter).toList();

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "History"),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  "All",
                  "Voice Alert",
                  "Caregiver Alert",
                  "Emergency Alert"
                ].map((f) {
                  final selected = _filter == f;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f),
                      selected: selected,
                      onSelected: (_) => setState(() => _filter = f),
                      selectedColor: AppColors.primaryLight,
                      labelStyle: TextStyle(
                          color: selected
                              ? AppColors.primary
                              : AppColors.textSecondary),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Expanded(child: _buildBody(filtered)),
        ],
      ),
    );
  }
}

class _AlertHistoryCard extends StatelessWidget {
  final Map<String, dynamic> alert;
  const _AlertHistoryCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.alertType(alert["alert_type"]);
    final dt = DateTime.parse(alert["created_at"]).toLocal();
    final guidanceCompleted = alert["guidance_completed"] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(Icons.campaign_outlined, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(alert["alert_type"],
                      style:
                          TextStyle(color: color, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    "${alert["fall_type"]} \u00b7 ${alert["location"]}",
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(DateFormat("h:mm a").format(dt),
                    style: Theme.of(context).textTheme.bodyMedium),
                if (guidanceCompleted) ...[
                  const SizedBox(height: 4),
                  const Text("Guidance completed",
                      style: TextStyle(fontSize: 11, color: AppColors.low)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, size: 48, color: AppColors.low),
            const SizedBox(height: 16),
            Text("No alerts yet \u2014 that's good news!",
                style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
