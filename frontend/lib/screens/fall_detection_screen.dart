import 'dart:async';
import 'package:flutter/material.dart';
import '../config.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/status_widgets.dart';

/// Fall Detection screen — Component 1 (fall detection / fall type /
/// risk level / activity / stability).
///
/// UI REDESIGN (Fall Detection Screen visual-parity prompt): restyled to
/// match the Environment screen's theme — teal header, white rounded
/// cards, pastel icon circles, consistent spacing — and the approved
/// mockup. Removed from the UI entirely (per the prompt): the Sensor
/// Data / accelerometer / gyroscope section (this file never had one —
/// confirmed by reading the whole screen before editing), the Model
/// Confidence field/gauge, the separate "Fall Detected: Yes/No" row, and
/// the old two-card split (Current Activity card + Detection Details
/// card) — replaced by ONE "Detection Details" card holding Fall Type /
/// Risk Level / Current Activity / Stability as four tiles in a
/// responsive 2-column grid, matching the mockup.
///
/// NOT changed: ApiService.getFallLatest(), Component 1's MQTT/ML
/// pipeline, risk-level logic, fall-type classifier, the overlapping-
/// request polling guard, periodic polling via AppConfig.pollInterval,
/// pull-to-refresh, loading/error/no-data/stale states, or the API
/// response shape — only how these values are presented. The
/// `confidence` field is still real backend data; it is simply no
/// longer surfaced in the UI per this redesign's explicit requirement
/// (the field itself is not fabricated or removed from the backend).
class FallDetectionScreen extends StatefulWidget {
  const FallDetectionScreen({super.key});

  @override
  State<FallDetectionScreen> createState() => _FallDetectionScreenState();
}

class _FallDetectionScreenState extends State<FallDetectionScreen> {
  Timer? _timer;
  Map<String, dynamic>? _result;
  String? _error;
  bool _loading = true;
  bool _fetchInProgress = false;

  // Humanization maps are display-only — the raw backend string is
  // never altered or re-sent anywhere. Both the project's actual
  // Title-Case values (confirmed via Component 1's ML source: e.g.
  // "Forward Fall", "Side Fall Right", "Walking") and the generic
  // snake_case forms from the fix prompt are covered, so this keeps
  // working even if the backend's exact wording changes later.
  static const Map<String, String> _fallTypeLabels = {
    "no fall": "No Fall",
    "fall_forward": "Forward Fall",
    "forward fall": "Forward Fall",
    "fall_backward": "Backward Fall",
    "backward fall": "Backward Fall",
    "fall_side_left": "Left Side Fall",
    "side fall left": "Left Side Fall",
    "fall_side_right": "Right Side Fall",
    "side fall right": "Right Side Fall",
    "fall_slump": "Slump Fall",
    "slump fall": "Slump Fall",
  };

  // Backend values are already "Stable"/"Unstable" (Title Case) per
  // Component 1's get_stability() — covered here with a safe fallback
  // in case that ever changes, same convention as fall type/activity.
  static const Map<String, String> _stabilityLabels = {
    "stable": "Stable",
    "unstable": "Unstable",
  };

  static const Map<String, String> _activityLabels = {
    "walk": "Walking",
    "walking": "Walking",
    "stand": "Standing",
    "standing": "Standing",
    "sit": "Sitting",
    "sitting": "Sitting",
    "lie_down": "Lying Down",
    "lying down": "Lying Down",
    "bend": "Bending",
    "bending": "Bending",
    "stair_case": "Staircase",
  };

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
    // FIX: overlapping-request guard — a slow request in flight blocks
    // the next scheduled poll (and a manual pull-to-refresh) instead of
    // both racing to setState().
    if (_fetchInProgress) return;
    _fetchInProgress = true;
    try {
      final res = await ApiService.instance.getFallLatest();
      if (!mounted) return;
      setState(() {
        // FIX: a transient error no longer wipes the last known good
        // detection result — only a successful response replaces it.
        _result = res["result"];
        _error = null;
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

  String _titleCase(String raw) {
    return raw
        .split(RegExp(r'[_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  // Unknown/unseen values are converted safely via title-case rather
  // than crashing or being hidden — never invents a DIFFERENT fall
  // type/activity than what the backend actually returned.
  String _humanizeFallType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Fall type unavailable";
    final key = raw.trim().toLowerCase();
    return _fallTypeLabels[key] ?? _titleCase(raw);
  }

  String _humanizeActivity(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Activity unavailable";
    final key = raw.trim().toLowerCase();
    return _activityLabels[key] ?? _titleCase(raw);
  }

  // Preserved label for risk level (semantic color still keys off the
  // raw LOW/MEDIUM/HIGH/CRITICAL via AppColors.severity() — unchanged).
  String _humanizeRiskLevel(String? raw) {
    switch ((raw ?? "").trim().toUpperCase()) {
      case "LOW":
        return "Low";
      case "MEDIUM":
        return "Medium";
      case "HIGH":
        return "High";
      case "CRITICAL":
        return "Critical";
      default:
        return "Unavailable";
    }
  }

  // UI REDESIGN: short word for the small status pill shown beside the
  // Risk Level tile (mockup: "Safe" / "Warning" / "High Risk" style
  // badge). Derived from the exact same real risk_level — never a
  // separate/hardcoded signal.
  String _riskPillLabel(String? raw) {
    switch ((raw ?? "").trim().toUpperCase()) {
      case "LOW":
        return "Safe";
      case "MEDIUM":
        return "Caution";
      case "HIGH":
        return "High Risk";
      case "CRITICAL":
        return "Critical";
      default:
        return "";
    }
  }

  // Reads the real `stability` field now forwarded by
  // component1_adapter.py / component1_router.py (delivered alongside
  // this screen fix — see this class's doc comment). Still fully
  // defensive: if that backend update hasn't been applied in your
  // project yet, `result["stability"]` simply won't be present, and
  // this honestly falls back to "Unavailable" rather than guessing — it
  // never crashes either way.
  String _humanizeStability(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "Unavailable";
    final key = raw.trim().toLowerCase();
    return _stabilityLabels[key] ?? "Unavailable";
  }

  // UI REDESIGN: short pill word next to the Stability tile (mockup:
  // "Normal" beside "Stable"). Derived from the same real stability
  // value — empty string (no pill shown) when stability is unavailable,
  // never fabricated.
  String _stabilityPillLabel(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "";
    switch (raw.trim().toLowerCase()) {
      case "stable":
        return "Normal";
      case "unstable":
        return "Alert";
      default:
        return "";
    }
  }

  String _formatClock(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? "AM" : "PM";
    return "$h:$m $ampm";
  }

  // `sample_time` is Component 1's processing/result timestamp — the
  // moment it produced this inference — not a verified record of the
  // exact physical instant of a fall. Only ever built from the real
  // `sample_time` field; DateTime.now() is used ONLY to compute the
  // age of an already-valid parsed timestamp, never as a fallback value.
  String? _relativeTime(DateTime? parsed) {
    if (parsed == null) return null;
    final diff = DateTime.now().difference(parsed);
    if (diff.isNegative || diff.inSeconds < 10) return "just now";
    if (diff.inSeconds < 60) return "${diff.inSeconds} sec ago";
    if (diff.inMinutes < 60) return "${diff.inMinutes} min ago";
    if (diff.inHours < 24) return "${diff.inHours} hr ago";
    if (diff.inDays == 1) return "yesterday, ${_formatClock(parsed)}";
    if (diff.inDays < 7) return "${diff.inDays} days ago";
    return "on ${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}";
  }

  // Used by the stale-result banner / connection-lost banner, which
  // need the fuller "Result updated ..." phrasing for clarity in those
  // contexts (unchanged wording/behavior from before this redesign).
  String _resultUpdatedLabel(DateTime? parsed) {
    final rel = _relativeTime(parsed);
    if (rel == null) return "Result update time unavailable";
    return "Result updated $rel";
  }

  // UI REDESIGN: the Last Updated card's own value line, matching the
  // Environment screen's "Updated X ago" wording exactly (mockup:
  // "Updated just now" / "Updated 18 min ago") — same real `sample_time`
  // source as _resultUpdatedLabel above, only the phrasing differs for
  // this specific card.
  String _lastUpdatedCardLabel(DateTime? parsed) {
    final rel = _relativeTime(parsed);
    if (rel == null) return "Update time unavailable";
    return "Updated $rel";
  }

  // DOCUMENTED LIMITATION (same pattern as Environment/Vitals): this is
  // a client-side freshness heuristic (3x this screen's own poll
  // interval), NOT a backend medical/ML validity threshold. It never
  // implies the sensor is disconnected, and a stale fall_detected=true
  // result is never presented as "still happening now" — only as a
  // detection that occurred at the shown time, which may be outdated.
  bool _isStale(DateTime? parsed) {
    if (parsed == null) return false;
    return DateTime.now().difference(parsed) > AppConfig.pollInterval * 3;
  }

  @override
  Widget build(BuildContext context) {
    final hasPriorResult = _result != null;
    final showFullScreenError = _error != null && !hasPriorResult;

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Fall Detection"),
      body: _loading
          ? const LoadingState(message: "Loading current detection...")
          : showFullScreenError
              ? ErrorStateView(
                  message:
                      "Unable to load fall detection data.\nPlease check the sensor or connection and try again.",
                  onRetry: _fetch,
                )
              : !hasPriorResult
                  ? _NoDataState(onRefresh: _fetch)
                  : _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final result = _result!;

    // Tri-state: a result that genuinely omits fall_detected is kept
    // distinct from an explicit `false` — in this architecture Component
    // 1 always sets it once a prediction exists, but this guards against
    // a malformed/partial payload without fabricating a verdict.
    final fallDetectedRaw = result["fall_detected"];
    final fallKnown = fallDetectedRaw is bool;
    final fallDetected = fallDetectedRaw == true;

    final fallType = result["fall_type"]?.toString();
    final riskLevel = result["risk_level"]?.toString();
    final movement = result["movement"]?.toString();
    final stability = result["stability"]?.toString();
    final explanation = result["explanation"]?.toString();

    final sampleTimeParsed =
        DateTime.tryParse(result["sample_time"]?.toString() ?? "");
    final stale = _isStale(sampleTimeParsed);
    final resultUpdatedLabel = _resultUpdatedLabel(sampleTimeParsed);
    final lastUpdatedCardLabel = _lastUpdatedCardLabel(sampleTimeParsed);

    // UI REDESIGN: wide-viewport (web/tablet) content is centered and
    // capped at a readable column width, matching the Environment
    // screen's responsive treatment — a phone-width screen sees no
    // change (contentWidth just equals the full available width).
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth =
            constraints.maxWidth > 640 ? 640.0 : constraints.maxWidth;
        return RefreshIndicator(
          onRefresh: _fetch,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: contentWidth,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.xl),
                children: [
                  Text("Fall Detection Monitoring",
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    "Real-time detection of falls and movement patterns.",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  if (_error != null && _result != null) ...[
                    ConnectionLostBanner(
                      lastUpdatedLabel: resultUpdatedLabel,
                      onRetry: _fetch,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],

                  _FallStatusCard(
                    fallKnown: fallKnown,
                    fallDetected: fallDetected,
                    fallTypeLabel: _humanizeFallType(fallType),
                    riskLevelRaw: riskLevel,
                    riskLabel: _humanizeRiskLevel(riskLevel),
                    riskColor: AppColors.severity(riskLevel),
                    resultUpdatedLabel: resultUpdatedLabel,
                    stale: stale,
                  ),

                  const SizedBox(height: AppSpacing.lg),
                  _DetectionDetailsCard(
                    fallTypeLabel: _humanizeFallType(fallType),
                    riskLabel: _humanizeRiskLevel(riskLevel),
                    riskColor: AppColors.severity(riskLevel),
                    riskPillLabel: _riskPillLabel(riskLevel),
                    activityLabel: _humanizeActivity(movement),
                    stabilityLabel: _humanizeStability(stability),
                    stabilityPillLabel: _stabilityPillLabel(stability),
                  ),

                  const SizedBox(height: AppSpacing.lg),
                  _LastUpdatedCard(
                    valueLabel: lastUpdatedCardLabel,
                    stale: stale,
                    onRefresh: _fetch,
                  ),

                  if (explanation != null &&
                      explanation.trim().isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.info_outline,
                                    size: 18, color: AppColors.primary),
                                const SizedBox(width: 6),
                                Text("Why this status?",
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(explanation,
                                style: Theme.of(context).textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: AppSpacing.lg),
                  const _AboutFallDetectionCard(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Main fall-status card. Fall-detected state is the one thing the
/// headline asserts; risk level/fall type are shown as separate,
/// clearly labeled facts rather than folded into one sentence.
///
/// Stale-result clarity (preserved from before this redesign): a stale
/// `fall_detected=true` result never looks identical to a fresh one —
/// the backend result itself is NEVER altered or suppressed (
/// fallDetected stays exactly what the API said); only the presentation
/// makes clear the result may be old.
class _FallStatusCard extends StatelessWidget {
  final bool fallKnown;
  final bool fallDetected;
  final String fallTypeLabel;
  final String? riskLevelRaw;
  final String riskLabel;
  final Color riskColor;
  final String resultUpdatedLabel;
  final bool stale;

  const _FallStatusCard({
    required this.fallKnown,
    required this.fallDetected,
    required this.fallTypeLabel,
    required this.riskLevelRaw,
    required this.riskLabel,
    required this.riskColor,
    required this.resultUpdatedLabel,
    required this.stale,
  });

  // UI REDESIGN: derived, not hardcoded — low/unknown risk reads as
  // "Normal Activity"; an elevated risk alongside "no fall" is shown
  // as such rather than defaulting every no-fall result to "normal".
  String get _noFallSubStatus {
    switch ((riskLevelRaw ?? "").trim().toUpperCase()) {
      case "MEDIUM":
        return "Caution";
      case "HIGH":
      case "CRITICAL":
        return "Elevated Risk";
      default:
        return "Normal Activity";
    }
  }

  Color get _noFallSubStatusColor {
    switch ((riskLevelRaw ?? "").trim().toUpperCase()) {
      case "MEDIUM":
      case "HIGH":
      case "CRITICAL":
        return riskColor;
      default:
        return AppColors.safe;
    }
  }

  String get _noFallMessage {
    switch ((riskLevelRaw ?? "").trim().toUpperCase()) {
      case "MEDIUM":
      case "HIGH":
      case "CRITICAL":
        return "The system has not detected any fall, but the current risk level is elevated.";
      default:
        return "The system has not detected any fall. Elder is safe and active.";
    }
  }

  Widget _statusPill(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontWeight: FontWeight.w800, fontSize: 13),
      ),
    );
  }

  Widget _staleNote(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 14, color: AppColors.warning),
          const SizedBox(width: 4),
          Text(
            "Data may be outdated",
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.warning, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Unknown status: explicitly does not assume safety.
    if (!fallKnown) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.help_outline,
                    size: 32, color: AppColors.textSecondary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Status Unavailable",
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      "Fall detection status could not be determined. Do not assume the elder is safe.",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(resultUpdatedLabel,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              _statusPill(context, "UNAVAILABLE", AppColors.textSecondary),
            ],
          ),
        ),
      );
    }

    if (fallDetected) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.emergencyLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.warning_amber_rounded,
                    size: 32, color: AppColors.emergency),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // A stale alert is never headlined the same as a
                      // fresh one — "Fall Detected" implies an active,
                      // current alert; "Fall Detection Result" is
                      // accurate for an old one.
                      stale ? "Fall Detection Result" : "Fall Detected",
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Row(
                      children: [
                        const Icon(Icons.circle,
                            size: 8, color: AppColors.emergency),
                        const SizedBox(width: 6),
                        Text(fallTypeLabel,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      "A fall was detected. Please check on the elder immediately.",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (riskLevelRaw != null && riskLevelRaw!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text("Risk: $riskLabel",
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: riskColor,
                                  fontWeight: FontWeight.w700)),
                    ],
                    if (stale) _staleNote(context),
                    const SizedBox(height: AppSpacing.sm),
                    Text(resultUpdatedLabel,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              _statusPill(context, "ALERT", AppColors.emergency),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.safeLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.directions_walk_rounded,
                  size: 32, color: AppColors.safe),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("No Fall Detected",
                      style: Theme.of(context).textTheme.titleLarge),
                  Row(
                    children: [
                      Icon(Icons.circle,
                          size: 8, color: _noFallSubStatusColor),
                      const SizedBox(width: 6),
                      Text(_noFallSubStatus,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                  color: _noFallSubStatusColor,
                                  fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(_noFallMessage,
                      style: Theme.of(context).textTheme.bodyMedium),
                  if (stale) _staleNote(context),
                  const SizedBox(height: AppSpacing.sm),
                  Text(resultUpdatedLabel,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            _statusPill(context, "SAFE", AppColors.safe),
          ],
        ),
      ),
    );
  }
}

/// Detection Details card — Fall Type / Risk Level / Current Activity /
/// Stability as four tiles in a responsive 2-column grid, styled like
/// the Environment screen's metric tiles (pastel icon circle, label,
/// bold value, optional small status pill).
class _DetectionDetailsCard extends StatelessWidget {
  final String fallTypeLabel;
  final String riskLabel;
  final Color riskColor;
  final String riskPillLabel;
  final String activityLabel;
  final String stabilityLabel;
  final String stabilityPillLabel;

  const _DetectionDetailsCard({
    required this.fallTypeLabel,
    required this.riskLabel,
    required this.riskColor,
    required this.riskPillLabel,
    required this.activityLabel,
    required this.stabilityLabel,
    required this.stabilityPillLabel,
  });

  Color get _stabilityColor {
    switch (stabilityLabel) {
      case "Stable":
        return AppColors.safe;
      case "Unstable":
        return AppColors.emergency;
      default:
        return AppColors.textSecondary;
    }
  }

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
                Text("Detection Details",
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // FIX (lesson from the Environment-screen crash): these Rows
            // intentionally do NOT set crossAxisAlignment: stretch — a
            // Row can only stretch children when its own height is
            // bounded, and inside this Card's Column (inside a
            // scrollable ListView) that height is unbounded, which
            // throws "BoxConstraints forces an infinite height". Tiles
            // just size to their own content instead; harmless if one
            // tile ends up a few pixels taller than its neighbor.
            Row(
              children: [
                Expanded(
                  child: _tile(
                    context,
                    icon: Icons.directions_run_rounded,
                    iconColor: const Color(0xFF8B5CF6),
                    label: "Fall Type",
                    value: fallTypeLabel,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _tile(
                    context,
                    icon: Icons.bar_chart_rounded,
                    iconColor: riskColor,
                    label: "Risk Level",
                    value: riskLabel,
                    pillLabel: riskPillLabel,
                    pillColor: riskColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _tile(
                    context,
                    icon: Icons.directions_walk_rounded,
                    iconColor: const Color(0xFF3B82F6),
                    label: "Current Activity",
                    value: activityLabel,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _tile(
                    context,
                    icon: Icons.verified_user_outlined,
                    iconColor: _stabilityColor,
                    label: "Stability",
                    value: stabilityLabel,
                    pillLabel: stabilityPillLabel,
                    pillColor: _stabilityColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    String pillLabel = "",
    Color? pillColor,
  }) {
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
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  value,
                  softWrap: true,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontSize: 16),
                ),
              ),
              if (pillLabel.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (pillColor ?? AppColors.primary)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    pillLabel,
                    style: TextStyle(
                      color: pillColor ?? AppColors.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Last Updated card — real `sample_time`-derived label, a stale
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

/// Static informational card (no backend data) — explicitly does not
/// claim an alert was delivered; the system's actual alert logic is
/// elsewhere.
class _AboutFallDetectionCard extends StatelessWidget {
  const _AboutFallDetectionCard();

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
                Text("About Fall Detection",
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: AppColors.primaryDark)),
                const SizedBox(height: 4),
                Text(
                  "The system analyzes movement patterns to help detect falls. "
                  "Alerts are generated according to the system's configured "
                  "alert logic.",
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

/// Professional "no data yet" state — explicitly NOT "no fall
/// detected": the system simply hasn't received a Component 1 reading
/// at all yet, which is a different fact from "monitored and safe".
class _NoDataState extends StatelessWidget {
  final Future<void> Function() onRefresh;
  const _NoDataState({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.xxxl),
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xxxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hourglass_empty,
                      size: 40, color: AppColors.textSecondary),
                  const SizedBox(height: AppSpacing.lg),
                  Text("No current detection data",
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    "The system has not received a current Component 1 reading yet.",
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  OutlinedButton.icon(
                    onPressed: () => onRefresh(),
                    icon: const Icon(Icons.refresh),
                    label: const Text("Refresh"),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
