import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

/// Shown automatically when an "Emergency Alert" fires — mirrors
/// CaregiverAlertVoiceInstructionScreen's TTS pattern (same package,
/// same mute/unmute, same "speak on open" behavior) but with an
/// urgent-tone message and critical-color styling. Used from BOTH
/// the Caregiver Dashboard (home_dashboard_screen.dart) and the
/// Emergency Person's own feed (emergency_alerts_feed_screen.dart).
/// Those two screens hold the elder/alert data in different shapes
/// (Elder model vs raw Map), so this screen deliberately takes plain
/// String/callback params instead of depending on either shape or on
/// AlertState — AlertState is specifically the Caregiver Dashboard's
/// own state and reading it here would be wrong when opened from the
/// Emergency Person's screen, which never touches AlertState.
class EmergencyAlertVoiceInstructionScreen extends StatefulWidget {
  final String elderName;
  final String? fallType;
  final String? location;
  final String? riskLevel;
  final VoidCallback? onAcknowledge;

  const EmergencyAlertVoiceInstructionScreen({
    super.key,
    required this.elderName,
    this.fallType,
    this.location,
    this.riskLevel,
    this.onAcknowledge,
  });

  @override
  State<EmergencyAlertVoiceInstructionScreen> createState() =>
      _EmergencyAlertVoiceInstructionScreenState();
}

class _EmergencyAlertVoiceInstructionScreenState
    extends State<EmergencyAlertVoiceInstructionScreen> {
  final FlutterTts _tts = FlutterTts();
  bool _muted = false;

  String _buildMessage() {
    final fallType = (widget.fallType ?? "a fall").replaceAll("_", " ");
    final location = widget.location ?? "an unknown location";
    return "Emergency! ${widget.elderName} needs immediate attention. "
        "$fallType detected in the $location. Please respond right now.";
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tts.setSpeechRate(0.45);
      _tts.speak(_buildMessage());
    });
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    if (_muted) {
      _tts.stop();
    } else {
      _tts.speak(_buildMessage());
    }
  }

  @override
  Widget build(BuildContext context) {
    final criticalBg = AppColors.critical.withValues(alpha: 0.12);

    return Scaffold(
      backgroundColor: const Color(0xFFFFF1F0),
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
                color: criticalBg,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.critical, width: 3),
              ),
              child: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                  color: AppColors.critical, size: 38),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: criticalBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.critical),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.emergency,
                      color: AppColors.critical, size: 14),
                  const SizedBox(width: 5),
                  Text(
                    "Emergency Alert",
                    style: TextStyle(
                        color: AppColors.critical,
                        fontWeight: FontWeight.w700,
                        fontSize: 12),
                  ),
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
            child: Text("Being read aloud on this device",
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 19,
                    backgroundColor: criticalBg,
                    child:
                        Icon(Icons.person, color: AppColors.critical, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.elderName,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(
                          "${widget.location ?? "-"} · ${widget.riskLevel ?? "-"}",
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
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
                '"${_buildMessage()}"',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              widget.onAcknowledge?.call();
              Navigator.of(context).pop();
            },
            style:
                ElevatedButton.styleFrom(backgroundColor: AppColors.critical),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text("Acknowledge"),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _toggleMute,
            icon: Icon(_muted ? Icons.volume_up : Icons.volume_off),
            label: Text(_muted ? "Unmute Voice" : "Mute Voice"),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              side: const BorderSide(color: AppColors.border),
            ),
          ),
        ],
      ),
    );
  }
}
