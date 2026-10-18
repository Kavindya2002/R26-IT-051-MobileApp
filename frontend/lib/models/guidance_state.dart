import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../services/api_service.dart';

/// How long the elder has to interact (tap Next / Help) before the
/// app treats them as unresponsive and auto-escalates to a
/// Caregiver/Emergency Alert.
const Duration kGuidanceTimeout = Duration(seconds: 45);

enum GuidanceStatus { inactive, active, escalated, completed }

/// Single shared source of truth for an active guidance session.
///
/// In production this state should be synced through the backend in
/// real time (e.g. Supabase Realtime / a WebSocket) so a caregiver's
/// phone reflects the elder's phone even across devices. This class
/// is written so that swapping the in-memory logic for a realtime
/// subscription later only touches `_pushRemoteUpdate()` /
/// `attachRemoteStream()` — the UI layer above never needs to change.
class GuidanceState extends ChangeNotifier {
  GuidanceState() {
    _tts.setLanguage("en-US");
    _tts.setSpeechRate(0.42); // slower, calmer pace for an elderly listener
    _tts.setPitch(1.0);
  }

  final FlutterTts _tts = FlutterTts();
  Timer? _timeoutTimer;
  Timer? _tickTimer;

  GuidanceStatus status = GuidanceStatus.inactive;
  List<String> steps = [];
  int currentStepIndex = 0; // 0-based
  String fallType = "";
  String elderId = "";
  String elderName = "";

  int _secondsRemaining = kGuidanceTimeout.inSeconds;
  int get secondsRemaining => _secondsRemaining;

  int get totalSteps => steps.length;
  String get currentStepText => steps.isEmpty ? "" : steps[currentStepIndex];
  bool get isLastStep => currentStepIndex >= steps.length - 1;

  /// Called when the backend result says guidance.enabled == true.
  /// (risk_level == LOW && fall_detected == true — see guidance_service.py)
  void startGuidance({
    required List<String> steps,
    required String fallType,
    required String elderId,
    required String elderName,
  }) {
    this.steps = steps;
    this.fallType = fallType;
    this.elderId = elderId;
    this.elderName = elderName;
    currentStepIndex = 0;
    status = GuidanceStatus.active;
    notifyListeners();

    _speakCurrentStep();
    _resetTimeoutTimer();
  }

  void _speakCurrentStep() {
    if (steps.isEmpty) return;
    _tts.stop();
    _tts.speak(currentStepText);
  }

  /// Elder tapped "Next Step" — counts as a sign of responsiveness,
  /// so the timeout resets.
  void nextStep() {
    if (status != GuidanceStatus.active) return;

    if (isLastStep) {
      status = GuidanceStatus.completed;
      _cancelTimers();
      _tts.stop();
      notifyListeners();
      return;
    }

    currentStepIndex++;
    notifyListeners();
    _speakCurrentStep();
    _resetTimeoutTimer();
  }

  void repeatCurrentStep() {
    _speakCurrentStep();
    _resetTimeoutTimer(); // manual interaction also counts as "responsive"
  }

  /// Elder pressed the big "I Need Help Now" button — skip guidance,
  /// escalate immediately regardless of timeout.
  Future<void> manualEscalate() async {
    await _escalate(reason: "elder_requested_help");
  }

  void _resetTimeoutTimer() {
    _cancelTimers();
    _secondsRemaining = kGuidanceTimeout.inSeconds;

    _tickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _secondsRemaining--;
      notifyListeners();
      if (_secondsRemaining <= 0) t.cancel();
    });

    _timeoutTimer = Timer(kGuidanceTimeout, () {
      _escalate(reason: "no_response_timeout");
    });
  }

  void _cancelTimers() {
    _timeoutTimer?.cancel();
    _tickTimer?.cancel();
  }

  // ADDED: tracks whether the escalate() call genuinely reached the
  // backend. Found during verification that a failed network call was
  // being silently swallowed — the elder's screen would show "help is
  // on the way" regardless, but if the server call never succeeded,
  // no alert row was ever created and the caregiver's app would never
  // learn about it at all. The elder-facing message is deliberately
  // left unchanged (showing a technical error to someone who may have
  // just fallen is the wrong call) — this flag instead lets the
  // caregiver-facing mirror card surface the real connection state,
  // which is where it actually matters.
  bool escalationConfirmed = false;

  // ADDED (real sensor-based guidance step advancement): a short,
  // honest status line derived directly from the backend's own
  // IMU-stability status string (see syncStepFromSensor below). Null
  // until the backend sends a real status.
  String? sensorHint;

  Future<void> _escalate({required String reason}) async {
    if (status == GuidanceStatus.escalated ||
        status == GuidanceStatus.completed) return;

    _cancelTimers();
    status = GuidanceStatus.escalated;
    escalationConfirmed = false;
    notifyListeners();

    _tts.stop();
    await _tts.speak("Alerting your caregiver now. Help is on the way.");

    try {
      await ApiService.instance.escalate(
        elderId: elderId,
        reason: reason,
        fallType: fallType.isEmpty ? "fall" : fallType,
      );
      escalationConfirmed = true;
    } catch (e) {
      debugPrint("Escalation call failed: $e");
      // Deliberately NOT reverting `status` — the elder still sees
      // the calm "escalated" view rather than a confusing error mid
      // emergency. escalationConfirmed stays false so the caregiver
      // side (not the elder side) can show the real connection state.
    }
    notifyListeners();
  }

  /// ADDED (real sensor-based guidance step advancement): called with
  /// the backend's own validated IMU-stability status/current_step
  /// (see guidance_progress message / StepValidator on the backend).
  /// This does not invent any validation logic of its own -- it only
  /// reflects what the backend already decided: advance the step if
  /// the backend says a later step is confirmed, and show an honest,
  /// literal status hint rather than a fabricated category.
  void syncStepFromSensor({
    required int? backendCurrentStep,
    required String backendStatus,
  }) {
    if (status != GuidanceStatus.active) return;

    sensorHint = _humanizeSensorStatus(backendStatus);

    if (backendCurrentStep != null &&
        backendCurrentStep != currentStepIndex &&
        backendCurrentStep >= 0 &&
        backendCurrentStep < steps.length) {
      currentStepIndex = backendCurrentStep;
      notifyListeners();
      _speakCurrentStep();
      _resetTimeoutTimer();
    } else {
      notifyListeners();
    }
  }

  /// Turns the backend's raw status string (e.g. "still_moving") into
  /// a readable label without guessing at meanings this app hasn't
  /// been told -- plain formatting only, no invented categories.
  String? _humanizeSensorStatus(String backendStatus) {
    if (backendStatus.isEmpty) return null;
    final words = backendStatus.split("_").where((w) => w.isNotEmpty);
    if (words.isEmpty) return null;
    return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(" ");
  }

  void reset() {
    _cancelTimers();
    _tts.stop();
    status = GuidanceStatus.inactive;
    steps = [];
    currentStepIndex = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelTimers();
    _tts.stop();
    super.dispose();
  }
}
