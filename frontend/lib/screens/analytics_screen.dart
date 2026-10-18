import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/status_widgets.dart';

/// Fall-related metrics are computed client-side from
/// ApiService.getAlertHistory() — the same endpoint AlertsScreen
/// uses. Environment/Health metrics come from the real
/// GET /elders/{elder_id}/events endpoint (backend: app/events/).
///
/// Every section below still derives strictly from `_alerts` /
/// `_events` as fetched by `_load()`. No value is hardcoded or
/// estimated — sections that would otherwise need invented data show
/// an honest empty/unavailable state instead.
///
/// FINAL REMAINING-ISSUES HARDENING FIX (this round):
/// - Alert-type counting now normalizes the backend value (trim,
///   lowercase, underscore→space) before comparing, same concept as
///   the Alerts screen, instead of a brittle exact `==` against
///   "Emergency Alert" — so counts keep working if the backend ever
///   returns snake_case. An unrecognized alert type is never silently
///   folded into one of the three known categories.
/// - Fall Type Distribution now shows humanized labels (e.g. "Forward
///   Fall") instead of the raw backend string, and an
///   unknown/unsupported fall_type is never title-cased into
///   something that looks like a real category — it's simply left out
///   of the distribution rows (it still counts toward Fall Incidents,
///   since the denominator is actualFalls.length, not the sum of
///   classified rows).
/// - Environment/Health events now show a humanized event type (for
///   known event types) or "Event type unavailable", a humanized
///   severity (or "Severity unavailable" — never defaulted to Low),
///   and a real, safely-parsed, readable timestamp (never
///   DateTime.now() standing in for a missing one). Events are sorted
///   newest-first.
/// - Safety Summary no longer claims "Monitoring active" (this is a
///   historical reporting screen, not a live-connectivity check) — it
///   now reads "Analytics period: ...".
/// - 30-day trend buckets show their actual calendar date range (e.g.
///   "Oct 9–15") instead of "Wk 1".."Wk 5", computed dynamically from
///   the real 30-day window — the underlying day-bucketing/count logic
///   is unchanged.
/// - `_load()` now guards against overlapping fetches (e.g. a fast
///   double pull-to-refresh) with a simple in-progress flag.
/// - Removed the old commented-out previous implementations that had
///   accumulated in this file; this is now the only version.
class AnalyticsScreen extends StatefulWidget {
  final Elder elder;
  const AnalyticsScreen({super.key, required this.elder});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

enum _DateRange { today, days7, days30 }

extension on _DateRange {
  String get label => switch (this) {
        _DateRange.today => "Today",
        _DateRange.days7 => "7 Days",
        _DateRange.days30 => "30 Days",
      };

  String get periodContext => switch (this) {
        _DateRange.today => "Today",
        _DateRange.days7 => "Last 7 days",
        _DateRange.days30 => "Last 30 days",
      };
}

// ---------------------------------------------------------------------
// Shared humanization helpers — kept consistent with the same concept
// used on the Alerts / Alert Detail / Fall Detection screens, so an
// alert type, fall type, or severity reads identically everywhere.
// ---------------------------------------------------------------------

const Map<String, String> _alertTypeLabels = {
  "emergency_alert": "Emergency Alert",
  "caregiver_alert": "Caregiver Alert",
  "voice_alert": "Voice Alert",
};

const Set<String> _knownAlertTypeValues = {
  "emergency alert",
  "caregiver alert",
  "voice alert",
};

const Map<String, String> _fallTypeLabels = {
  "no fall": "No Fall",
  "no_fall": "No Fall",
  "fall_forward": "Forward Fall",
  "forward fall": "Forward Fall",
  "fall_backward": "Backward Fall",
  "backward fall": "Backward Fall",
  "fall_side_left": "Side Fall Left",
  "side fall left": "Side Fall Left",
  "fall_side_right": "Side Fall Right",
  "side fall right": "Side Fall Right",
  "fall_slump": "Slump Fall",
  "slump fall": "Slump Fall",
};

const Map<String, String> _eventTypeLabels = {
  "temperature_high": "High Temperature",
  "temperature_low": "Low Temperature",
  "heart_rate_abnormal": "Heart Rate Alert",
  "blood_pressure_abnormal": "Blood Pressure Alert",
  "environment_risk": "Environment Risk",
  "fall_risk_transition": "Fall Risk Change",
};

String _titleCase(String raw) {
  return raw
      .split(RegExp(r'[_\s]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}

// Maps a raw/already-humanized alert type to one of the three known
// canonical labels, or null if it matches none — so an unknown alert
// type is simply not counted as Emergency/Caregiver/Voice, never
// silently folded into one of them.
String? _normalizeAlertType(dynamic raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final key = trimmed.toLowerCase();
  if (_alertTypeLabels.containsKey(key)) return _alertTypeLabels[key];
  final normalized = key.replaceAll('_', ' ');
  if (_knownAlertTypeValues.contains(normalized)) return _titleCase(trimmed);
  return null;
}

// Returns a known fall type label, or null for anything
// unrecognized/missing — the caller decides what to do with null
// (never title-cases an unknown value into something that looks like
// a real fall type).
String? _humanizeFallType(dynamic raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return _fallTypeLabels[trimmed.toLowerCase()];
}

String _humanizeEventType(dynamic raw) {
  if (raw is! String) return "Event type unavailable";
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return "Event type unavailable";
  return _eventTypeLabels[trimmed.toLowerCase()] ?? "Event type unavailable";
}

// Single centralized severity normalization point: the displayed text
// and the displayed color are both derived from this ONE switch, so
// they can never disagree (the previous code normalized the text via
// _humanizeSeverity() but passed the raw, un-trimmed value straight to
// AppColors.severity() for the color — a value like " HIGH" could
// therefore show the correct "High" text next to a neutral/incorrect
// color, or vice versa). An unknown/null/empty/unsupported value
// always gets the neutral "unavailable" presentation — never an
// emergency/high/medium/low color.
(String, Color) _severityPresentation(dynamic raw) {
  final value = raw is String ? raw : "";
  switch (value.trim().toUpperCase()) {
    case "LOW":
      return ("Low", AppColors.safe);
    case "MEDIUM":
      return ("Medium", AppColors.warning);
    case "HIGH":
      return ("High", AppColors.high);
    case "CRITICAL":
      return ("Critical", AppColors.emergency);
    default:
      return ("Severity unavailable", AppColors.textSecondary);
  }
}

// Never throws on a malformed/missing timestamp.
DateTime? _parseTimestamp(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

// "10:45 AM" today, "Yesterday, 6:20 PM", or "Oct 6, 2026, 4:15 PM" for
// anything older — DateTime.now() is used only to classify which of
// these three buckets a REAL parsed timestamp falls into, never as a
// stand-in event time itself.
String _formatEventTime(DateTime? dt) {
  if (dt == null) return "Time unavailable";
  final local = dt.toLocal();
  final now = DateTime.now();
  final diffDays = DateTime(now.year, now.month, now.day)
      .difference(DateTime(local.year, local.month, local.day))
      .inDays;
  if (diffDays == 0) return DateFormat("h:mm a").format(local);
  if (diffDays == 1) return "Yesterday, ${DateFormat("h:mm a").format(local)}";
  return DateFormat("MMM d, yyyy, h:mm a").format(local);
}

// "Oct 9–15" for a range within one month, "Oct 30–Nov 5" across a
// month boundary.
String _formatWeekLabel(DateTime start, DateTime end) {
  final startFmt = DateFormat("MMM d").format(start);
  if (start.month == end.month && start.year == end.year) {
    return "$startFmt–${end.day}";
  }
  return "$startFmt–${DateFormat("MMM d").format(end)}";
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  List<Map<String, dynamic>> _alerts = [];
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  String? _error;
  _DateRange _range = _DateRange.days7;

  // Guards against overlapping/duplicate fetches (e.g. a fast double
  // pull-to-refresh, or refresh triggered while the initial load is
  // still in flight).
  bool _fetchInProgress = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_fetchInProgress) return;
    _fetchInProgress = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // getAlertHistory() defaults to a single page of 20 records, and
      // this screen needs the complete dataset in range, not just the
      // latest page — otherwise "30 Days" stats would be silently
      // based on only the latest 20 alerts even when more existed.
      // Page through the real API (at the backend's own sanctioned max
      // of 100/page — app/alerts/router.py caps `limit` at 100) until
      // a page comes back short, meaning nothing is left to fetch. The
      // 20-page cap (2000 records) is a sanity bound against a runaway
      // loop, not an arbitrary data limit.
      const pageSize = 100;
      final alerts = <Map<String, dynamic>>[];
      for (int page = 0; page < 20; page++) {
        final batch = await ApiService.instance.getAlertHistory(
          widget.elder.id,
          limit: pageSize,
          offset: page * pageSize,
        );
        alerts.addAll(batch);
        if (batch.length < pageSize) break;
      }
      // Events are fetched separately and deliberately not allowed to
      // fail the whole screen — an older backend without this endpoint
      // yet should still show the alert-based metrics that already
      // worked, with the Environment/Health section simply staying
      // empty rather than the entire screen erroring out.
      List<Map<String, dynamic>> events = [];
      try {
        events = await ApiService.instance.getElderEvents(widget.elder.id);
      } catch (e) {
        debugPrint("Events fetch failed (non-fatal, older backend?): $e");
      }
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        _events = events;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
      _fetchInProgress = false;
    }
  }

  // Calendar-based date-range semantics, shared by both the alerts
  // filter below and _buildEventsSection(): Today = today from 00:00
  // to now; 7 Days = today plus the previous 6 calendar days (7 days
  // total); 30 Days = today plus the previous 29 calendar days (30
  // days total). NOT a rolling 7×24h/30×24h duration.
  DateTime _cutoffFor(_DateRange range) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    return switch (range) {
      _DateRange.today => startOfToday,
      _DateRange.days7 => startOfToday.subtract(const Duration(days: 6)),
      _DateRange.days30 => startOfToday.subtract(const Duration(days: 29)),
    };
  }

  List<Map<String, dynamic>> get _filteredByRange {
    final cutoff = _cutoffFor(_range);
    return _alerts.where((a) {
      final dt = DateTime.tryParse(a["created_at"]?.toString() ?? "");
      return dt != null && !dt.isBefore(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Analytics"),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingState(message: "Loading analytics…")
            : _error != null
                ? ErrorStateView(
                    message: "Couldn't load analytics data", onRetry: _load)
                : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final data = _filteredByRange;

    // An elder who has events but has never actually fallen still sees
    // the Environment/Health section instead of a blank screen.
    if (_alerts.isEmpty && _events.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
        children: const [
          EmptyState(
              icon: Icons.bar_chart, message: "No historical data available"),
        ],
      );
    }

    if (_alerts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
        children: [_buildEventsSection()],
      );
    }

    // Real aggregates — every number below is derived from `data`,
    // nothing is a placeholder.
    //
    // "Fall Incidents" counts actual detected falls, not every
    // alert/monitoring record in range (that total also includes e.g.
    // "No Fall, HIGH, Caregiver Alert" pre-fall-warning rows, which are
    // real alerts but not falls). Fall Type Distribution, the trend
    // chart below, and the Safety Summary all share this same
    // actualFalls list so they can never contradict each other.
    final actualFalls = data.where((a) => a["fall_detected"] == true).toList();
    final totalIncidents = actualFalls.length;
    final emergencyCount = data
        .where((a) => _normalizeAlertType(a["alert_type"]) == "Emergency Alert")
        .length;
    final caregiverCount = data
        .where((a) => _normalizeAlertType(a["alert_type"]) == "Caregiver Alert")
        .length;
    final voiceCount = data
        .where((a) => _normalizeAlertType(a["alert_type"]) == "Voice Alert")
        .length;

    // Grouped by HUMANIZED label (so "fall_forward" and "forward fall"
    // merge into one "Forward Fall" row) and excludes No Fall, same as
    // before. An actual fall with a null/unknown/unsupported fall_type
    // is NOT given an invented category — it's simply left out of
    // these rows, while still counting toward Fall Incidents above.
    final Map<String, int> fallTypeCounts = {};
    for (final a in actualFalls) {
      final humanized = _humanizeFallType(a["fall_type"]);
      if (humanized == null || humanized == "No Fall") continue;
      fallTypeCounts[humanized] = (fallTypeCounts[humanized] ?? 0) + 1;
    }
    // Denominator must be ALL actual detected falls (actualFalls.length
    // via totalIncidents), not just the ones with a classified
    // fall_type — otherwise percentages would disagree with the Fall
    // Incidents KPI above.
    final actualFallCount = totalIncidents;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
      children: [
        _buildRangeSelector(),
        const SizedBox(height: AppSpacing.lg),
        if (data.isEmpty)
          const EmptyState(
              icon: Icons.bar_chart,
              message: "No historical data available for this date range")
        else ...[
          // ---- Compact KPI row (Fall Incidents / Emergency Alerts) ----
          Row(
            children: [
              Expanded(
                child: _KpiCard(
                  icon: Icons.personal_injury,
                  iconColor: AppColors.warning,
                  iconBg: AppColors.warningLight,
                  value: "$totalIncidents",
                  label: "Fall Incidents",
                  context_: _range.periodContext,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _KpiCard(
                  icon: Icons.emergency,
                  iconColor: AppColors.emergency,
                  iconBg: AppColors.emergencyLight,
                  value: "$emergencyCount",
                  label: "Emergency Alerts",
                  context_: _range.periodContext,
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.xl),
          // "Fall Activity" means actual detected falls over time, not
          // every alert — actualFalls, not the full alert list, so the
          // trend agrees with the Fall Incidents KPI above.
          _buildTrendSection(actualFalls),

          const SizedBox(height: AppSpacing.xl),
          _buildAlertOverview(voiceCount, caregiverCount, emergencyCount),

          const SizedBox(height: AppSpacing.xl),
          Text("Fall Type Distribution",
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          if (fallTypeCounts.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: EmptyState(
                    icon: Icons.bar_chart,
                    message: "No fall-type data available"),
              ),
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  children: fallTypeCounts.entries.map((e) {
                    final pct = e.value / actualFallCount;
                    return Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  e.key,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text("${e.value}",
                                  style:
                                      Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 6,
                              backgroundColor: AppColors.border,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          const SizedBox(height: AppSpacing.xl),
          _buildSafetySummary(totalIncidents, emergencyCount),
        ],
        const SizedBox(height: AppSpacing.xl),
        _buildEventsSection(),
      ],
    );
  }

  /// Compact pill-style replacement for the default SegmentedButton —
  /// same enum/state/onSelectionChanged behavior, just a tighter,
  /// more professional footprint on small screens.
  Widget _buildRangeSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: _DateRange.values.map((r) {
          final selected = r == _range;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _range = r),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.chip - 4),
                ),
                alignment: Alignment.center,
                child: Text(
                  r.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Real daily/weekly bucket counts for the selected range. A single
  /// calendar day ("Today") can't show a meaningful trend, so that
  /// case is left to the caller to show an empty state instead of a
  /// one-bar "chart". For 30 Days, bucket labels are the bucket's
  /// actual calendar date range (e.g. "Oct 9–15"), computed dynamically
  /// — never hardcoded — from the real 30-day window; the day-bucketing
  /// and counts themselves are unchanged from before.
  Map<String, int> _trendBuckets(List<Map<String, dynamic>> data) {
    const dayAbbr = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    final now = DateTime.now();
    final buckets = <String, int>{};

    if (_range == _DateRange.days7) {
      final days = List.generate(
          7,
          (i) => DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: 6 - i)));
      for (final d in days) {
        buckets[dayAbbr[d.weekday - 1]] = 0;
      }
      for (final a in data) {
        final dt = DateTime.tryParse(a["created_at"]?.toString() ?? "");
        if (dt == null) continue;
        final day = DateTime(dt.year, dt.month, dt.day);
        for (final d in days) {
          if (d == day) {
            buckets[dayAbbr[d.weekday - 1]] =
                (buckets[dayAbbr[d.weekday - 1]] ?? 0) + 1;
          }
        }
      }
    } else if (_range == _DateRange.days30) {
      // Real calendar weeks: weeks 1–4 are genuine 7-day calendar
      // ranges from the start of the 30-day window; week 5 is
      // whatever remains (30 - 28 = 2 days) — a partial final week is
      // expected since 30 doesn't divide evenly by 7, not a bug.
      final windowStart = _cutoffFor(_DateRange.days30);
      final todayStart = DateTime(now.year, now.month, now.day);
      final bucketLabels = List.generate(5, (w) {
        final rangeStart = windowStart.add(Duration(days: w * 7));
        final rawEnd = windowStart.add(Duration(days: w * 7 + 6));
        final rangeEnd = rawEnd.isAfter(todayStart) ? todayStart : rawEnd;
        return _formatWeekLabel(rangeStart, rangeEnd);
      });
      for (final label in bucketLabels) {
        buckets[label] = 0;
      }
      for (final a in data) {
        final dt = DateTime.tryParse(a["created_at"]?.toString() ?? "");
        if (dt == null) continue;
        final day = DateTime(dt.year, dt.month, dt.day);
        if (day.isBefore(windowStart)) continue;
        final daysFromStart = day.difference(windowStart).inDays;
        final weekIndex = (daysFromStart ~/ 7).clamp(0, 4);
        final key = bucketLabels[weekIndex];
        buckets[key] = (buckets[key] ?? 0) + 1;
      }
    }

    return buckets;
  }

  Widget _buildTrendSection(List<Map<String, dynamic>> actualFalls) {
    final sectionTitle = Row(
      children: [
        const Icon(Icons.trending_up, size: 18, color: AppColors.primary),
        const SizedBox(width: 6),
        Text("Fall Activity", style: Theme.of(context).textTheme.titleMedium),
      ],
    );

    if (_range == _DateRange.today) {
      // "No historical trend data available" would be misleading for
      // Today — Today isn't historical data, a single-day trend just
      // isn't a meaningful line/bar chart.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle,
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: EmptyState(
                icon: Icons.show_chart,
                message: actualFalls.isEmpty
                    ? "No fall activity recorded today"
                    : "Trend view is not available for Today",
              ),
            ),
          ),
        ],
      );
    }

    final buckets = _trendBuckets(actualFalls);
    final maxCount = buckets.values.fold<int>(0, (m, v) => v > m ? v : m);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle,
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
            child: SizedBox(
              height: 90,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: buckets.entries.map((e) {
                  final heightFraction =
                      maxCount == 0 ? 0.0 : e.value / maxCount;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            e.value > 0 ? "${e.value}" : "",
                            style: const TextStyle(
                                fontSize: 10, color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            height: 6 + heightFraction * 46,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            e.key,
                            style: const TextStyle(
                                fontSize: 10, color: AppColors.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlertOverview(
      int voiceCount, int caregiverCount, int emergencyCount) {
    final total = voiceCount + caregiverCount + emergencyCount;
    final rows = [
      (
        "Voice Alerts",
        voiceCount,
        Icons.record_voice_over,
        AppColors.secondaryTeal
      ),
      (
        "Caregiver Alerts",
        caregiverCount,
        Icons.support_agent,
        AppColors.warning
      ),
      (
        "Emergency Alerts",
        emergencyCount,
        Icons.emergency,
        AppColors.emergency
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Alert Overview", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.sm, horizontal: AppSpacing.lg),
            child: Column(
              children: rows.map((r) {
                final (label, count, icon, color) = r;
                // total == 0 → 0.0, never divides by zero.
                final pct = total == 0 ? 0.0 : count / total;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(icon, size: 18, color: color),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                              child: Text(label,
                                  style:
                                      Theme.of(context).textTheme.bodyMedium)),
                          Text("$count",
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 6,
                          backgroundColor: AppColors.border,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSafetySummary(int totalIncidents, int emergencyCount) {
    // Purely operational, historical-reporting phrasing derived from
    // real counts already computed above — no medical claims, no
    // fabricated conclusions, and no claim of verified live monitoring
    // connectivity (this screen only reports on past data).
    final periodLine = "Analytics period: ${_range.periodContext}";
    final emergencyLine = emergencyCount == 0
        ? "No emergency alerts recorded in this period"
        : "$emergencyCount emergency alert${emergencyCount == 1 ? '' : 's'} recorded in this period";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Safety Summary", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SafetyLine(color: AppColors.primary, text: periodLine),
                const SizedBox(height: AppSpacing.sm),
                _SafetyLine(
                    color: emergencyCount == 0
                        ? AppColors.safe
                        : AppColors.emergency,
                    text: emergencyLine),
                const SizedBox(height: AppSpacing.sm),
                _SafetyLine(
                  color: AppColors.primary,
                  text:
                      "$totalIncidents total fall incident${totalIncidents == 1 ? '' : 's'} in this period",
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEventsSection() {
    final cutoff = _cutoffFor(_range);

    // Safely parse + filter by range, then sort newest-first — relying
    // on backend/API order was never guaranteed. An event with an
    // invalid/missing timestamp can't be reliably placed in a date
    // range, so (same as before) it's excluded from this filtered
    // list rather than crashing the screen or showing a fabricated
    // date.
    final dated = <MapEntry<Map<String, dynamic>, DateTime>>[];
    for (final e in _events) {
      final dt = _parseTimestamp(e["created_at"]);
      if (dt != null && !dt.isBefore(cutoff)) dated.add(MapEntry(e, dt));
    }
    dated.sort((x, y) => y.value.compareTo(x.value));

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Environment & Health Events",
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          if (dated.isEmpty)
            const EmptyState(
                icon: Icons.sensors_outlined,
                message: "No environment or health events in this period")
          else
            Card(
              child: Column(
                children: dated.map((entry) {
                  final e = entry.key;
                  final isEnv = e["source"] == "component2";
                  final (severityLabel, color) =
                      _severityPresentation(e["severity"]);
                  final rawDetails = e["details"]?.toString().trim();
                  // Real `details` is shown when present and
                  // meaningful; otherwise a humanized event type (never
                  // the raw technical identifier, never fabricated).
                  final title = (rawDetails != null && rawDetails.isNotEmpty)
                      ? rawDetails
                      : _humanizeEventType(e["event_type"]);
                  final timeLabel = _formatEventTime(entry.value);
                  return ListTile(
                    leading: Icon(
                        isEnv
                            ? Icons.location_on_outlined
                            : Icons.monitor_heart_outlined,
                        color: color),
                    title: Text(title,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(timeLabel,
                        style: Theme.of(context).textTheme.bodySmall),
                    trailing: Text(
                      severityLabel,
                      style:
                          TextStyle(color: color, fontWeight: FontWeight.w600),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact KPI card — icon, large number, label, and small period
/// context. Replaces the old oversized 4-up grid for the two primary
/// headline metrics (Fall Incidents, Emergency Alerts).
class _KpiCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String value;
  final String label;
  final String context_;

  const _KpiCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.value,
    required this.label,
    required this.context_,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: iconBg, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(color: iconColor)),
            const SizedBox(height: 2),
            Text(label,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(context_, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _SafetyLine extends StatelessWidget {
  final Color color;
  final String text;
  const _SafetyLine({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    );
  }
}
