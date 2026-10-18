import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

/// Deliberately minimal — no confidence %, no probability breakdown,
/// and no "Call" button (per decision: an emergency contact calling
/// a high-risk fall patient directly isn't a good idea — see
/// conversation notes). "Get Directions" uses the elder's home
/// address (elders.address) since the backend has no GPS/location
/// coordinates, only a room-name string per sensor zone.
///
/// HARDENING / FINAL REVIEW PASS (per the "Emergency Alert Detail
/// Screen – COMPLETE UI/UX + FUNCTIONAL + SAFETY + RESPONSIVENESS"
/// prompt) fixed the following real issues found on audit:
///   - Fall Type / Location were shown as raw backend strings
///     ("fall_forward", "stair_case", or "-" when missing) instead of
///     humanized text — fixed via _humanizeFallType()/_humanizeLocation().
///   - Missing fields fell back to a bare "-", which reads as a glitch
///     in an emergency context — replaced with explicit "X unavailable"
///     text everywhere (fall type, location, time, address).
///   - The home address was crammed into the button label
///     ("Get Directions · <address>"), which both looks cluttered and
///     truncates on small phones — the address is now its own row
///     above a plain "Get Directions" button.
///   - Tapping Get Directions with no address, or a Maps launch that
///     silently fails, did nothing visible — the button is now
///     disabled with "Home address unavailable" text when there's no
///     address, and a launch failure shows a friendly SnackBar instead
///     of failing silently.
///   - Fall Type/Location values sat directly in a Row with no
///     Flexible/Expanded, so a long value could overflow on a narrow
///     phone — wrapped for safe wrapping.
/// No architecture change: still receives the same
/// Map<String, dynamic> alert / String elderName / String? elderAddress,
/// no new backend call, no new Alert model, Components 1-4 untouched.
class EmergencyAlertDetailScreen extends StatelessWidget {
  final Map<String, dynamic> alert;
  final String elderName;
  final String? elderAddress;

  const EmergencyAlertDetailScreen({
    super.key,
    required this.alert,
    required this.elderName,
    this.elderAddress,
  });

  bool _hasValue(dynamic v) => v != null && v.toString().trim().isNotEmpty;

  // Only ever returns a known, explicit mapping or the honest
  // "unavailable" fallback — never title-cases an unrecognized raw
  // backend string and presents it as if it were a real fall type.
  String _humanizeFallType(dynamic raw) {
    if (!_hasValue(raw)) return "Fall type unavailable";
    final value = raw.toString().trim();
    const alreadyHumanized = {
      "Forward Fall",
      "Backward Fall",
      "Side Fall Left",
      "Side Fall Right",
      "No Fall",
    };
    if (alreadyHumanized.contains(value)) return value;
    const rawKeyMap = {
      "fall_forward": "Forward Fall",
      "fall_backward": "Backward Fall",
      "fall_side_left": "Side Fall Left",
      "fall_side_right": "Side Fall Right",
      "side_fall_left": "Side Fall Left",
      "side_fall_right": "Side Fall Right",
    };
    return rawKeyMap[value.toLowerCase()] ?? "Fall type unavailable";
  }

  // Sensor room location (NOT the elder's home address — kept as a
  // separate concept per the prompt). If it isn't one of the known raw
  // sensor keys, the backend likely already sent a readable value, so
  // it's shown as-is rather than invented or discarded.
  String _humanizeLocation(dynamic raw) {
    if (!_hasValue(raw)) return "Location unavailable";
    final value = raw.toString().trim();
    const rawKeyMap = {
      "stair_case": "Staircase",
      "living_room": "Living Room",
      "bed_room": "Bedroom",
      "bath_room": "Bathroom",
      "kitchen": "Kitchen",
      "dining_room": "Dining Room",
    };
    return rawKeyMap[value.toLowerCase()] ?? value;
  }

  // Never falls back to DateTime.now() or a fabricated time — only a
  // real, successfully-parsed created_at, or an honest "unavailable".
  String _formatTimestamp(dynamic raw) {
    if (!_hasValue(raw)) return "Time unavailable";
    final dt = DateTime.tryParse(raw.toString());
    if (dt == null) return "Time unavailable";
    return DateFormat("MMM d, yyyy · h:mm a").format(dt.toLocal());
  }

  Future<void> _openDirections(BuildContext context) async {
    if (!_hasValue(elderAddress)) return;
    try {
      final query = Uri.encodeComponent(elderAddress!.trim());
      final uri =
          Uri.parse("https://www.google.com/maps/search/?api=1&query=$query");
      final canLaunch = await canLaunchUrl(uri);
      final launched = canLaunch &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) _showMapsError(context);
    } catch (_) {
      // Never surface a raw platform/URI exception to the user.
      _showMapsError(context);
    }
  }

  void _showMapsError(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              "Unable to open maps. Please use the home address shown above.")),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm, top: AppSpacing.lg),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.5),
        ),
      );

  Widget _detailRow(
      BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.left,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = elderName.trim().isEmpty
        ? "Elder information unavailable"
        : elderName.trim();
    final fallType = _humanizeFallType(alert["fall_type"]);
    final location = _humanizeLocation(alert["location"]);
    final time = _formatTimestamp(alert["created_at"]);
    final reasoning = _hasValue(alert["explanation"])
        ? alert["explanation"].toString().trim()
        : "No additional explanation available.";
    final hasAddress = _hasValue(elderAddress);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const AegisAppBar(showLogo: false, title: "Emergency Alert"),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            // EMERGENCY HEADER — the emergency state is communicated by
            // icon + text + a controlled accent color, never by making
            // the whole screen red (prompt sections 5/6).
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                color: AppColors.criticalLight,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.critical, width: 1.5),
              ),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                        color: AppColors.emergencyLight,
                        shape: BoxShape.circle),
                    child: const Icon(Icons.warning_amber_rounded,
                        size: 30, color: AppColors.critical),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    "EMERGENCY ALERT",
                    style: TextStyle(
                        color: AppColors.critical,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    displayName,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontSize: 22, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    "Immediate assistance required",
                    style: TextStyle(
                        color: AppColors.critical,
                        fontWeight: FontWeight.w600,
                        fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.xl),

            // FALL DETAILS — plain white card, deliberately quieter
            // than the emergency header above.
            _sectionLabel("Fall Details"),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    _detailRow(context, Icons.accessibility_new, "Fall Type",
                        fallType),
                    const Divider(height: 1),
                    _detailRow(context, Icons.location_on_outlined, "Location",
                        location),
                    const Divider(height: 1),
                    _detailRow(context, Icons.schedule_outlined, "Time", time),
                  ],
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.xl),

            // WHY THIS ALERT — only ever the real backend explanation,
            // or an honest "none available" line. Never fabricated.
            _sectionLabel("Why This Alert"),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        color: AppColors.textSecondary, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        reasoning,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.xl),

            // HOME LOCATION — the elder's registered address, kept
            // conceptually separate from the sensor room location
            // above. Address is shown in full, outside the button, and
            // allowed to wrap across lines (prompt sections 13/34).
            _sectionLabel("Home Location"),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.home_outlined,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    hasAddress
                        ? elderAddress!.trim()
                        : "Home address unavailable",
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: hasAddress ? () => _openDirections(context) : null,
                icon: const Icon(Icons.map_outlined),
                label: const Text("Get Directions",
                    style: TextStyle(fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary, width: 1.5),
                  disabledForegroundColor: AppColors.textSecondary,
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.xl),

            // EMERGENCY DISCLAIMER — subtle warning background, not a
            // dominant red card (prompt section 18).
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline,
                      size: 18, color: AppColors.warning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "If this is a life-threatening emergency, contact local emergency services immediately.",
                      style: Theme.of(context).textTheme.bodyMedium,
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
