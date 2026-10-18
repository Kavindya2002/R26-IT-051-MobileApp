import 'dart:async';
import 'package:flutter/material.dart';
import '../config.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/status_widgets.dart';

/// Environment screen — Zones-only list.
///
/// REMOVED (Buzzer Removal prompt): the Buzzer switch, its loading
/// spinner, its SnackBars, its "turn off mid-Emergency-Alert?"
/// confirmation dialog, `_sending`, `_toggleBuzzer()`, and the
/// `AlertState` import that dialog needed — all of it was ONLY used by
/// this screen's Buzzer control, confirmed by searching the rest of
/// the app for any other reference before removing it. The backend
/// `ApiService.setBuzzer()` method itself is left in place (it may
/// still be wanted for hardware testing or a future screen) — only
/// this screen's UI for it is gone. Removing it does not touch
/// Component 1/3/4, Voice/Caregiver/Emergency alerts, alert history, or
/// the WebSocket alert stream — none of that code lived here.
///
/// The real zone-data fetching, periodic polling, pull-to-refresh, and
/// risk-based sorting are preserved exactly from the original; only the
/// presentation layer and the sort's offline-safety rule (see `_fetch`)
/// changed.
class EnvironmentScreen extends StatefulWidget {
  const EnvironmentScreen({super.key});

  @override
  State<EnvironmentScreen> createState() => _EnvironmentScreenState();
}

class _EnvironmentScreenState extends State<EnvironmentScreen> {
  Timer? _timer;
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  String? _error;

  static const _riskOrder = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3};

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(AppConfig.pollInterval, (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final devices = await ApiService.instance.getEnvironmentDevices();
      final list = devices.map((d) => Map<String, dynamic>.from(d)).toList();
      list.sort((a, b) {
        // FIX: a device's stored risk_level is only a LIVE reading while
        // it's actually online — an offline/unknown zone must never
        // outrank (or be sorted alongside by risk) a genuinely online
        // zone just because its last-known risk_level happened to be
        // high. Online zones are always sorted first, by real risk;
        // offline/unknown zones follow, in whatever order they came in.
        final onlineA =
            (a["device_status"]?.toString().toLowerCase()) == "online";
        final onlineB =
            (b["device_status"]?.toString().toLowerCase()) == "online";
        if (onlineA != onlineB) return onlineA ? -1 : 1;
        if (!onlineA) return 0;
        final ra =
            _riskOrder[(a["risk_level"] ?? "").toString().toUpperCase()] ?? 9;
        final rb =
            _riskOrder[(b["risk_level"] ?? "").toString().toUpperCase()] ?? 9;
        return ra.compareTo(rb);
      });

      if (!mounted) return;
      setState(() {
        _devices = list;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Environment"),
      body: _loading
          ? const LoadingState()
          : _error != null
              ? ErrorStateView(
                  message: "Unable to load environment data", onRetry: _fetch)
              : RefreshIndicator(
                  onRefresh: _fetch,
                  child: _devices.isEmpty
                      ? ListView(
                          // Kept as a ListView (not a bare centered
                          // widget) so pull-to-refresh still works on
                          // an empty list instead of only on a
                          // populated one.
                          padding: const EdgeInsets.only(top: AppSpacing.xxxl),
                          children: const [
                            EmptyState(
                              icon: Icons.sensors_off,
                              message:
                                  "No environmental sensors found\n\nEnvironmental monitoring zones will appear here when available.",
                            ),
                          ],
                        )
                      // RESPONSIVE (UI redesign): on a wide viewport (web /
                      // tablet landscape) the card list is centered and
                      // capped at a readable column width instead of
                      // stretching edge-to-edge; on a normal phone width
                      // this LayoutBuilder is a no-op (maxWidth already
                      // fits). No data/fetch logic lives in this
                      // LayoutBuilder — purely a width constraint.
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final contentWidth = constraints.maxWidth > 640
                                ? 640.0
                                : constraints.maxWidth;
                            return Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: contentWidth,
                                child: ListView.separated(
                                  padding:
                                      const EdgeInsets.all(AppSpacing.xl),
                                  itemCount: _devices.length + 1,
                                  separatorBuilder: (_, i) => SizedBox(
                                      height: i == 0
                                          ? AppSpacing.lg
                                          : AppSpacing.md),
                                  itemBuilder: (context, i) {
                                    if (i == 0) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text("Environmental Monitoring",
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          const SizedBox(height: 2),
                                          Text(
                                            "Monitor environmental conditions around the elder.",
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      );
                                    }
                                    return _ZoneCard(
                                      device: _devices[i - 1],
                                      // Wires the card's refresh button to
                                      // this same, real _fetch() — the
                                      // exact method pull-to-refresh above
                                      // already uses. No new/duplicate
                                      // fetch logic.
                                      onRefresh: _fetch,
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}

/// Real, tri-state sensor connectivity — distinct from the environmental
/// RISK reading below it. "unknown" is a genuine state (device_status
/// missing from the payload), not an error.
enum _SensorStatus { online, offline, unknown }

class _ZoneCard extends StatelessWidget {
  final Map<String, dynamic> device;
  final VoidCallback? onRefresh;
  const _ZoneCard({required this.device, this.onRefresh});

  _SensorStatus get _status {
    final raw = device["device_status"]?.toString().toLowerCase();
    if (raw == null) return _SensorStatus.unknown;
    return raw == "online" ? _SensorStatus.online : _SensorStatus.offline;
  }

  // Display-only humanization — never changes the real backend value
  // (the raw `location` string is still what's sent anywhere this
  // value might be used elsewhere; this only affects what's drawn).
  static const Map<String, String> _knownLocationLabels = {
    "stair_case": "Staircase",
    "staircase": "Staircase",
    "living_room": "Living Room",
    "bedroom": "Bedroom",
    "bed_room": "Bedroom",
    "bath_room": "Bathroom",
    "bathroom": "Bathroom",
    "kitchen": "Kitchen",
    "hallway": "Hallway",
    "dining_room": "Dining Room",
  };

  String _titleCase(String raw) {
    return raw
        .split(RegExp(r'[_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  String _humanizeLocation(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Zone";
    final key = raw.trim().toLowerCase();
    return _knownLocationLabels[key] ?? _titleCase(raw);
  }

  // Real backend risk_level -> a readable label. Only ever called when
  // the sensor is actually online (see build() below) — an
  // offline/unknown zone's stored risk_level is never shown as current.
  String _riskLabel(String? level) {
    switch ((level ?? "").toUpperCase()) {
      case "LOW":
        return "Low";
      case "MEDIUM":
        return "Warning";
      case "HIGH":
        return "High Risk";
      case "CRITICAL":
        return "Critical";
      default:
        return "Unknown";
    }
  }

  // Short form of the same real risk_level, used only to word the
  // warning banner below ("High environmental risk detected" /
  // "Critical environmental risk detected"). Derived from the same
  // backend field as _riskLabel — never a separate/hardcoded value.
  String _riskWarningWord(String? level) {
    switch ((level ?? "").toUpperCase()) {
      case "HIGH":
        return "High";
      case "CRITICAL":
        return "Critical";
      default:
        return "";
    }
  }

  String _sensorStatusLabel(_SensorStatus status) {
    switch (status) {
      case _SensorStatus.online:
        return "Sensor Online";
      case _SensorStatus.offline:
        return "Sensor Offline";
      case _SensorStatus.unknown:
        return "Sensor Status Unavailable";
    }
  }

  Color _sensorStatusColor(_SensorStatus status) {
    switch (status) {
      case _SensorStatus.online:
        return AppColors.safe;
      case _SensorStatus.offline:
        return AppColors.warning;
      case _SensorStatus.unknown:
        return AppColors.textSecondary;
    }
  }

  String _connectivityBadgeLabel(_SensorStatus status) {
    switch (status) {
      case _SensorStatus.online:
        return "ONLINE";
      case _SensorStatus.offline:
        return "OFFLINE";
      case _SensorStatus.unknown:
        return "UNKNOWN";
    }
  }

  // No invented units: "cm" for distance is the unit the original
  // screen already displayed (an established part of this value's
  // meaning), but light/moisture have never carried a confirmed unit
  // anywhere in this app's backend — so none is added here rather than
  // guessing "lux" / "%".
  String _metricValue(dynamic raw, {String suffix = ""}) {
    if (raw == null) return "No current reading";
    return "$raw$suffix";
  }

  // Motion is a real top-level backend field (device["motion"], a bool),
  // confirmed via app/component2/api/router.py's _serialize(). Handled
  // separately from _metricValue because it's boolean, not numeric —
  // null still means "No current reading", never a fabricated false.
  String _motionValue(dynamic raw) {
    if (raw == null) return "No current reading";
    final bool detected = raw == true || raw == 1 || raw == "1";
    return detected ? "Motion detected" : "No motion detected";
  }

  String _formatClock(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? "AM" : "PM";
    return "$h:$m $ampm";
  }

  // Only ever built from the REAL `updated_time` field — no
  // DateTime.now() fallback when it's missing or fails to parse.
  String _formatUpdatedTime(DateTime? parsed) {
    if (parsed == null) return "Update time unavailable";
    final diff = DateTime.now().difference(parsed);
    if (diff.isNegative || diff.inSeconds < 60) return "Updated just now";
    if (diff.inMinutes < 60) return "Updated ${diff.inMinutes} min ago";
    if (diff.inHours < 24) return "Updated ${diff.inHours} hr ago";
    if (diff.inDays == 1) return "Yesterday, ${_formatClock(parsed)}";
    if (diff.inDays < 7) return "Updated ${diff.inDays} days ago";
    return "Updated ${parsed.day}/${parsed.month}/${parsed.year}";
  }

  bool _isStale(DateTime? parsed) {
    if (parsed == null) return false;
    return DateTime.now().difference(parsed) > AppConfig.pollInterval * 3;
  }

  // UI-redesign only: which icon represents each metric tile. Purely
  // cosmetic — never consulted for any value or logic.
  IconData _metricIcon(String label) {
    switch (label) {
      case "Light":
        return Icons.wb_sunny_outlined;
      case "Moisture":
        return Icons.water_drop_outlined;
      case "Distance":
        return Icons.straighten_outlined;
      case "Motion":
        return Icons.directions_run_rounded;
      default:
        return Icons.sensors;
    }
  }

  Color _metricIconColor(String label) {
    switch (label) {
      case "Light":
        return const Color(0xFFF5A623);
      case "Moisture":
        return const Color(0xFF3B82F6);
      case "Distance":
        return AppColors.safe;
      case "Motion":
        return const Color(0xFF8B5CF6);
      default:
        return AppColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final online = status == _SensorStatus.online;
    final riskLevel = device["risk_level"]?.toString();
    final badgeColor =
        online ? AppColors.severity(riskLevel) : _sensorStatusColor(status);
    final badgeLabel = online
        ? _riskLabel(riskLevel).toUpperCase()
        : _connectivityBadgeLabel(status);

    final updatedParsed =
        DateTime.tryParse(device["updated_time"]?.toString() ?? "");
    final stale = online && _isStale(updatedParsed);

    // Driven entirely by the real, already-computed riskLevel — never
    // hardcoded. Only HIGH/CRITICAL while the sensor is actually online
    // surface the banner (an offline zone's stale risk_level is never
    // treated as a live warning, consistent with the "Unknown" block
    // below for that case).
    final riskWord = _riskWarningWord(riskLevel);
    final showRiskWarning = online && riskWord.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.location_on_outlined,
                      size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _humanizeLocation(device["location"]?.toString()),
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          Icon(Icons.circle,
                              size: 8, color: _sensorStatusColor(status)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _sensorStatusLabel(status),
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  // FIX (flutter analyze info, confirmed against your
                  // actual project's Flutter SDK): withOpacity() is
                  // deprecated there in favor of withValues(alpha:),
                  // which avoids a precision-loss warning. Reverting to
                  // withValues() here, which is what your real
                  // toolchain asked for.
                  decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showRiskWarning) ...[
                        Icon(Icons.warning_amber_rounded,
                            size: 14, color: badgeColor),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        badgeLabel,
                        style: TextStyle(
                            color: badgeColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // FIX: when NOT online, the real risk_level is never shown
            // as a current reading — instead this explicit row always
            // reads "Unknown", because a stale stored value from the
            // last time this sensor was online is not a live risk.
            if (!online) ...[
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.md),
              Text("Environmental Status",
                  style: Theme.of(context).textTheme.bodySmall),
              Text(
                "Unknown",
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ],

            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.md),

            // REMOVED (per request): the Temperature tile. Motion is
            // still a real, currently-sent backend field (confirmed via
            // app/component2/api/router.py's _serialize()) — kept
            // alongside Light/Moisture/Distance, same
            // null-safe/no-invented-unit rules as every other metric.
            //
            // UI REDESIGN: each metric is now its own bordered card with
            // an icon, laid out as a responsive 2-column grid
            // (Row + Expanded). The value Text no longer has
            // maxLines/overflow:ellipsis — it wraps instead, so a longer
            // value like "No motion detected" is always shown in full
            // (acceptance criterion: no truncated text) and the card
            // simply grows to fit it rather than clipping.
            //
            // FIX (infinite-height crash): CrossAxisAlignment.stretch was
            // tried here to make both cards in a row match height, but a
            // Row can only stretch its children when ITS OWN height is
            // bounded — and inside this Card's Column (mainAxisSize.max
            // by default) sitting in a scrollable ListView, the Row's
            // height constraint is unbounded, so Flutter throws
            // "BoxConstraints forces an infinite height". Dropping
            // stretch (back to the default crossAxisAlignment) removes
            // that crash; the two cards in a row can differ in height by
            // a few pixels when one value wraps to two lines, which is
            // harmless and still shows the full text.
            Row(
              children: [
                Expanded(
                    child: _metricTile(
                        context, "Light", _metricValue(device["light"]))),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                    child: _metricTile(context, "Moisture",
                        _metricValue(device["moisture"]))),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                    child: _metricTile(context, "Distance",
                        _metricValue(device["distance"], suffix: " cm"))),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                    child: _metricTile(
                        context, "Motion", _motionValue(device["motion"]))),
              ],
            ),

            // UI REDESIGN: an explicit warning banner, worded from the
            // real risk_level (via _riskWarningWord — never a hardcoded
            // string), shown only while the sensor is online and its
            // actual risk is HIGH or CRITICAL. Purely additive to the
            // existing badge; no risk computation happens here.
            if (showRiskWarning) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: badgeColor, size: 20),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "$riskWord environmental risk detected",
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                    color: badgeColor,
                                    fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "Please check the surroundings and ensure safety for the elder.",
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Last updated",
                          style: Theme.of(context).textTheme.bodySmall),
                      Text(_formatUpdatedTime(updatedParsed),
                          style: Theme.of(context).textTheme.bodyMedium),
                      if (stale) ...[
                        const SizedBox(height: 4),
                        Text(
                          "Data may be outdated",
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: AppColors.warning),
                        ),
                      ],
                    ],
                  ),
                ),
                // UI REDESIGN: a visible refresh action, wired to the
                // exact same _fetch() the pull-to-refresh gesture above
                // already calls (passed down as onRefresh) — no new
                // fetch/polling logic, no new endpoint. Only shown when
                // a callback was actually supplied.
                if (onRefresh != null)
                  IconButton(
                    onPressed: onRefresh,
                    tooltip: "Refresh",
                    icon: const Icon(Icons.refresh_rounded,
                        color: AppColors.primary),
                    style: IconButton.styleFrom(
                      backgroundColor:
                          AppColors.primary.withValues(alpha: 0.10),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricTile(BuildContext context, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _metricIconColor(label).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(_metricIcon(label),
                size: 16, color: _metricIconColor(label)),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          // No maxLines/overflow:ellipsis here on purpose — this is the
          // fix for the motion-value truncation bug. Text wraps and the
          // surrounding Container (no fixed height) simply grows.
          Text(
            value,
            softWrap: true,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 16),
          ),
        ],
      ),
    );
  }
}
