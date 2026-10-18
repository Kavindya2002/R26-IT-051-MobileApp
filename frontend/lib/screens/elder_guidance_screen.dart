import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/guidance_state.dart';
import '../theme/app_theme.dart';

/// Full-screen, elder-facing recovery guidance.
///
/// Design choices (see conversation notes):
/// - ONE step at a time, large text — not a scrollable list, to keep
///   cognitive load low right after a fall.
/// - TTS speaks every step automatically; the elder does not need to
///   read or even hold the phone up.
/// - Calm palette (soft teal/blue) — deliberately avoids red or
///   flashing colors that could raise anxiety right after a fall.
/// - A big, always-visible "I Need Help Now" button skips guidance
///   entirely and escalates immediately.
/// - A countdown ring shows how long until auto-escalation if there
///   is no interaction — visible but not alarming.
class ElderGuidanceScreen extends StatelessWidget {
  const ElderGuidanceScreen({super.key});

  static const _calmBackground = AppColors.primaryLight;
  static const _calmAccent = AppColors.primary;

  @override
  Widget build(BuildContext context) {
    return Consumer<GuidanceState>(
      builder: (context, guidance, _) {
        if (guidance.status == GuidanceStatus.escalated) {
          return _EscalatedView(elderName: guidance.elderName);
        }
        if (guidance.status == GuidanceStatus.completed) {
          return const _CompletedView();
        }
        if (guidance.status != GuidanceStatus.active ||
            guidance.steps.isEmpty) {
          return const Scaffold(
            body: Center(child: Text("No active guidance.")),
          );
        }

        final progress = (guidance.currentStepIndex + 1) / guidance.totalSteps;
        final timeoutProgress =
            guidance.secondsRemaining / kGuidanceTimeout.inSeconds;

        return Scaffold(
          backgroundColor: _calmBackground,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Step progress (e.g. "Step 2 of 5")
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Step ${guidance.currentStepIndex + 1} of ${guidance.totalSteps}",
                        style: const TextStyle(
                            fontSize: 16,
                            color: Colors.black54,
                            fontWeight: FontWeight.w600),
                      ),
                      // Subtle countdown indicator — informative, not alarming
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          value: timeoutProgress.clamp(0.0, 1.0),
                          strokeWidth: 3,
                          backgroundColor: Colors.black12,
                          valueColor: const AlwaysStoppedAnimation(_calmAccent),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: Colors.black12,
                    valueColor: const AlwaysStoppedAnimation(_calmAccent),
                  ),

                  // The single current instruction, large and centered
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.self_improvement,
                              size: 56, color: _calmAccent),
                          const SizedBox(height: 24),
                          Text(
                            guidance.currentStepText,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 20),
                          TextButton.icon(
                            onPressed: guidance.repeatCurrentStep,
                            icon:
                                const Icon(Icons.volume_up, color: _calmAccent),
                            label: const Text("Repeat",
                                style: TextStyle(
                                    color: _calmAccent, fontSize: 16)),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Primary action — big, thumb-friendly
                  SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: ElevatedButton(
                      onPressed: guidance.nextStep,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _calmAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        guidance.isLastStep ? "I'm OK Now" : "Next Step",
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Always-visible emergency escape hatch
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      onPressed: guidance.manualEscalate,
                      icon: const Icon(Icons.warning_amber_rounded,
                          color: AppColors.emergency),
                      label: const Text(
                        "I Need Help Now",
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.emergency),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: AppColors.emergency, width: 1.5),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EscalatedView extends StatelessWidget {
  final String elderName;
  const _EscalatedView({required this.elderName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.emergencyLight,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.phone_forwarded,
                    size: 72, color: AppColors.emergency),
                const SizedBox(height: 24),
                const Text(
                  "Your caregiver has been alerted",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Help is on the way. Stay where you are and stay calm.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompletedView extends StatelessWidget {
  const _CompletedView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryLight,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.check_circle, size: 72, color: AppColors.secondaryTeal),
            SizedBox(height: 16),
            Text("Glad you're okay.",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text("Your caregiver can still see this recovery in your history.",
                style: TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}
