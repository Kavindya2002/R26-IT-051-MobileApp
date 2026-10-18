import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import '../models/alert_state.dart';
import '../models/elder.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

/// Shown automatically when AlertState.alertType == "Caregiver Alert".
/// Reads the alert aloud (TTS) so the caregiver doesn't have to be
/// looking at the phone to notice it. Backend note: the alerts table
/// doesn't store a natural-language message (only structured fields —
/// fall_type, risk_level, location), so the spoken sentence is built
/// client-side from those fields rather than fetched as pre-written text.
///
/// HARDENING PASS (final review):
///   - Fall type / location used only replaceAll("_", " "), which
///     would mangle an unrecognized value rather than fail safely —
///     now explicit humanization maps for both, matching the pattern
///     used elsewhere in the app (Emergency Alert Detail, Elder Home),
///     with an honest "unavailable" fallback instead of inventing text.
///   - Risk level was never shown or spoken at all — now humanized and
///     included in both the visual card and the spoken message when
///     AlertState actually has one (never calculated locally).
///   - TTS had no error handling: a speak()/setSpeechRate() failure on
///     a device without TTS support would have left the caregiver with
///     no indication anything was wrong. Now wrapped so a TTS failure
///     shows a small "Voice unavailable" notice without ever hiding
///     the visual alert.
///   - Mute/unmute now explicitly stops before re-speaking (prompt
///     section 4/6), and an in-flight speak is never left to overlap
///     a newly requested one.
///   - "I'm Checking Now" now guards against a double tap (which could
///     previously have called markResolved() twice and attempted to
///     pop twice) and stops TTS before leaving.
/// No change to AlertState's architecture, no risk calculation, no
/// business/alert logic — this screen only presents and acknowledges
/// the existing Caregiver Alert.
class CaregiverAlertVoiceInstructionScreen extends StatefulWidget {
  final Elder elder;
  const CaregiverAlertVoiceInstructionScreen({super.key, required this.elder});

  @override
  State<CaregiverAlertVoiceInstructionScreen> createState() =>
      _CaregiverAlertVoiceInstructionScreenState();
}

class _CaregiverAlertVoiceInstructionScreenState
    extends State<CaregiverAlertVoiceInstructionScreen> {
  final FlutterTts _tts = FlutterTts();
  bool _muted = false;
  bool _hasSpokenInitialMessage = false;
  bool _voiceUnavailable = false;
  bool _acknowledging = false;

  bool _hasValue(dynamic v) => v != null && v.toString().trim().isNotEmpty;

  String get _elderName {
    final name = widget.elder.name.trim();
    return name.isEmpty ? "This elder" : name;
  }

  // Only ever a known, explicit mapping or an honest "unavailable" —
  // never a guessed title-case of a raw/unrecognized backend string.
  String _humanizeFallType(dynamic raw) {
    if (!_hasValue(raw)) return "Fall information unavailable";
    final value = raw.toString().trim();
    const alreadyHumanized = {
      "Forward Fall",
      "Backward Fall",
      "Side Fall Left",
      "Side Fall Right",
      "Fall Slump",
      "No Fall",
    };
    if (alreadyHumanized.contains(value)) return value;
    const rawKeyMap = {
      "fall_forward": "Forward Fall",
      "fall_backward": "Backward Fall",
      "fall_side_left": "Side Fall Left",
      "fall_side_right": "Side Fall Right",
      "fall_slump": "Fall Slump",
    };
    return rawKeyMap[value.toLowerCase()] ?? "Fall information unavailable";
  }

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

  // Displays/speaks exactly the real AlertState value — never
  // calculated or inferred here, only capitalized for readability.
  String _humanizeRisk(dynamic raw) {
    if (!_hasValue(raw)) return "Risk level unavailable";
    final value = raw.toString().trim().toLowerCase();
    switch (value) {
      case "low":
        return "Low";
      case "medium":
        return "Medium";
      case "high":
        return "High";
      case "critical":
        return "Critical";
      default:
        return "Risk level unavailable";
    }
  }

  // The SAME builder feeds both the spoken message and the on-screen
  // card (prompt section 14) — they can never drift apart.
  String _buildMessage(AlertState alert) {
    final fallType = _humanizeFallType(alert.fallType);
    final location = _humanizeLocation(alert.location);
    final risk = _humanizeRisk(alert.riskLevel);
    final riskClause = _hasValue(alert.riskLevel) ? " Risk level: $risk." : "";
    return "Fall detected for $_elderName in the $location. $fallType detected.$riskClause Please check on them now.";
  }

  Future<void> _speak(String message) async {
    try {
      await _tts.stop();
      await _tts.setSpeechRate(0.45);
      await _tts.speak(message);
      if (mounted && _voiceUnavailable)
        setState(() => _voiceUnavailable = false);
    } catch (_) {
      // TTS is an enhancement, not a requirement — the visual alert
      // stays visible regardless (prompt section 5).
      if (mounted) setState(() => _voiceUnavailable = true);
    }
  }

  Future<void> _stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing to show the user for a failed stop — it's already on
      // its way out either way.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_hasSpokenInitialMessage || !mounted) return;
      _hasSpokenInitialMessage = true;
      final alert = context.read<AlertState>();
      _speak(_buildMessage(alert));
    });
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    if (_muted) {
      await _stopSpeaking();
    } else {
      final alert = context.read<AlertState>();
      await _speak(_buildMessage(alert));
    }
  }

  Future<void> _acknowledge() async {
    // Guards against a double tap firing markResolved()/pop() twice
    // (prompt section 15).
    if (_acknowledging) return;
    setState(() => _acknowledging = true);
    await _stopSpeaking();
    if (!mounted) return;
    // NOTE (prompt section 16): this marks the alert resolved in the
    // local AlertState only — the existing, unmodified behavior. This
    // screen does not claim or assume backend persistence beyond what
    // AlertState.markResolved() itself already does.
    context.read<AlertState>().markResolved();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final alert = context.watch<AlertState>();
    final fallType = _humanizeFallType(alert.fallType);
    final location = _humanizeLocation(alert.location);
    final risk = _humanizeRisk(alert.riskLevel);

    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F0),
      appBar: AegisAppBar(showLogo: false, title: "Voice Instructions"),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.mediumLight,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFCDCB8), width: 3),
              ),
              child: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                  color: AppColors.medium, size: 38),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.mediumLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.medium),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.notifications_active_outlined,
                      color: AppColors.medium, size: 14),
                  const SizedBox(width: 5),
                  Text("Caregiver Alert",
                      style: TextStyle(
                          color: AppColors.medium,
                          fontWeight: FontWeight.w700,
                          fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              _muted ? "Voice Instruction Muted" : "Voice Instruction Playing",
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              "Being read aloud on this device",
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
          if (_voiceUnavailable) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                "Voice unavailable. Please read the alert below.",
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                      radius: 19,
                      backgroundColor: AppColors.infoLight,
                      child: const Icon(Icons.person,
                          color: AppColors.info, size: 18)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_elderName,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text("$location · $risk",
                            style: Theme.of(context).textTheme.bodyMedium),
                        Text(fallType,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '"${_buildMessage(alert)}"',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _acknowledging ? null : _acknowledge,
              style:
                  ElevatedButton.styleFrom(backgroundColor: AppColors.medium),
              icon: _acknowledging
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check_box_outlined),
              label: const Text("I'm Checking Now"),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _toggleMute,
              icon: Icon(_muted ? Icons.volume_up : Icons.volume_off),
              label: Text(_muted ? "Unmute Voice" : "Mute Voice"),
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  side: const BorderSide(color: AppColors.border)),
            ),
          ),
        ],
      ),
    );
  }
}
