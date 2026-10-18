import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/guidance_state.dart';
import '../theme/app_theme.dart';

/// Read-only mirror of the elder's guidance progress, meant to sit on
/// the Caregiver Home Dashboard. It never controls the elder's flow —
/// it only reflects it — plus a one-tap "Call Elder" fallback in case
/// the caregiver wants to intervene directly instead of waiting.
///
/// HARDENING PASS (final review):
///   - Progress value could previously divide by zero / go out of
///     [0.0, 1.0] if totalSteps was ever 0 or currentStepIndex was out
///     of range. Now computed through a safe helper that always
///     returns a value in range and never NaN/Infinity.
///   - currentStepIndex/currentStepText are now validated before
///     display — an out-of-range index or missing step text shows an
///     honest "Current guidance step unavailable" instead of a
///     garbled or blank line.
///   - elderName falls back to "This elder" instead of producing
///     " is following recovery guidance" when empty.
///   - Call Elder now guards against rapid double-taps, trims/
///     validates the phone number, and gives distinct friendly
///     feedback for "can't launch" vs. "launch threw" rather than
///     silently doing nothing.
/// Converted to a StatefulWidget only to hold the local `_calling`
/// guard — it introduces no guidance control of any kind. GuidanceState
/// remains the sole source of truth and this widget never starts,
/// advances, repeats, completes, or escalates guidance.
class CaregiverGuidanceMirrorCard extends StatefulWidget {
  // Nullable and honest: when null/empty, the Call button is replaced
  // with "No phone number available" rather than silently calling a
  // fake or hardcoded number.
  final String? elderPhoneNumber;

  const CaregiverGuidanceMirrorCard({super.key, this.elderPhoneNumber});

  @override
  State<CaregiverGuidanceMirrorCard> createState() =>
      _CaregiverGuidanceMirrorCardState();
}

class _CaregiverGuidanceMirrorCardState
    extends State<CaregiverGuidanceMirrorCard> {
  bool _calling = false;

  String _safeElderName(String? raw) {
    final name = raw?.trim() ?? "";
    return name.isEmpty ? "This elder" : name;
  }

  // Always in [0.0, 1.0], never NaN/Infinity/negative — totalSteps <= 0
  // (or any other degenerate input) safely yields 0.0 instead of
  // dividing by zero.
  double _safeProgress(GuidanceState guidance) {
    final totalSteps = guidance.totalSteps;
    final currentStep = guidance.currentStepIndex + 1;
    if (totalSteps <= 0) return 0.0;
    return (currentStep / totalSteps).clamp(0.0, 1.0);
  }

  // Never fabricates a step number — an out-of-range index just means
  // there is nothing safe to show, not a guessed one.
  String? _safeStepLabel(GuidanceState guidance) {
    final totalSteps = guidance.totalSteps;
    final index = guidance.currentStepIndex;
    if (totalSteps <= 0 || index < 0 || index >= totalSteps) return null;
    return "Step ${index + 1} of $totalSteps";
  }

  String _safeStepText(GuidanceState guidance) {
    final totalSteps = guidance.totalSteps;
    final index = guidance.currentStepIndex;
    if (totalSteps <= 0 || index < 0 || index >= totalSteps) {
      return "Current guidance step unavailable";
    }
    final text = guidance.currentStepText.trim();
    return text.isEmpty ? "Current guidance step unavailable" : text;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _callElder() async {
    if (_calling) return;
    final phone = widget.elderPhoneNumber?.trim();
    if (phone == null || phone.isEmpty) return;

    setState(() => _calling = true);
    try {
      final uri = Uri(scheme: "tel", path: phone);
      final canLaunch = await canLaunchUrl(uri);
      if (!canLaunch) {
        _showMessage("Unable to open the phone app.");
        return;
      }
      final launched = await launchUrl(uri);
      if (!launched) {
        _showMessage("Unable to open the phone app.");
      }
    } catch (_) {
      // Never surface e.toString() to the caregiver, and never claim
      // the call was completed when launching it failed.
      _showMessage("Unable to start the call.");
    } finally {
      if (mounted) setState(() => _calling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GuidanceState>(
      builder: (context, guidance, _) {
        if (guidance.status == GuidanceStatus.inactive) {
          return const SizedBox.shrink(); // nothing to mirror right now
        }

        final elderName = _safeElderName(guidance.elderName);
        final isEscalated = guidance.status == GuidanceStatus.escalated;
        final isCompleted = guidance.status == GuidanceStatus.completed;
        final color = isEscalated
            ? Colors.redAccent
            : isCompleted
                ? AppColors.safe
                : AppColors.primary;

        final phone = widget.elderPhoneNumber?.trim();
        final hasPhone = phone != null && phone.isNotEmpty;

        final stepLabel = _safeStepLabel(guidance);
        final stepText = _safeStepText(guidance);

        return Card(
          color: color.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: color.withValues(alpha: 0.4)),
          ),
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isEscalated
                          ? Icons.warning_amber_rounded
                          : isCompleted
                              ? Icons.check_circle
                              : Icons.accessibility_new,
                      color: color,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isEscalated
                            ? "$elderName did not respond — escalated"
                            : isCompleted
                                ? "$elderName completed recovery guidance"
                                : "$elderName is following recovery guidance",
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: color),
                      ),
                    ),
                  ],
                ),
                // Surfaces the real connection state found during
                // escalation verification — if the backend call never
                // succeeded, no alert exists server-side, so the
                // caregiver needs to know this device's "escalated"
                // state may not be real/shared yet. Never invents
                // server confirmation, and never says "Emergency alert
                // sent" unless escalationConfirmed is actually true.
                if (isEscalated && !guidance.escalationConfirmed) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.warningLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.wifi_off,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "Escalation may not have reached the server yet — check connection.",
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (guidance.status == GuidanceStatus.active) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _safeProgress(guidance),
                    minHeight: 6,
                    backgroundColor: Colors.black12,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    stepLabel != null ? "$stepLabel: \"$stepText\"" : stepText,
                    style: const TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: !hasPhone
                      ? OutlinedButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.phone_disabled),
                          label: const Text("No phone number available"),
                        )
                      : OutlinedButton.icon(
                          onPressed: _calling ? null : _callElder,
                          icon: _calling
                              ? SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: color),
                                )
                              : Icon(Icons.call, color: color),
                          label: Text("Call $elderName",
                              style: TextStyle(color: color)),
                          style: OutlinedButton.styleFrom(
                              side: BorderSide(color: color)),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
