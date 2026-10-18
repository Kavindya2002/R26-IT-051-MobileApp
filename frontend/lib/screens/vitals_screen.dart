import 'dart:async';
import 'package:flutter/material.dart';
import '../config.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/status_widgets.dart';

/// Vitals screen — Component 3 (PPG heart rate + BP).
///
/// UI REDESIGN (Vitals Screen professional visual-parity prompt):
/// restyled to match the Environment/Fall Detection screens' theme and
/// the approved reference mockup — teal header, white rounded cards,
/// pastel icon circles, status pills, consistent spacing.
///
/// NOT changed: ApiService.getVitalsLatest(), Component 3's PPG
/// pipeline, the backend response shape/field names, AppConfig
/// .pollInterval polling, the overlapping-request guard
/// (_fetchInProgress), safe numeric parsing, `_bpCategory()`'s
/// threshold values, `_parseDeviceTimestamp()`'s magnitude heuristic,
/// or `_isStale()` — only how these are presented.
///
/// One new UI-only concept was added for the mockup's "Measurement
/// Status" tile: it is NOT a new backend field or a fabricated
/// reading — it's a label derived entirely from the finger-detected
/// and staleness signals this screen already computes (the same kind
/// of derived status pill already used for BP category elsewhere on
/// this screen, and for risk/connectivity badges on the Environment
/// and Fall Detection screens).
///
/// BUG FIX (blank-screen / "BoxConstraints forces an infinite height"
/// crash): the Heart Rate / BP metric-card Row is a direct child of
/// the screen's ListView, which gives every child UNBOUNDED height
/// (it's a scrolling list). `CrossAxisAlignment.stretch` on a Row
/// tries to stretch its children to fill the Row's own cross-axis
/// (height) size — which here was unbounded, so Flutter could not
/// satisfy "stretch to infinity" and threw a layout assertion that
/// broke the entire render tree. Wrapping the Row in `IntrinsicHeight`
/// gives it a real, bounded height (the tallest child's natural
/// height) before stretch is applied — this fix is preserved exactly
/// as before; the same fix is reused for the new "Additional
/// Information" tile row added by this redesign.
class VitalsScreen extends StatefulWidget {
  const VitalsScreen({super.key});

  @override
  State<VitalsScreen> createState() => _VitalsScreenState();
}

class _VitalsScreenState extends State<VitalsScreen> {
  Timer? _timer;
  Map<String, dynamic>? _result;
  bool _loading = true;
  String? _error;
  bool _fetchInProgress = false;

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
    // FIX: guard against overlapping requests if a poll fires while a
    // previous one (or pull-to-refresh) is still in flight.
    if (_fetchInProgress) return;
    _fetchInProgress = true;
    try {
      final res = await ApiService.instance.getVitalsLatest();
      if (!mounted) return;
      setState(() {
        // FIX: a transient error no longer wipes out the last known
        // good reading — only a successful response replaces it, so a
        // caregiver viewing a real past reading never has it yanked
        // away by a dropped poll. Staleness (below) makes clear when
        // it's no longer current.
        _result = res["result"];
        _loading = false;
        _error = null;
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

  // Preserved EXACTLY per the prompt's instruction not to silently
  // alter the BP classification thresholds — only the return shape
  // changed (nullable, so the UI can show "No current reading"
  // instead of "-" when a value is missing).
  String? _bpCategory(int? sys, int? dia) {
    if (sys == null || dia == null) return null;
    if (sys < 120 && dia < 80) return "Normal";
    if (sys < 130 && dia < 80) return "Elevated";
    if (sys < 140 || dia < 90) return "High (Stage 1)";
    return "High (Stage 2)";
  }

  // DOCUMENTED LIMITATION B (final-review requirement): "Elevated" and
  // "High (Stage 1)" may use the same AegisCare warning/amber color
  // because the current theme does not contain a separate orange
  // semantic token. The AegisCare theme is intentionally NOT changed
  // just to remove this limitation (per the Remaining Issues prompt).
  // They remain distinguishable through their text labels in every
  // place this color is used (the metric card footer and the Blood
  // Pressure Status card) — color is never the only signal.
  Color _bpCategoryColor(String? category) {
    switch (category) {
      case "Normal":
        return AppColors.safe;
      case "Elevated":
      case "High (Stage 1)":
        return AppColors.warning;
      case "High (Stage 2)":
        return AppColors.emergency;
      default:
        return AppColors.textSecondary;
    }
  }

  String _formatClock(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? "AM" : "PM";
    return "$h:$m $ampm";
  }

  // FIX (bug: "Last updated" always showed "unavailable" even with a
  // real, fresh reading): Component 3's backend `timestamp` field is
  // a raw integer straight from the device payload
  // (app/component3/ml/ppg_processor.py: `timestamp = int(timestamp)`)
  // — never an ISO8601 string. `DateTime.tryParse(value.toString())`
  // on a plain integer like "1760270520000" always fails (tryParse
  // expects ISO8601 text), so `updatedParsed` was always null and the
  // staleness check never ran, regardless of how fresh the real data
  // was.
  //
  // KNOWN LIMITATION (disclosed, not hidden): the device firmware
  // that actually sets this field was not available to confirm its
  // exact unit. This parses by MAGNITUDE, the only honest way to
  // guess without the firmware:
  //   - >= 1e12  -> treated as epoch MILLISECONDS (a real calendar
  //                 time far enough in the future that only ms-since-
  //                 1970 reaches this range today).
  //   - 1e9..1e12 -> treated as epoch SECONDS, converted to ms.
  //   - below 1e9 -> most likely a device-uptime counter (e.g.
  //                 Arduino's `millis()`, time since the sensor
  //                 rebooted, NOT a calendar time) rather than a real
  //                 timestamp. There is no honest way to turn that
  //                 into a real date, so this intentionally returns
  //                 null (same as "no timestamp") instead of
  //                 fabricating a date near 1970 or guessing wrong.
  // Once the device firmware's actual format is confirmed, replace
  // this heuristic with a direct conversion for that one real format.
  DateTime? _parseDeviceTimestamp(dynamic raw) {
    if (raw == null) return null;
    final value = raw is num ? raw : num.tryParse(raw.toString());
    if (value == null) return null;
    final ms = value.toDouble();
    if (ms >= 1e12) {
      return DateTime.fromMillisecondsSinceEpoch(ms.round());
    }
    if (ms >= 1e9) {
      return DateTime.fromMillisecondsSinceEpoch((ms * 1000).round());
    }
    return null;
  }

  // Only ever built from the real `timestamp` field — no
  // DateTime.now() fallback when it's missing or fails to parse.
  String _formatUpdatedTime(DateTime? parsed) {
    if (parsed == null) return "Last updated time unavailable";
    final diff = DateTime.now().difference(parsed);
    if (diff.isNegative || diff.inSeconds < 60) return "Updated just now";
    if (diff.inMinutes < 60) return "Updated ${diff.inMinutes} min ago";
    if (diff.inHours < 24) return "Updated ${diff.inHours} hr ago";
    if (diff.inDays == 1) return "Yesterday, ${_formatClock(parsed)}";
    if (diff.inDays < 7) return "Updated ${diff.inDays} days ago";
    return "Updated ${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}";
  }

  // DOCUMENTED LIMITATION A (final-review requirement): stale-data
  // detection currently uses a client-side heuristic based on three
  // polling intervals because Component 3 does not provide a
  // dedicated backend freshness field. This is NOT a backend medical
  // freshness threshold — it never implies the sensor is disconnected
  // or that a reading is medically invalid, only that it may no
  // longer be current. A backend freshness field was intentionally
  // NOT added for this (per the Remaining Issues prompt: keep this a
  // Flutter-side refinement, not a new API contract).
  bool _isStale(DateTime? parsed) {
    if (parsed == null) return false;
    return DateTime.now().difference(parsed) > AppConfig.pollInterval * 3;
  }

  // UI REDESIGN ONLY (see class doc comment): the mockup's
  // "Measurement Status" tile, composed purely from the real
  // finger-detected and staleness signals already computed above —
  // never a new backend field, never a fabricated reading.
  String _measurementStatusLabel(
      {required bool fingerStateKnown,
      required bool fingerDetected,
      required bool stale}) {
    if (!fingerStateKnown) return "Unavailable";
    if (!fingerDetected) return "Waiting";
    if (stale) return "Outdated";
    return "Stable";
  }

  Color _measurementStatusColor(String label) {
    switch (label) {
      case "Stable":
        return AppColors.safe;
      case "Waiting":
      case "Outdated":
        return AppColors.warning;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Tri-state, not boolean: a payload that never included
    // finger_detected (null) is a genuinely different, unavailable
    // state — not silently treated as "not detected".
    final fingerRaw = _result?["finger_detected"];
    final fingerDetected = fingerRaw == true;
    final fingerStateKnown = fingerRaw != null;

    final heartRate = (_result?["heart_rate"] as num?)?.round();
    final sys = (_result?["systolic_bp"] as num?)?.round();
    final dia = (_result?["diastolic_bp"] as num?)?.round();
    final bpCategory = _bpCategory(sys, dia);

    // FIX: was DateTime.tryParse(_result?["timestamp"]?.toString() ?? "")
    // — that always failed (and always returned null) because the
    // backend's `timestamp` is a raw device integer, not an ISO8601
    // string. See _parseDeviceTimestamp's doc comment for the
    // magnitude-based heuristic and its disclosed limitation.
    final updatedParsed = _parseDeviceTimestamp(_result?["timestamp"]);
    final stale = _isStale(updatedParsed);

    final hasPriorResult = _result != null;
    final showFullScreenError = _error != null && !hasPriorResult;

    final measurementStatusLabel = _measurementStatusLabel(
        fingerStateKnown: fingerStateKnown,
        fingerDetected: fingerDetected,
        stale: stale);
    final measurementStatusColor =
        _measurementStatusColor(measurementStatusLabel);

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Vitals"),
      body: _loading
          ? const LoadingState(message: "Loading vital readings...")
          : showFullScreenError
              ? ErrorStateView(
                  message:
                      "Unable to load vital readings.\nPlease check the sensor or connection and try again.",
                  onRetry: _fetch,
                )
              // UI REDESIGN: wide-viewport (web/tablet) content is
              // centered and capped at a readable column width,
              // matching the Environment/Fall Detection screens'
              // responsive treatment — a phone-width screen sees no
              // change.
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final contentWidth = constraints.maxWidth > 640
                        ? 640.0
                        : constraints.maxWidth;
                    return RefreshIndicator(
                      onRefresh: _fetch,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: contentWidth,
                          child: ListView(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            children: [
                              Text("Vital Signs Monitoring",
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(
                                "Monitor heart rate and blood pressure using the PPG sensor.",
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: AppSpacing.lg),

                              // A later poll failing after we already had a
                              // good reading doesn't blank the screen — it
                              // shows this banner above the last known
                              // (now-staleness-flagged) values instead, so
                              // nothing caregiver-useful is lost.
                              if (_error != null && hasPriorResult) ...[
                                ConnectionLostBanner(
                                  lastUpdatedLabel:
                                      _formatUpdatedTime(updatedParsed),
                                  onRetry: _fetch,
                                ),
                                const SizedBox(height: AppSpacing.lg),
                              ],

                              _SensorStatusCard(
                                  fingerDetected: fingerDetected,
                                  fingerStateKnown: fingerStateKnown),

                              if (fingerDetected) ...[
                                const SizedBox(height: AppSpacing.lg),
                                // FIX: wrapped in IntrinsicHeight — see the
                                // class doc comment above for why
                                // CrossAxisAlignment.stretch on a bare Row
                                // here crashed the whole screen (unbounded
                                // height from the parent ListView).
                                // IntrinsicHeight gives the Row a real,
                                // bounded height equal to its tallest child
                                // before stretch is applied. Preserved
                                // exactly as before.
                                IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: _VitalMetricCard(
                                          icon: Icons.favorite_rounded,
                                          iconColor: AppColors.emergency,
                                          iconBg: AppColors.emergencyLight,
                                          title: "Heart Rate",
                                          value: heartRate == null
                                              ? "No current reading"
                                              : "$heartRate",
                                          unit: heartRate == null
                                              ? null
                                              : "bpm",
                                          footer: heartRate == null
                                              ? null
                                              : "Current",
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.md),
                                      Expanded(
                                        child: _VitalMetricCard(
                                          icon: Icons.bloodtype_rounded,
                                          iconColor: AppColors.primary,
                                          iconBg: AppColors.primaryLight,
                                          title: "Blood Pressure",
                                          value: (sys == null || dia == null)
                                              ? "No current reading"
                                              : "$sys/$dia",
                                          unit: (sys == null || dia == null)
                                              ? null
                                              : "mmHg",
                                          footer: bpCategory,
                                          footerColor:
                                              _bpCategoryColor(bpCategory),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: AppSpacing.lg),
                                _AdditionalInfoCard(
                                  bpCategory: bpCategory,
                                  bpCategoryColor:
                                      _bpCategoryColor(bpCategory),
                                  measurementStatusLabel:
                                      measurementStatusLabel,
                                  measurementStatusColor:
                                      measurementStatusColor,
                                ),
                              ],

                              // UI REDESIGN: the mockup's amber "place
                              // finger to measure" card — shown only in
                              // the genuinely-known "waiting" state
                              // (fingerStateKnown but not yet detected),
                              // never when the sensor status itself is
                              // unknown, so this never implies a working
                              // sensor that may not exist.
                              if (fingerStateKnown && !fingerDetected) ...[
                                const SizedBox(height: AppSpacing.lg),
                                const _PlaceFingerCard(),
                              ],

                              // FIX (Remaining Issues prompt, #2): "Last
                              // updated" now shows whenever we have ANY
                              // real backend result at all — not only
                              // while a finger is currently detected —
                              // since the `timestamp` field reflects when
                              // Component 3 last supplied data,
                              // independent of finger_detected. This still
                              // never fabricates a timestamp: if `_result`
                              // exists but has no parseable `timestamp`,
                              // it honestly shows "Last updated time
                              // unavailable".
                              if (hasPriorResult) ...[
                                const SizedBox(height: AppSpacing.lg),
                                _LastUpdatedCard(
                                  valueLabel:
                                      _formatUpdatedTime(updatedParsed),
                                  stale: stale,
                                  onRefresh: _fetch,
                                ),
                              ],

                              const SizedBox(height: AppSpacing.lg),
                              const _AboutVitalsCard(),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// PPG sensor connection card — a genuine 3-state read of
/// `finger_detected` (true / false / missing-from-payload), never
/// inferred from "the API call succeeded". Headline wording is kept
/// honest about what's actually known (finger detection only) even
/// though the reference mockup's accent-bar/pill visual style is
/// matched exactly — see this file's class doc comment.
class _SensorStatusCard extends StatelessWidget {
  final bool fingerDetected;
  final bool fingerStateKnown;
  const _SensorStatusCard(
      {required this.fingerDetected, required this.fingerStateKnown});

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    late final Color color;
    late final Color bg;
    late final String title;
    late final String statusText;
    late final String description;
    late final String pillLabel;

    if (!fingerStateKnown) {
      icon = Icons.sensors_off_rounded;
      color = AppColors.textSecondary;
      bg = AppColors.background;
      title = "PPG Sensor";
      statusText = "No Current Reading";
      description = "No current reading from the sensor.";
      pillLabel = "UNAVAILABLE";
    } else if (fingerDetected) {
      // FIX (Remaining Issues prompt, #1, preserved): "Sensor
      // Connected" over-claims a verified physical/electrical
      // connection that Component 3 never actually reports —
      // `finger_detected` only proves a finger is detected right now,
      // nothing about the sensor link itself. No separate backend
      // "connection status" field exists (confirmed via Component 3's
      // router.py), so the headline here states only what's actually
      // known: finger detection, and the sensor actively reading.
      icon = Icons.touch_app_rounded;
      color = AppColors.safe;
      bg = AppColors.safeLight;
      title = "Finger Detected";
      statusText = "Reading Vitals";
      description =
          "Sensor is reading your vital signs. Keep your finger on the sensor.";
      pillLabel = "ACTIVE";
    } else {
      icon = Icons.touch_app_outlined;
      color = AppColors.warning;
      bg = AppColors.warningLight;
      title = "Sensor Ready";
      statusText = "Waiting for Finger";
      description = "Place your finger on the sensor to measure vital signs.";
      pillLabel = "WAITING";
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                      child: Icon(icon, size: 28, color: color),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.circle, size: 8, color: color),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(statusText,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                            color: color,
                                            fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(description,
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        pillLabel,
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w800,
                            fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact metric card for Heart Rate / Blood Pressure — pastel icon
/// circle, large value, unit, and the SAME status footer the original
/// screen already computed (no new clinical indicator is introduced
/// for Heart Rate, which has no backend-computed category).
class _VitalMetricCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String value;
  final String? unit;
  final String? footer;
  final Color? footerColor;

  const _VitalMetricCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.value,
    this.unit,
    this.footer,
    this.footerColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration:
                      BoxDecoration(color: iconBg, shape: BoxShape.circle),
                  child: Icon(icon, size: 18, color: iconColor),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: Theme.of(context).textTheme.headlineSmall),
                  if (unit != null) ...[
                    const SizedBox(width: 4),
                    Text(unit!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            if (footer != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (footerColor ?? AppColors.textSecondary)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  footer!,
                  style: TextStyle(
                    color: footerColor ?? AppColors.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Additional Information" card — BP Category (existing, real
/// `_bpCategory()` output) and Measurement Status (new, UI-only label
/// derived from finger-detected + staleness — see class doc comment,
/// never a fabricated reading) as two tiles.
class _AdditionalInfoCard extends StatelessWidget {
  final String? bpCategory;
  final Color bpCategoryColor;
  final String measurementStatusLabel;
  final Color measurementStatusColor;

  const _AdditionalInfoCard({
    required this.bpCategory,
    required this.bpCategoryColor,
    required this.measurementStatusLabel,
    required this.measurementStatusColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.description_outlined,
                      size: 18, color: AppColors.primary),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text("Additional Information",
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // FIX (same crash avoided elsewhere on this screen): no
            // CrossAxisAlignment.stretch on a bare Row inside this
            // unbounded-height ListView — tiles size to their own
            // content instead.
            Row(
              children: [
                Expanded(
                  child: _infoTile(
                    context,
                    icon: Icons.favorite_border_rounded,
                    iconColor: bpCategoryColor,
                    label: "BP Category",
                    value: bpCategory ?? "No current reading",
                    valueColor: bpCategoryColor,
                  ),
                ),
                Container(
                  width: 1,
                  height: 40,
                  margin:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  color: AppColors.border,
                ),
                Expanded(
                  child: _infoTile(
                    context,
                    icon: Icons.access_time_filled_rounded,
                    iconColor: measurementStatusColor,
                    label: "Measurement Status",
                    value: measurementStatusLabel,
                    valueColor: measurementStatusColor,
                  ),
                ),
              ],
            ),
            if (bpCategory != null) ...[
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.sm),
              Text(
                "Within the displayed reference category. This is a monitoring category, not a medical diagnosis.",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoTile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 16, color: iconColor),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(
          value,
          softWrap: true,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontSize: 16, color: valueColor),
        ),
      ],
    );
  }
}

/// Amber instructional card shown only in the genuinely-known
/// "waiting for finger" state.
class _PlaceFingerCard extends StatelessWidget {
  const _PlaceFingerCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.warningLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppColors.warning,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.touch_app_rounded,
                size: 18, color: Colors.white),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Place finger on sensor to measure",
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  "Keep your finger on the sensor to read your vital signs.",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Last Updated card — real `timestamp`-derived label, a stale
/// warning when applicable, and a refresh button wired to the exact
/// same `_fetch()` pull-to-refresh already uses.
class _LastUpdatedCard extends StatelessWidget {
  final String valueLabel;
  final bool stale;
  final Future<void> Function() onRefresh;

  const _LastUpdatedCard({
    required this.valueLabel,
    required this.stale,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.access_time_rounded,
                  size: 18, color: AppColors.primary),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Last Updated",
                      style: Theme.of(context).textTheme.bodySmall),
                  Text(valueLabel,
                      style: Theme.of(context).textTheme.titleMedium),
                  if (stale) ...[
                    const SizedBox(height: 2),
                    Text(
                      // Client-side freshness heuristic only (see
                      // _isStale doc comment) — never a claim that the
                      // sensor is disconnected or the reading is
                      // medically invalid.
                      "Data may be outdated",
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color: AppColors.warning,
                              fontWeight: FontWeight.w700),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              onPressed: () => onRefresh(),
              tooltip: "Refresh",
              icon: const Icon(Icons.refresh_rounded, color: AppColors.primary),
              style: IconButton.styleFrom(
                backgroundColor: AppColors.primary.withValues(alpha: 0.10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Static informational footer card — satisfies both the mockup's
/// "About Vitals Monitoring" card and the prompt's required
/// not-a-substitute-for-medical-advice disclaimer, in one place. No
/// backend data.
class _AboutVitalsCard extends StatelessWidget {
  const _AboutVitalsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.info_outline, size: 18, color: Colors.white),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("About Vitals Monitoring",
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: AppColors.primaryDark)),
                const SizedBox(height: 4),
                Text(
                  "The system measures heart rate and blood pressure using a "
                  "PPG sensor. Keep your finger on the sensor for accurate "
                  "readings. For monitoring purposes only — not a substitute "
                  "for medical advice.",
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.primaryDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
