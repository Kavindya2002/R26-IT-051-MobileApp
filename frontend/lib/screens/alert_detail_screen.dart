import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/alert_state.dart';
import '../models/guidance_state.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/status_widgets.dart';
import 'elder_guidance_screen.dart';

/// Alert Detail screen — shows the current real-time AlertState
/// (Component 4's most recent alert decision) with the actions a
/// caregiver can take on it.
///
/// UI REDESIGN PASS (this round) — strict scope: only this screen was
/// touched. Nothing in AlertsScreen, Home Dashboard, Analytics,
/// Profile, bottom navigation, `AegisAppBar`, the backend, AlertState/
/// GuidanceState's own fields, Component 1–4/XGBoost logic, or risk
/// thresholds was changed.
///
/// MANDATORY REMOVALS (redesign brief section 4):
/// - "Latest Sensor Reading" — this section did not actually exist
///   anywhere in this screen already (confirmed by inspection before
///   making any change), so there was nothing to remove here.
/// - "Model Confidence" card — removed entirely from both the live
///   and the historical view, along with the now-unused confidence
///   label/value computation that only fed it.
/// - Both unconditional action buttons ("Call Elder", "Mark Resolved")
///   — removed entirely, including their containers/spacing and the
///   handlers that only existed to serve them (`_callElder`,
///   `_confirmResolve`, `_isResolving`, and the now-unused
///   `url_launcher` import). No replacement buttons were added in
///   their place, per the brief's "do not replace... with two new
///   buttons."
///   NOT removed: the "View Guidance" entry. It isn't one of "both"
///   buttons referred to above — it's a third, conditional element
///   that only ever appears while `GuidanceState` reports guidance is
///   actually active for this real alert — and the brief's own
///   section 3D asks this screen to keep showing real guidance
///   information when the app actually provides it, rather than
///   stripping every action off the screen. Removing it would have
///   deleted working navigation to the real Guidance screen with
///   nothing asked for in its place. Flagged in the chat reply in case
///   the intent was actually to remove this too.
///
/// B. ELDER INFORMATION (added on request, after this screen's first
/// redesign pass shipped without it): this screen's constructor takes
/// no `Elder` and no alert record (live or historical) carries an
/// elder name field, so there is no real elder identity available to
/// this screen BY ITSELF. `AlertsScreen` is the one place that already
/// holds the real `Elder` for every alert/history card it renders, so
/// it now passes `elderName`/`elderAge`/`elderGender` through at both
/// of its `AlertDetailScreen(...)` navigation call sites (see
/// `alerts_screen.dart`). All three are optional here and the new
/// `_ElderInfoCard` only renders when a real, non-empty name was
/// actually supplied — no name/age/gender is ever invented when it
/// wasn't.
///
/// BUGS FIXED while redesigning this screen (both the live and the
/// historical probability-breakdown block had the same two bugs):
/// - `AppColors.alertType(e.key)` was being called with the RAW
///   probability key straight from the backend (often snake_case,
///   e.g. "emergency_alert"), but `AppColors.alertType()` only matches
///   Title-Case substrings ("Emergency"/"Caregiver"). A snake_case key
///   silently fell through to the default teal color instead of its
///   real emergency/caregiver/voice color — every probability bar
///   could render the wrong color. Same raw-key problem made
///   `isSelected` (the checkmark + bold highlight on the chosen
///   option) compare a snake_case key against `alert.alertType`, which
///   is already Title-Case — so the actually-selected entry could
///   simply never match and never get its highlight. Both are now
///   resolved through the same canonical-alert-type lookup already
///   used elsewhere on this screen (`_canonicalAlertTypeKey`, added
///   below) before either comparing or coloring, so an unrecognized
///   key still safely falls back to the neutral default instead of
///   silently miscoloring a real alert type.
///
/// NOT changed from the previous pass: alert type / fall type / risk
/// level / location humanization, safe/clamped probability parsing,
/// the live-vs-historical rendering split (`historyAlert`), or
/// AlertState/GuidanceState's own fields and logic.
class AlertDetailScreen extends StatefulWidget {
  final Map<String, dynamic>? historyAlert;
  // ADDED (Elder Information section, on request): the screen itself
  // has no Elder and no alert record carries an elder name, so these
  // are optional and supplied by the caller (AlertsScreen, which
  // already has the real Elder) rather than invented here. All three
  // stay null for any existing/other caller that doesn't pass them —
  // the Elder Information section below simply doesn't render in that
  // case instead of showing a placeholder.
  final String? elderName;
  final int? elderAge;
  final String? elderGender;
  // ADDED (elder avatar on this screen, on request): same optional,
  // caller-supplied pattern as elderName/elderAge/elderGender above —
  // stays null for any caller that doesn't pass it, in which case
  // _ElderInfoCard's AvatarCircle just falls back to the initial-letter
  // circle it already showed before this change.
  final String? elderAvatarId;
  const AlertDetailScreen({
    super.key,
    this.historyAlert,
    this.elderName,
    this.elderAge,
    this.elderGender,
    this.elderAvatarId,
  });

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  static const Map<String, String> _alertTypeLabels = {
    "emergency_alert": "Emergency Alert",
    "caregiver_alert": "Caregiver Alert",
    "voice_alert": "Voice Alert",
  };

  // Normalized (lowercase, underscores→spaces) forms of every alert
  // type this screen actually knows how to display. Used to safely
  // accept an already-humanized value (e.g. AlertState handing us
  // "Emergency Alert" directly) without accepting arbitrary unknown
  // text.
  static const Set<String> _knownAlertTypeValues = {
    "emergency alert",
    "caregiver alert",
    "voice alert",
  };

  static const Map<String, String> _fallTypeLabels = {
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

  static const Map<String, String> _locationLabels = {
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

  // Only ever returns a KNOWN alert type (mapped from snake_case, or an
  // already-humanized value this screen recognizes) or the honest
  // "Alert type unavailable" message. Never displays an unexpected
  // backend value directly, and never silently reassigns it to one of
  // the three real alert types.
  String _humanizeAlertType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Alert type unavailable";
    final trimmed = raw.trim();
    final key = trimmed.toLowerCase();
    if (_alertTypeLabels.containsKey(key)) return _alertTypeLabels[key]!;
    final normalized = key.replaceAll('_', ' ');
    if (_knownAlertTypeValues.contains(normalized)) return _titleCase(trimmed);
    return "Alert type unavailable";
  }

  // BUG FIX (see class doc comment above): the single source of truth
  // for "what canonical alert type does this raw key represent" — or
  // null when it isn't one of the three known types. Used before BOTH
  // comparing a probability key against the selected alert type AND
  // before coloring it, so a snake_case backend key and an
  // already-humanized one are always treated identically instead of
  // silently miscomparing/miscoloring.
  String? _canonicalAlertTypeKey(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final key = trimmed.toLowerCase();
    if (_alertTypeLabels.containsKey(key)) return _alertTypeLabels[key];
    final normalized = key.replaceAll('_', ' ');
    if (_knownAlertTypeValues.contains(normalized)) return _titleCase(trimmed);
    return null;
  }

  // Same known-values check as _humanizeAlertType, but for probability
  // breakdown labels specifically: an unexpected/unknown key is shown
  // as a safe human-readable fallback rather than raw snake_case, per
  // the Remaining Issues fix. The probability VALUE itself is never
  // touched here — only the label.
  String _humanizeProbabilityLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return "Alert option unavailable";
    final key = trimmed.toLowerCase();
    if (_alertTypeLabels.containsKey(key)) return _alertTypeLabels[key]!;
    final normalized = key.replaceAll('_', ' ');
    if (_knownAlertTypeValues.contains(normalized)) return _titleCase(trimmed);
    return "Other alert option";
  }

  // Only ever returns a KNOWN fall type or "Fall type unavailable" — an
  // unrecognized value is no longer title-cased (which could make it
  // look like a legitimate fall type), per the Remaining Issues
  // Hardening Fix.
  String _humanizeFallType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Fall type unavailable";
    final key = raw.trim().toLowerCase();
    return _fallTypeLabels[key] ?? "Fall type unavailable";
  }

  String _humanizeRiskLevel(String? raw) {
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
        return "Risk level unavailable";
    }
  }

  // Only ever returns a KNOWN location or "Location unavailable" — an
  // unrecognized value is no longer title-cased (which could make it
  // look like a legitimate location), per the Remaining Issues
  // Hardening Fix.
  String _humanizeLocation(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Location unavailable";
    final key = raw.trim().toLowerCase();
    return _locationLabels[key] ?? "Location unavailable";
  }

  // Only ever formats a real DateTime already on AlertState (set once,
  // when the alert was recorded) — never DateTime.now() as a stand-in
  // for a missing value.
  String _formatAlertTime(DateTime? dt) {
    if (dt == null) return "Time unavailable";
    return DateFormat("dd MMM yyyy, hh:mm a").format(dt.toLocal());
  }

  // Accepts num, int, double, or a numeric string; returns null (never
  // throws) for anything else, so one malformed probability entry can't
  // take down the whole screen. The caller omits an entry that parses
  // to null rather than showing a fabricated 0%.
  double? _parseProbability(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }

  double _clampProbability(double value) => value.clamp(0, 100).toDouble();

  // Never throws on a malformed/missing stored timestamp — used only
  // for the historical (history-record) view below.
  DateTime? _parseStoredDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      return DateTime.tryParse(trimmed);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // A history record was passed explicitly — show THIS alert,
    // read-only, and never consult the live AlertState at all (so it
    // can never be confused with whatever the current active alert is).
    final historyAlert = widget.historyAlert;
    if (historyAlert != null) {
      return _buildHistoricalView(context, historyAlert);
    }

    return Consumer<AlertState>(
      builder: (context, alert, _) {
        if (!alert.hasActiveAlert) {
          return Scaffold(
            appBar: AegisAppBar(showLogo: false, title: "Alert Details"),
            body: const EmptyState(
              icon: Icons.check_circle_outline,
              message:
                  "No Active Alert\n\nNo active alert requires attention right now.",
            ),
          );
        }

        final color = AppColors.alertType(alert.alertType);
        final alertTypeLabel = _humanizeAlertType(alert.alertType);
        final fallTypeLabel = _humanizeFallType(alert.fallType);
        final riskLabel = _humanizeRiskLevel(alert.riskLevel);
        final riskColor = AppColors.severity(alert.riskLevel);
        final locationLabel = _humanizeLocation(alert.location);
        final timeLabel = _formatAlertTime(alert.occurredAt);

        final guidanceActive =
            context.watch<GuidanceState>().status == GuidanceStatus.active;

        // Safely parsed + clamped probability entries only — an
        // unparseable entry is skipped rather than crashing the screen
        // or showing a fabricated value.
        final probEntries = <MapEntry<String, double>>[];
        for (final e in (alert.probabilities ?? {}).entries) {
          final parsed = _parseProbability(e.value);
          if (parsed != null)
            probEntries.add(MapEntry(e.key, _clampProbability(parsed)));
        }

        final alertIcon = _alertIconFor(alert.alertType);
        final alertMessage = _alertMessageFor(alert.alertType);
        final selectedCanonical = _canonicalAlertTypeKey(alert.alertType);

        return Scaffold(
          appBar: AegisAppBar(showLogo: false, title: "Alert Details"),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              children: [
                // A. ALERT HEADER — icon, alert type (most prominent
                // fact on screen), risk level, and the alert's own
                // date/time, all in one card.
                _HeaderCard(
                  icon: alertIcon,
                  color: color,
                  alertTypeLabel: alertTypeLabel,
                  fallTypeLabel: fallTypeLabel,
                  riskLabel: riskLabel,
                  riskColor: riskColor,
                  timeLabel: timeLabel,
                  alertMessage: alertMessage,
                ),

                // B. ELDER INFORMATION — only rendered when the caller
                // (AlertsScreen) actually passed a real elder name;
                // never a placeholder when it didn't.
                if (widget.elderName != null &&
                    widget.elderName!.trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  _ElderInfoCard(
                      name: widget.elderName!,
                      age: widget.elderAge,
                      gender: widget.elderGender,
                      avatarId: widget.elderAvatarId),
                ],

                const SizedBox(height: AppSpacing.lg),
                // C. INCIDENT DETAILS
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Incident Details",
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: AppSpacing.sm),
                        _row(context, Icons.accessibility_new_rounded,
                            "Fall Type", fallTypeLabel),
                        const Divider(height: AppSpacing.lg),
                        _row(context, Icons.warning_amber_rounded, "Risk Level",
                            riskLabel,
                            valueColor: riskColor),
                        const Divider(height: AppSpacing.lg),
                        _row(context, Icons.location_on_rounded, "Location",
                            locationLabel),
                        const Divider(height: AppSpacing.lg),
                        _row(
                            context, Icons.schedule_rounded, "Time", timeLabel),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: AppSpacing.lg),
                // ALERT DECISION (probability breakdown) — kept; not
                // named in the redesign brief's removal list, and
                // removing a working, real data-backed section wasn't
                // asked for. Restyled nothing here beyond the bug fix
                // described in the class doc comment.
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Alert Decision",
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(
                          "The alert model evaluates the available alert options. The selected alert corresponds to the highest model probability.",
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (probEntries.isEmpty)
                          Text(
                              "No probability breakdown available for this alert.",
                              style: Theme.of(context).textTheme.bodyMedium)
                        else
                          ...probEntries.map((e) =>
                              _probabilityRow(context, e, selectedCanonical)),
                      ],
                    ),
                  ),
                ),

                // D. GUIDANCE INFORMATION — only the real, existing
                // "View Guidance" entry point, only while GuidanceState
                // actually reports guidance as active for this alert.
                // Nothing invented when it isn't.
                if (guidanceActive) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const ElderGuidanceScreen())),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                  color: AppColors.primaryLight,
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.record_voice_over_rounded,
                                  color: AppColors.primary, size: 20),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("Recovery Guidance",
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 2),
                                  Text("Guidance is active for this alert",
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right,
                                color: AppColors.textSecondary),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // Renders a past Alert History record read-only. Deliberately omits
  // View Guidance — that's a live action tied to the CURRENT active
  // alert's GuidanceState, and showing it here would imply this old
  // record can still be acted on, which isn't real backend behavior.
  // A stored probabilities value is shown if present; if the history
  // record genuinely doesn't carry one, that's stated honestly rather
  // than inventing a breakdown.
  Widget _buildHistoricalView(
      BuildContext context, Map<String, dynamic> record) {
    String? asString(dynamic v) => v is String ? v : null;

    final alertTypeRaw = asString(record["alert_type"]);
    final color = AppColors.alertType(alertTypeRaw);
    final alertTypeLabel = _humanizeAlertType(alertTypeRaw);
    final fallTypeLabel = _humanizeFallType(asString(record["fall_type"]));
    final riskLabel = _humanizeRiskLevel(asString(record["risk_level"]));
    final riskColor = AppColors.severity(asString(record["risk_level"]));
    final locationLabel = _humanizeLocation(asString(record["location"]));
    final timeLabel = _formatAlertTime(_parseStoredDate(record["created_at"]));
    final guidanceCompleted = record["guidance_completed"] == true;

    final probEntries = <MapEntry<String, double>>[];
    final rawProbabilities = record["probabilities"];
    if (rawProbabilities is Map) {
      for (final e in rawProbabilities.entries) {
        final parsed = _parseProbability(e.value);
        if (parsed != null)
          probEntries
              .add(MapEntry(e.key.toString(), _clampProbability(parsed)));
      }
    }

    final alertIcon = _alertIconFor(alertTypeRaw);
    final alertMessage = _alertMessageFor(alertTypeRaw);
    final selectedCanonical = _canonicalAlertTypeKey(alertTypeRaw);

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Alert Details"),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            _HeaderCard(
              icon: alertIcon,
              color: color,
              alertTypeLabel: alertTypeLabel,
              fallTypeLabel: fallTypeLabel,
              riskLabel: riskLabel,
              riskColor: riskColor,
              timeLabel: timeLabel,
              alertMessage: alertMessage,
            ),
            // B. ELDER INFORMATION — same real-data-only rule as the
            // live view above.
            if (widget.elderName != null &&
                widget.elderName!.trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _ElderInfoCard(
                  name: widget.elderName!,
                  age: widget.elderAge,
                  gender: widget.elderGender,
                  avatarId: widget.elderAvatarId),
            ],
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Incident Details",
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: AppSpacing.sm),
                    _row(context, Icons.accessibility_new_rounded, "Fall Type",
                        fallTypeLabel),
                    const Divider(height: AppSpacing.lg),
                    _row(context, Icons.warning_amber_rounded, "Risk Level",
                        riskLabel,
                        valueColor: riskColor),
                    const Divider(height: AppSpacing.lg),
                    _row(context, Icons.location_on_rounded, "Location",
                        locationLabel),
                    const Divider(height: AppSpacing.lg),
                    _row(context, Icons.schedule_rounded, "Time", timeLabel),
                  ],
                ),
              ),
            ),
            if (probEntries.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Alert Decision",
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        "The alert model evaluates the available alert options. The selected alert corresponds to the highest model probability.",
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      ...probEntries.map((e) =>
                          _probabilityRow(context, e, selectedCanonical)),
                    ],
                  ),
                ),
              ),
            ],
            // D. GUIDANCE/RESOLUTION INFORMATION — real stored status
            // only; hidden entirely when the record doesn't say
            // guidance was completed, rather than showing a "not
            // completed" state this screen can't actually verify.
            if (guidanceCompleted) ...[
              const SizedBox(height: AppSpacing.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          size: 20, color: AppColors.safe),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        "Guidance completed",
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.safe, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // One probability entry row, shared by the live and historical
  // views. `selectedCanonical` is this alert's own canonical type
  // (e.g. "Emergency Alert") or null — compared against this entry's
  // OWN canonical type (not its raw key) so a snake_case backend key
  // and an already-humanized one behave identically. See the class
  // doc comment ("BUGS FIXED") for why this replaced the previous
  // raw-key comparison/coloring.
  Widget _probabilityRow(BuildContext context, MapEntry<String, double> e,
      String? selectedCanonical) {
    final entryCanonical = _canonicalAlertTypeKey(e.key);
    final isSelected =
        entryCanonical != null && entryCanonical == selectedCanonical;
    final entryColor = AppColors.alertType(entryCanonical ?? "");
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isSelected) ...[
                Icon(Icons.check_circle, size: 14, color: entryColor),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  _humanizeProbabilityLabel(e.key),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            isSelected ? FontWeight.w800 : FontWeight.w400,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                "${e.value.toStringAsFixed(0)}%",
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.w800 : FontWeight.w400,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: e.value / 100,
              minHeight: isSelected ? 10 : 6,
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation(entryColor),
            ),
          ),
        ],
      ),
    );
  }

  // Exact, normalized classification — NOT substring matching. A
  // substring check like `.contains("emergency")` would incorrectly
  // classify an unsupported value such as "unknown_emergency_type" as
  // a real Emergency Alert; normalizing (trim/lowercase/underscore→
  // space) and then switching on the exact known strings means only
  // the three real alert types this app supports ever get their
  // specific icon — anything else safely falls through to a generic
  // one. Shared by both the live (active) and historical alert views.
  //
  // ICON PASS: switched to the `_rounded` Material icon variants per
  // the redesign brief's icon guidance (section 5) — same
  // classification logic, cosmetic glyph change only.
  IconData _alertIconFor(String? alertType) {
    final normalized =
        (alertType ?? "").trim().toLowerCase().replaceAll("_", " ");
    switch (normalized) {
      case "emergency alert":
        return Icons.emergency_rounded;
      case "caregiver alert":
        return Icons.warning_amber_rounded;
      case "voice alert":
        return Icons.volume_up_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  String _alertMessageFor(String? alertType) {
    final normalized =
        (alertType ?? "").trim().toLowerCase().replaceAll("_", " ");
    switch (normalized) {
      case "emergency alert":
        return "Immediate attention may be required.";
      case "voice alert":
        return "Preventive warning.";
      default:
        return "";
    }
  }

  Widget _row(BuildContext context, IconData icon, String label, String value,
      {Color? valueColor}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: valueColor ?? AppColors.textSecondary),
        const SizedBox(width: 10),
        SizedBox(
          width: 140,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: valueColor, fontWeight: FontWeight.w700),
            textAlign: TextAlign.left,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// A. Alert Header card — icon, alert type, fall type, a risk-level
/// pill with its own icon, and the alert's own date/time. Shared by
/// the live and historical views so both read identically.
class _HeaderCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String alertTypeLabel;
  final String fallTypeLabel;
  final String riskLabel;
  final Color riskColor;
  final String timeLabel;
  final String alertMessage;

  const _HeaderCard({
    required this.icon,
    required this.color,
    required this.alertTypeLabel,
    required this.fallTypeLabel,
    required this.riskLabel,
    required this.riskColor,
    required this.timeLabel,
    required this.alertMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      // .withValues(alpha:) used instead of the deprecated
      // .withOpacity(), matching this project's real
      // flutter analyze output (confirmed on Environment Screen).
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Icon(icon, size: 32, color: color),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              alertTypeLabel.toUpperCase(),
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: color, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(fallTypeLabel,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.lg,
              runSpacing: 6,
              children: [
                _pill(Icons.warning_amber_rounded, riskLabel, riskColor),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule_rounded,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(timeLabel,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
            ),
            if (alertMessage.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(alertMessage,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }
}

/// B. Elder Information card — added on request. Only ever built when
/// the caller passed a real `name` (both call sites check that before
/// constructing this widget at all), so there's no "Elder unavailable"
/// placeholder state to design for here. `age`/`gender` are optional
/// and each one is omitted individually when not present, rather than
/// showing e.g. "Age: -" — the Elder model's `gender` is nullable
/// today, and an `age` of exactly 0 is treated as unset (the same
/// "no real value yet" convention already used for it in
/// MyEldersScreen's own elder list).
class _ElderInfoCard extends StatelessWidget {
  final String name;
  final int? age;
  final String? gender;
  // ADDED (elder avatar on this screen, on request): optional — when the
  // caller doesn't pass a real avatarId, AvatarCircle below falls back
  // to the same initial-letter circle this card already showed.
  final String? avatarId;
  const _ElderInfoCard(
      {required this.name,
      required this.age,
      required this.gender,
      this.avatarId});

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (age != null && age! > 0) "Age $age",
      if (gender != null && gender!.trim().isNotEmpty) gender!.trim(),
    ].join(" · ");

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            AvatarCircle(
              avatarId: avatarId,
              fallbackInitial:
                  name.trim().isEmpty ? "?" : name.trim().substring(0, 1).toUpperCase(),
              radius: 24,
              fallbackColor: AppColors.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Row(
                children: [
                  const Icon(Icons.person_rounded,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  // Name and "Age · Gender" on the SAME line (one
                  // Text.rich instead of a stacked Column) — the
                  // details span uses a smaller/secondary style so it
                  // still reads as supporting info, not a second name.
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: Theme.of(context).textTheme.titleMedium,
                        children: [
                          TextSpan(text: name),
                          if (details.isNotEmpty)
                            TextSpan(
                              text: "   •   $details",
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
