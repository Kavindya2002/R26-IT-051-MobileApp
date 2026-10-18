import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/elder.dart';
import '../models/guidance_state.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

/// Backend note: there is no standalone GET /elders/{id}/guidance
/// endpoint yet (see conversation notes — guidance is only returned
/// embedded in a live Component 4 response). This screen shows the
/// ACTIVE GuidanceState when a real fall event triggered it, and
/// falls back to the generic reference steps (guidance_steps.py's
/// "fall" entry) the rest of the time, clearly labelled as reference
/// content rather than a live session.
///
/// HARDENING PASS (final review):
///   - This screen previously collapsed every non-active status
///     (completed, escalated, AND inactive) into the same generic
///     reference-guidance view. A completed or escalated guidance
///     session was indistinguishable from "no session ever
///     happened" — both looked like static reference content. Now
///     each of the four GuidanceState statuses (active/completed/
///     escalated/inactive) gets its own explicit, clearly labelled
///     presentation, per the hardening prompt's state hierarchy.
///   - An ACTIVE session with null/empty steps used to render an
///     empty list silently (no cards, no explanation). Now shown as
///     an explicit "Live guidance steps are currently unavailable."
///     message — it is never silently backfilled with the generic
///     reference steps, since that would misrepresent reference
///     content as live backend guidance.
///   - Live steps are now filtered (null/empty/whitespace-only
///     removed) before display, preserving backend order, rather
///     than rendering a blank card for an empty entry.
///   - Fall type is now humanized through a single reusable helper
///     covering the full prompt-specified set (fall_forward/backward/
///     side_left/side_right/slump, bend/sit/stand/walk/lie_down, "No
///     Fall"), with an honest "Fall type unavailable" fallback
///     instead of ever showing a raw snake_case value.
/// No new API calls, no second WebSocket, no risk/fall calculation —
/// this remains a pure, read-only Consumer<GuidanceState> view. The
/// `elder` parameter is preserved on the public constructor even
/// though this screen doesn't currently need it for display, in case
/// navigation/future compatibility depends on it.
const List<String> _genericReferenceSteps = [
  "Stay calm and do not move suddenly.",
  "Check whether you can move your arms and legs.",
  "Slowly turn yourself into a comfortable position.",
  "Use nearby support if you need help maintaining balance.",
  "If you feel stable, slowly return to a sitting or standing position.",
];

// Single reusable humanization helper (prompt section 9) — only ever
// a known, explicit mapping or an honest "unavailable" fallback, never
// a guessed/title-cased raw value and never a raw snake_case string
// shown to the user.
String _humanizeFallType(dynamic raw) {
  if (raw == null) return "Fall type unavailable";
  final value = raw.toString().trim();
  if (value.isEmpty) return "Fall type unavailable";
  const alreadyHumanized = {
    "No Fall",
    "Forward Fall",
    "Backward Fall",
    "Left Side Fall",
    "Right Side Fall",
    "Slump Fall",
    "Bend",
    "Sitting",
    "Standing",
    "Walking",
    "Lying Down",
  };
  if (alreadyHumanized.contains(value)) return value;
  const rawKeyMap = {
    "fall_forward": "Forward Fall",
    "fall_backward": "Backward Fall",
    "fall_side_left": "Left Side Fall",
    "fall_side_right": "Right Side Fall",
    "fall_slump": "Slump Fall",
    "bend": "Bend",
    "sit": "Sitting",
    "stand": "Standing",
    "walk": "Walking",
    "lie_down": "Lying Down",
    "no_fall": "No Fall",
  };
  return rawKeyMap[value.toLowerCase()] ?? "Fall type unavailable";
}

// Preserves backend step order; only removes null/empty/whitespace-only
// entries (prompt section 10). Never invents or rewrites a step.
List<String> _validSteps(List<dynamic>? raw) {
  if (raw == null) return const [];
  return raw
      .map((e) => e?.toString().trim() ?? "")
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

class GuidanceSupportScreen extends StatelessWidget {
  final Elder elder;
  const GuidanceSupportScreen({super.key, required this.elder});

  @override
  Widget build(BuildContext context) {
    return Consumer<GuidanceState>(
      builder: (context, guidance, _) {
        final status = guidance.status;
        final isActive = status == GuidanceStatus.active;
        final isCompleted = status == GuidanceStatus.completed;
        final isEscalated = status == GuidanceStatus.escalated;

        final liveSteps =
            isActive ? _validSteps(guidance.steps) : const <String>[];
        // Only an ACTIVE session with at least one valid step counts as
        // genuinely "live" for display purposes — an active session
        // with no usable steps gets its own unavailable message
        // instead of ever falling back to the generic reference list
        // (prompt section 7/10/20).
        final hasLiveSteps = isActive && liveSteps.isNotEmpty;

        final String headerTitle;
        final String headerSubtitle;
        final IconData headerIcon;
        final Color headerColor;
        final Color headerBg;

        if (isActive) {
          headerTitle = "Live Guidance";
          headerSubtitle = hasLiveSteps
              ? "Guidance is currently active for this fall event."
              : "Live guidance steps are currently unavailable. Please follow the active alert instructions or wait for the next guidance update.";
          headerIcon = Icons.shield_outlined;
          headerColor = AppColors.low;
          headerBg = AppColors.lowLight;
        } else if (isCompleted) {
          headerTitle = "Guidance Completed";
          headerSubtitle = "The previous guidance session has been completed.";
          headerIcon = Icons.check_circle_outline;
          headerColor = AppColors.safe;
          headerBg = AppColors.safe.withValues(alpha: 0.12);
        } else if (isEscalated) {
          headerTitle = "Guidance Escalated";
          headerSubtitle =
              "The guidance session was escalated to the appropriate response flow.";
          headerIcon = Icons.warning_amber_rounded;
          headerColor = AppColors.warning;
          headerBg = AppColors.warningLight;
        } else {
          headerTitle = "Reference Guidance";
          headerSubtitle =
              "No active guidance session right now — general reference guidance is shown below.";
          headerIcon = Icons.info_outline;
          headerColor = AppColors.textMuted;
          headerBg = AppColors.surfaceMuted;
        }

        // Fall type badge: shown for any state where a real fall type
        // is actually associated with the event (active/completed/
        // escalated); plain "Reference" label when there's no real
        // event behind what's on screen at all.
        final fallTypeLabel = (isActive || isCompleted || isEscalated)
            ? _humanizeFallType(guidance.fallType)
            : "Reference";

        // Steps shown in the list below the status card:
        //   - active + valid steps   -> the real live steps
        //   - inactive                -> generic reference steps
        //   - active w/o valid steps,
        //     completed, escalated    -> no step list at all (avoids
        //     presenting stale/placeholder steps as if actionable)
        final List<String> displaySteps = hasLiveSteps
            ? liveSteps
            : (!isActive && !isCompleted && !isEscalated)
                ? _genericReferenceSteps
                : const <String>[];

        return Scaffold(
          appBar: AegisAppBar(showLogo: false, title: "Guidance Support"),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: AppColors.amberSoft,
                                  child: const Icon(Icons.menu_book_outlined,
                                      color: AppColors.medium, size: 20),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text("Guidance & Support",
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      Text("Recovery steps",
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text("Fall Type",
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(fontSize: 10)),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.purpleLight,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: AppColors.purple),
                                ),
                                child: Text(
                                  fallTypeLabel,
                                  style: const TextStyle(
                                      color: AppColors.purple,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: headerBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: headerColor),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(headerIcon, color: headerColor, size: 15),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    headerTitle,
                                    style: TextStyle(
                                        color: headerColor,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    headerSubtitle,
                                    style: TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ...displaySteps.asMap().entries.map((entry) {
                final index = entry.key;
                final step = entry.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: AppColors.accentBlue,
                            child: Text(
                              "${index + 1}",
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(step,
                                  style:
                                      Theme.of(context).textTheme.bodyLarge)),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          color: AppColors.info, size: 16),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Guidance is available only for low-risk detected falls. Higher-risk falls trigger a caregiver or emergency alert instead.",
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
