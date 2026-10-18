import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/alert_state.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/status_widgets.dart';
import 'alert_detail_screen.dart';

// ---------------------------------------------------------------------
// Shared humanization helpers (module-private, used by both
// _AlertsScreenState and the alert cards below). Kept in sync with the
// same mappings used on the Alert Detail screen so an alert reads
// identically everywhere in the app.
// ---------------------------------------------------------------------

const Map<String, String> _alertTypeLabels = {
  "emergency_alert": "Emergency Alert",
  "caregiver_alert": "Caregiver Alert",
  "voice_alert": "Voice Alert",
};

// Normalized (lowercase, underscores→spaces) forms of every alert type
// this screen knows how to display — lets an already-humanized value
// ("Emergency Alert") be recognized as valid without accepting
// arbitrary unknown text.
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

const Map<String, String> _locationLabels = {
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

// Contextual empty-state copy per filter chip. "Emergency Alert" /
// "Voice Alert" / "Caregiver Alert" filter by real alert type exactly
// as before; "High Risk" / "Medium Risk" are NEW filters added in this
// redesign — they filter by the real `risk_level` field the backend
// already returns on every alert record (see _AlertsScreenState.
// _alertMatchesFilter below). Both filter families are additive: every
// filter chip the screen supported before this redesign still works
// exactly as before, nothing was removed to make room for the new
// risk-based chips shown in the reference design.
const Map<String, String> _filterEmptyLabels = {
  "Voice Alert": "No Voice Alerts found",
  "Caregiver Alert": "No Caregiver Alerts found",
  "Emergency Alert": "No Emergency Alerts found",
  "High Risk": "No High Risk alerts found",
  "Medium Risk": "No Medium Risk alerts found",
};

// The filter chip row shown on screen. Order follows the reference
// design (All / Emergency / High Risk / Medium Risk / Voice Alert),
// with the existing "Caregiver Alert" type-filter kept at the end —
// per the redesign brief: "Keep the existing filter options for Voice
// Alert, Caregiver Alert, and Emergency Alert unless the new risk
// filters can be implemented accurately using real backend risk-level
// data." Real risk_level data IS available per alert (the app already
// reads and humanizes it elsewhere), so the two risk filters were
// added rather than used as a reason to drop the type filters.
const List<String> _filterChips = [
  "All",
  "Emergency Alert",
  "High Risk",
  "Medium Risk",
  "Voice Alert",
  "Caregiver Alert",
];

// Short display label for a filter chip (kept distinct from the value
// used for matching/empty-state copy so "Emergency Alert" can read as
// just "Emergency" on the chip itself, matching the reference design,
// without inventing a second, inconsistent value to filter on).
String _chipLabel(String filter) =>
    filter == "Emergency Alert" ? "Emergency" : filter;

String _titleCase(String raw) {
  return raw
      .split(RegExp(r'[_\s]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}

// Only ever returns a known alert type or the honest "Alert type
// unavailable" — never raw snake_case, and never silently reassigns
// an unknown value to one of the three real alert types.
String _humanizeAlertType(String? raw) {
  if (raw == null || raw.trim().isEmpty) return "Alert type unavailable";
  final trimmed = raw.trim();
  final key = trimmed.toLowerCase();
  if (_alertTypeLabels.containsKey(key)) return _alertTypeLabels[key]!;
  final normalized = key.replaceAll('_', ' ');
  if (_knownAlertTypeValues.contains(normalized)) return _titleCase(trimmed);
  return "Alert type unavailable";
}

// Maps a raw/already-humanized alert type to one of the three known
// canonical labels for FILTERING purposes, or null if it matches none
// (so an unknown alert type simply won't match a specific filter chip,
// without crashing or being mis-filed under one by accident).
String? _canonicalAlertType(dynamic raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final key = trimmed.toLowerCase();
  if (_alertTypeLabels.containsKey(key)) return _alertTypeLabels[key];
  final normalized = key.replaceAll('_', ' ');
  if (_knownAlertTypeValues.contains(normalized)) return _titleCase(trimmed);
  return null;
}

// Null (rather than an "unavailable" string) when there's nothing real
// to show — used by the redesigned cards, which omit an optional field
// entirely instead of printing placeholder text for it (per redesign
// brief section 2: "If a field is missing, show a clear unavailable
// state or omit the optional field gracefully" — the card UI reads
// better omitting it than leaving "Fall type unavailable" among tidy
// chips/icons). The alert TYPE itself is never optional like this — it
// always goes through _humanizeAlertType above, which still surfaces
// an explicit "unavailable" message rather than hiding a identity
// field.
String? _humanizeFallTypeOrNull(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return _fallTypeLabels[raw.trim().toLowerCase()];
}

// See _humanizeFallTypeOrNull above — same reasoning, used for the
// risk pill badge on the redesigned cards.
String? _humanizeRiskLevelOrNull(String? raw) {
  switch ((raw ?? "").trim().toUpperCase()) {
    case "LOW":
      return "Low Risk";
    case "MEDIUM":
      return "Medium Risk";
    case "HIGH":
      return "High Risk";
    case "CRITICAL":
      return "Critical Risk";
    default:
      return null;
  }
}

// See _humanizeFallTypeOrNull above — same reasoning, used for the
// bottom icon row on the redesigned cards.
String? _humanizeLocationOrNull(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return _locationLabels[raw.trim().toLowerCase()];
}

// Never throws on a malformed/missing timestamp — returns null instead
// so the caller can show "Time unavailable" / group it as such, rather
// than crashing the whole Alerts screen on one bad record.
DateTime? _parseDate(dynamic raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return DateTime.tryParse(trimmed);
  }
  return null;
}

String _formatTime(DateTime? dt) {
  if (dt == null) return "Time unavailable";
  return DateFormat("h:mm a").format(dt.toLocal());
}

// Exact, normalized classification — NOT substring matching. A
// substring check like `.contains("emergency")` would incorrectly
// classify an unsupported value such as "unknown_emergency_type" as a
// real Emergency Alert; normalizing (trim/lowercase/underscore→space)
// and switching on the exact known strings means only the three real
// alert types this app supports ever get their specific icon —
// anything else safely falls through to a generic one. Shared by the
// Active Alert card and every History card.
IconData _alertIconFor(String? alertType) {
  final normalized =
      (alertType ?? "").trim().toLowerCase().replaceAll("_", " ");
  switch (normalized) {
    case "emergency alert":
      return Icons.emergency;
    case "caregiver alert":
      return Icons.notifications_active;
    case "voice alert":
      return Icons.record_voice_over;
    default:
      return Icons.info_outline;
  }
}

// "Today • 09 Oct 2026" / "Yesterday • 08 Oct 2026" / "02 Oct 2026" —
// matches the reference design's group-header format while keeping
// exactly the same Today/Yesterday day-granularity comparison as
// before (so grouping behavior is unchanged; only the printed label
// gained the explicit calendar date alongside it).
String _dateGroupLabel(DateTime dt) {
  final now = DateTime.now();
  final diff = DateTime(now.year, now.month, now.day)
      .difference(DateTime(dt.year, dt.month, dt.day))
      .inDays;
  final formatted = DateFormat("dd MMM yyyy").format(dt);
  if (diff == 0) return "Today • $formatted";
  if (diff == 1) return "Yesterday • $formatted";
  return formatted;
}

/// Alerts screen — Active Alerts (live AlertState) + Alert History
/// (real ApiService.getAlertHistory() call), with type + risk filters.
///
/// UI REDESIGN PASS (this round) — visual match to the AegisCare
/// Alerts Dashboard reference image, with every rule in the "Preserve
/// Existing Flutter Functionality" section of the redesign brief kept
/// intact:
/// - `AlertsScreen`'s constructor, required `Elder elder` argument,
///   `AlertState` provider read, and `ApiService.getAlertHistory()`
///   call are all unchanged.
/// - Alert type / fall type / risk level / location humanization,
///   newest-first ordering, safe timestamp parsing, duplicate-request
///   protection (`_inFlight`), pull-to-refresh, and the
///   AlertDetailScreen navigation split (live state for the Active
///   Alert card, `historyAlert: alert` for a History card) are all
///   unchanged.
/// - The existing Voice/Caregiver/Emergency alert-type filters still
///   work exactly as before; High Risk/Medium Risk filters were ADDED
///   (using the real `risk_level` field already on every alert
///   record) rather than used as a reason to remove anything.
/// - The shared `AegisAppBar` widget itself was left untouched — it
///   has no bell/profile-action or badge support today, and inventing
///   that here would mean silently changing the header on every other
///   screen in the app that also uses `AegisAppBar`. Instead, a
///   screen-local "page title" row (bell icon + "Alerts" + subtitle)
///   was added below it, matching the reference image's second header
///   band without touching shared app chrome. See the chat reply for
///   this and the other two reference-image items that could not be
///   built with real data (an elder switcher, and a green "Resolved"
///   card style).
/// - No new screen/route was introduced.
///
/// BUGS FIXED while rebuilding this screen:
/// - The history card's subtitle used to print raw "Fall type
///   unavailable · Location unavailable" text whenever those
///   fields were missing; optional fields are now omitted cleanly
///   instead (the identity field, alert type, still always shows
///   something, including its own honest "unavailable" state).
/// - The date-group header used to show only "Today"/"Yesterday"/
///   "MMM d" with no diagnostic for which calendar date that actually
///   was; it now always carries the explicit date alongside the
///   relative label.
///
/// NOT changed: Component 1–4/XGBoost/MQTT/Supabase architecture,
/// AlertState's own fields/logic, or ApiService.getAlertHistory()'s
/// real network call.
class AlertsScreen extends StatefulWidget {
  final Elder elder;
  const AlertsScreen({super.key, required this.elder});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<Map<String, dynamic>> _alerts = [];
  bool _loading = true;
  String? _error;
  String _filter = "All";

  // Shares one in-flight request across initState/pull-to-refresh
  // instead of allowing overlapping/duplicate network calls.
  Future<void>? _inFlight;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _doLoad();
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<void> _doLoad() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await ApiService.instance.getAlertHistory(widget.elder.id);
      // Defensive: a single malformed (non-Map) entry from the backend
      // must not take down the whole screen — it's safely skipped.
      final alerts = result.whereType<Map<String, dynamic>>().toList();
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
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

  // Matches one alert record against one filter chip. "All" always
  // matches; the three type filters normalize the backend's alert_type
  // before comparing (unchanged from before this redesign); the two
  // risk filters compare the real risk_level field directly — an alert
  // with a missing/unrecognized risk_level simply never matches either
  // risk chip, rather than being guessed into one.
  bool _alertMatchesFilter(Map<String, dynamic> alert, String filter) {
    switch (filter) {
      case "All":
        return true;
      case "High Risk":
        final raw = alert["risk_level"];
        return raw is String && raw.trim().toUpperCase() == "HIGH";
      case "Medium Risk":
        final raw = alert["risk_level"];
        return raw is String && raw.trim().toUpperCase() == "MEDIUM";
      default:
        return _canonicalAlertType(alert["alert_type"]) == filter;
    }
  }

  @override
  Widget build(BuildContext context) {
    final alertState = context.watch<AlertState>();
    // Never mutates _alerts — .where(...).toList() always builds a new list.
    final filtered =
        _alerts.where((a) => _alertMatchesFilter(a, _filter)).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AegisAppBar(showLogo: false, title: "Alerts"),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
          children: [
            _AlertsPageTitle(elderName: widget.elder.name),
            const SizedBox(height: AppSpacing.xl),

            // ACTIVE ALERTS — real AlertState only, never fabricated.
            Text("Active Alerts",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            if (!alertState.hasActiveAlert)
              const EmptyState(
                  icon: Icons.shield_outlined, message: "No active alerts")
            else
              _ActiveAlertCard(
                alertState: alertState,
                elderName: widget.elder.name,
                elderAge: widget.elder.age,
                elderGender: widget.elder.gender,
                elderAvatarId: widget.elder.avatarId,
              ),

            const SizedBox(height: AppSpacing.xl),
            Text("Alert History",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _filterChips.map((f) {
                  final selected = _filter == f;
                  return Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: ChoiceChip(
                      label: Text(_chipLabel(f)),
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
            const SizedBox(height: AppSpacing.md),

            if (_loading)
              const LoadingState()
            else if (_error != null)
              ErrorStateView(
                  message: "Couldn't load alert history", onRetry: _load)
            else if (filtered.isEmpty)
              EmptyState(
                icon: Icons.history,
                message:
                    _filterEmptyLabels[_filter] ?? "No alert history available",
              )
            else
              ..._buildGroupedHistory(filtered),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGroupedHistory(List<Map<String, dynamic>> filtered) {
    // Safely parse every record's timestamp first; a record with a
    // missing/invalid timestamp is never dropped or given a fabricated
    // date — it's set aside into its own trailing group instead.
    final withDate = <MapEntry<Map<String, dynamic>, DateTime>>[];
    final withoutDate = <Map<String, dynamic>>[];
    for (final a in filtered) {
      final dt = _parseDate(a["created_at"]);
      if (dt != null) {
        withDate.add(MapEntry(a, dt));
      } else {
        withoutDate.add(a);
      }
    }
    // Newest first, independent of whatever order the backend returned.
    withDate.sort((x, y) => y.value.compareTo(x.value));

    final Map<String, List<MapEntry<Map<String, dynamic>, DateTime>>> grouped =
        {};
    for (final entry in withDate) {
      grouped.putIfAbsent(_dateGroupLabel(entry.value), () => []).add(entry);
    }

    final widgets = <Widget>[];
    for (final group in grouped.entries) {
      widgets.add(_groupHeader(group.key));
      widgets.addAll(
          group.value.map((entry) => _historyTile(entry.key, entry.value)));
    }
    if (withoutDate.isNotEmpty) {
      widgets.add(_groupHeader("Date unavailable"));
      widgets.addAll(withoutDate.map((a) => _historyTile(a, null)));
    }
    return widgets;
  }

  Widget _groupHeader(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }

  Widget _historyTile(Map<String, dynamic> alert, DateTime? dt) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: _AlertHistoryCard(
        alert: alert,
        time: dt,
        elderName: widget.elder.name,
        // CRITICAL FIX (kept from the previous hardening pass): pass
        // this specific history record through so the detail screen
        // shows THIS alert, not whatever the live active alert happens
        // to be right now.
        //
        // elderName/elderAge/elderGender: the Alert Details screen's
        // own "Elder Information" section has no other way to know
        // whose alert this is (its constructor takes no Elder, and no
        // alert record carries an elder name) — AlertsScreen is the
        // one place that already has the real Elder on hand, so it's
        // passed through here rather than invented on the detail
        // screen itself.
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AlertDetailScreen(
              historyAlert: alert,
              elderName: widget.elder.name,
              elderAge: widget.elder.age,
              elderGender: widget.elder.gender,
              elderAvatarId: widget.elder.avatarId,
            ),
          ),
        ),
      ),
    );
  }
}

/// Page-title band shown under the app's shared header: bell icon +
/// "Alerts" + subtitle, per the redesign brief's "Page Title" section.
/// No elder-switcher dropdown is shown here — this app's caregiver
/// flow (RootShell → AlertsScreen) is single-elder by design (the
/// splash-screen routing sends a caregiver straight to one elder's
/// dashboard, with no in-app elder switcher), so a reference-image
/// "All Elders" control would be inventing selection functionality the
/// app doesn't have. The elder's real name is shown in the subtitle
/// instead, since that IS genuinely available here.
class _AlertsPageTitle extends StatelessWidget {
  final String elderName;
  const _AlertsPageTitle({required this.elderName});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
              color: AppColors.primaryLight, shape: BoxShape.circle),
          child: const Icon(Icons.notifications_rounded,
              color: AppColors.primary, size: 22),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Alerts", style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 2),
              Text(
                "View and manage alerts for $elderName",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Small "Name · Elder" pill shown on each card — real data (the
/// screen's own `widget.elder.name`), never a fabricated/placeholder
/// name.
class _ElderPill extends StatelessWidget {
  final String name;
  const _ElderPill({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
                text: name,
                style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12)),
            const TextSpan(
                text: "  ·  Elder",
                style: TextStyle(color: AppColors.primary, fontSize: 12)),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Risk-level pill badge — only ever rendered when a real risk_level
/// value is present (see _humanizeRiskLevelOrNull); omitted entirely
/// otherwise rather than showing a placeholder/invented risk.
class _RiskPill extends StatelessWidget {
  final String label;
  final Color color;
  const _RiskPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Text(label,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

/// One icon+label item in a card's bottom info row (time / location /
/// fall type). Each caller only passes fields that are actually
/// available — this widget itself never decides to show a placeholder.
class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _ActiveAlertCard extends StatelessWidget {
  final AlertState alertState;
  final String elderName;
  final int elderAge;
  final String? elderGender;
  // ADDED (elder avatar on Alert Details, on request): optional, passed
  // through to AlertDetailScreen the same way as elderName/elderAge/
  // elderGender above.
  final String? elderAvatarId;
  const _ActiveAlertCard({
    required this.alertState,
    required this.elderName,
    required this.elderAge,
    required this.elderGender,
    this.elderAvatarId,
  });

  @override
  Widget build(BuildContext context) {
    final color = AppColors.alertType(alertState.alertType);
    final icon = _alertIconFor(alertState.alertType);
    final alertTypeLabel = _humanizeAlertType(alertState.alertType);
    final fallTypeLabel = _humanizeFallTypeOrNull(alertState.fallType);
    final riskLabel = _humanizeRiskLevelOrNull(alertState.riskLevel);
    final riskColor = AppColors.severity(alertState.riskLevel);
    final locationLabel = _humanizeLocationOrNull(alertState.location);
    final timeLabel = _formatTime(alertState.occurredAt);

    return Card(
      color: color.withValues(alpha: 0.08),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        // Active Alert always opens the live AlertState — no
        // `historyAlert` argument, unchanged from before. elderName/
        // elderAge/elderGender are passed the same way as on the
        // History card above, so "Elder Information" on the detail
        // screen is populated for both the live and the historical
        // alert, from the one real Elder this screen already has.
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AlertDetailScreen(
              elderName: elderName,
              elderAge: elderAge,
              elderGender: elderGender,
              elderAvatarId: elderAvatarId,
            ),
          ),
        ),
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
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      alertTypeLabel,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: color,
                          fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (riskLabel != null)
                    _RiskPill(label: riskLabel, color: riskColor),
                  const SizedBox(width: AppSpacing.xs),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: 6,
                children: [
                  _ElderPill(name: elderName),
                  if (fallTypeLabel != null || locationLabel != null)
                    Text(
                      [fallTypeLabel, locationLabel]
                          .whereType<String>()
                          .join(" • "),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: 4,
                children: [
                  _InfoChip(icon: Icons.access_time, label: timeLabel),
                  if (locationLabel != null)
                    _InfoChip(
                        icon: Icons.location_on_outlined, label: locationLabel),
                  if (fallTypeLabel != null)
                    _InfoChip(
                        icon: Icons.accessibility_new, label: fallTypeLabel),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertHistoryCard extends StatelessWidget {
  final Map<String, dynamic> alert;
  final DateTime? time;
  final String elderName;
  final VoidCallback onTap;
  const _AlertHistoryCard(
      {required this.alert,
      required this.time,
      required this.elderName,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final alertTypeRaw = alert["alert_type"];
    final color =
        AppColors.alertType(alertTypeRaw is String ? alertTypeRaw : null);
    final alertTypeLabel =
        _humanizeAlertType(alertTypeRaw is String ? alertTypeRaw : null);
    final fallTypeLabel = _humanizeFallTypeOrNull(
        alert["fall_type"] is String ? alert["fall_type"] as String : null);
    final riskRaw =
        alert["risk_level"] is String ? alert["risk_level"] as String : null;
    final riskLabel = _humanizeRiskLevelOrNull(riskRaw);
    final riskColor = AppColors.severity(riskRaw);
    final locationLabel = _humanizeLocationOrNull(
        alert["location"] is String ? alert["location"] as String : null);
    final timeLabel = _formatTime(time);
    final guidanceCompleted = alert["guidance_completed"] == true;

    return Card(
      color: color.withValues(alpha: 0.06),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
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
                        color: color.withValues(alpha: 0.12),
                        shape: BoxShape.circle),
                    child: Icon(
                        _alertIconFor(
                            alertTypeRaw is String ? alertTypeRaw : null),
                        color: color,
                        size: 20),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      alertTypeLabel,
                      style:
                          TextStyle(color: color, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (riskLabel != null)
                    _RiskPill(label: riskLabel, color: riskColor),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: 6,
                children: [
                  _ElderPill(name: elderName),
                  if (fallTypeLabel != null || locationLabel != null)
                    Text(
                      [fallTypeLabel, locationLabel]
                          .whereType<String>()
                          .join(" • "),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: AppSpacing.lg,
                      runSpacing: 4,
                      children: [
                        _InfoChip(icon: Icons.access_time, label: timeLabel),
                        if (locationLabel != null)
                          _InfoChip(
                              icon: Icons.location_on_outlined,
                              label: locationLabel),
                        if (fallTypeLabel != null)
                          _InfoChip(
                              icon: Icons.accessibility_new,
                              label: fallTypeLabel),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      color: AppColors.textSecondary),
                ],
              ),
              if (guidanceCompleted) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.check_circle,
                        size: 13, color: AppColors.safe),
                    const SizedBox(width: 4),
                    Text("Guidance completed",
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.safe)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
