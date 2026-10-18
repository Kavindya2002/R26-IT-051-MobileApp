import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/alert_state.dart';
import '../models/elder.dart';
import '../models/guidance_state.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/status_widgets.dart';
import 'elder_guidance_screen.dart';
import 'login_screen.dart';

/// Minimal, dedicated Elder Home — NOT the Caregiver dashboard with
/// sections hidden. Built fresh per prompt section 13 ("Create ONLY
/// if the project does not already contain an appropriate Elder Home
/// screen" — it did not; the project's only elder-facing screen was
/// ElderGuidanceScreen, which handles an ALREADY-ACTIVE guidance
/// session, not the elder's own entry point into the app).
///
/// Reuses, rather than duplicates:
/// - ApiService.connectAlertStream(elderId) — the SAME WebSocket
///   channel the Caregiver dashboard uses. No second real-time
///   architecture.
/// - GuidanceState / AlertState — the SAME shared Provider instances
///   from main.dart's MultiProvider. Starting guidance here is the
///   exact same GuidanceState.startGuidance() call the Caregiver
///   dashboard makes from its own HTTP response; this screen just
///   also reads the (already-existing, already-broadcast) `guidance`
///   field from the WebSocket message that the Caregiver dashboard's
///   own listener happens to ignore (see app/alerts/service.py's
///   broadcast_sync call — `guidance` is already on the wire).
/// - ElderGuidanceScreen / status_widgets.dart's SafetyStatusCard —
///   the SAME existing widgets, unmodified.
/// - The existing POST /elders/{elderId}/escalate flow via
///   GuidanceState.manualEscalate() when a guidance session is
///   already active, or ApiService.escalate() directly when one isn't
///   (see _handleHelp() below for why these two paths differ).
///
/// GUIDANCE-PROGRESS ADDITION: the backend's message_router.py now
/// broadcasts a SEPARATE "guidance_progress" message (distinct from
/// "alert") over this SAME socket whenever a guidance session is
/// active and a new real IMU sample has been scored by StepValidator
/// (real stability check — see app/component4/guidance/feedback/
/// step_validator.py). This screen forwards that real, already-
/// validated status/current_step straight into
/// GuidanceState.syncStepFromSensor() — no new validation logic here,
/// no fabricated progress. The existing manual "Next Step" button
/// inside ElderGuidanceScreen is untouched and still works as a
/// fallback; this is an additional, automatic path, not a
/// replacement.
///
/// AVATAR PICKER (ADDED): the elder's chosen preset avatar now shows
/// next to the "Hello, {name}" greeting via AvatarCircle, falling back
/// to the exact same initial-letter look for any elder who hasn't
/// picked one yet. The SafetyStatusCard below (with its walking-person
/// status icon) is untouched — that icon conveys live safety status,
/// not identity, so it deliberately stays as-is.
class ElderHomeScreen extends StatefulWidget {
  final Elder elder;
  const ElderHomeScreen({super.key, required this.elder});

  @override
  State<ElderHomeScreen> createState() => _ElderHomeScreenState();
}

enum _ConnState { connecting, connected, disconnected }

class _ElderHomeScreenState extends State<ElderHomeScreen> {
  WebSocketChannel? _socket;
  Timer? _reconnectTimer;
  _ConnState _connState = _ConnState.connecting;

  // Bounded dedup set — same reasoning as HomeDashboardScreen's
  // _isNewAlertId: a reconnect can replay a recently-seen broadcast,
  // and the same alert can arrive here once; a real backend alert id
  // is never reused, so this can never grow without limit and never
  // needs clearing.
  final Set<String> _processedAlertIds = <String>{};
  static const int _maxProcessedAlertIds = 50;

  bool _escalating = false;
  bool _helpRequestedWithoutGuidance = false;

  // Safety status is derived ONLY from the most recent real alert
  // message this screen has actually seen — never assumed "safe" as a
  // starting value (prompt section 29).
  String? _latestRiskLevel;

  bool _isNewAlertId(String? id) {
    if (id == null || id.isEmpty) return true;
    if (_processedAlertIds.contains(id)) return false;
    _processedAlertIds.add(id);
    if (_processedAlertIds.length > _maxProcessedAlertIds) {
      _processedAlertIds.remove(_processedAlertIds.first);
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    _reconnectTimer?.cancel();
    _socket?.sink.close();
    if (mounted) setState(() => _connState = _ConnState.connecting);

    WebSocketChannel socket;
    try {
      socket = ApiService.instance.connectAlertStream(widget.elder.id);
    } catch (e) {
      debugPrint("Elder Home: could not connect alert stream: $e");
      _scheduleReconnect();
      return;
    }
    _socket = socket;

    socket.ready.then((_) {
      if (!mounted || _socket != socket) return;
      setState(() => _connState = _ConnState.connected);
    }).catchError((e) {
      debugPrint("Elder Home: handshake failed: $e");
      if (!mounted || _socket != socket) return;
      setState(() => _connState = _ConnState.disconnected);
      _scheduleReconnect();
    });

    socket.stream.listen((raw) {
      try {
        final message = jsonDecode(raw as String);
        final type = message["type"];

        // ADDED (real sensor-based guidance step advancement): a
        // distinct message type on the SAME socket, broadcast only
        // while a guidance session is active. Handled separately from
        // "alert" below and returned early so it never falls through
        // to the alert-handling logic.
        if (type == "guidance_progress") {
          _handleGuidanceProgress(message);
          return;
        }

        if (type != "alert" || message["alert"] == null) return;
        final a = Map<String, dynamic>.from(message["alert"]);
        final alertId = a["id"]?.toString();
        if (!_isNewAlertId(alertId)) return;
        if (!mounted) return;

        final riskLevel = a["risk_level"]?.toString().toUpperCase();
        setState(() => _latestRiskLevel = riskLevel);

        context.read<AlertState>().setAlert(
              alertType: a["alert_type"] ?? "Voice Alert",
              confidence: (a["confidence"] ?? 0).toDouble(),
              probabilities: const {},
              fallType: a["fall_type"] ?? "fall",
              riskLevel: a["risk_level"] ?? "LOW",
              location: a["location"] ?? "unknown",
              elderPhone: widget.elder.phone,
            );

        // ADDED (the integration point confirmed by reading
        // app/alerts/service.py directly): `guidance` is already
        // included in this same broadcast message, next to `alert` —
        // no backend change was needed to read it here. Only ever
        // starts guidance for LOW risk, exactly mirroring Component
        // 4's own intervention mapping (prompt section 18) — never a
        // second risk calculation, just reading the same real decision
        // the backend already made.
        //
        // HARDENING (final fix prompt sections 3-4): the payload is
        // untrusted wire data, so it is validated step by step before
        // ever being handed to GuidanceState — a malformed or partial
        // `guidance` object is silently skipped (with a debug log),
        // never papered over with fabricated fallback steps. Separately,
        // a guidance session that is already active is never restarted
        // by a second genuine LOW alert arriving mid-session — that
        // would reset the elder's current step and re-speak step 1 via
        // TTS. Both checks are combined into one guard; neither touches
        // the real risk-level decision made above.
        final guidance = message["guidance"];
        final alreadyActive =
            context.read<GuidanceState>().status == GuidanceStatus.active;
        if (riskLevel == "LOW" &&
            !alreadyActive &&
            guidance is Map &&
            guidance["enabled"] == true) {
          final rawSteps = guidance["steps"];
          if (rawSteps is List) {
            final steps = rawSteps.whereType<String>().toList();
            if (steps.isNotEmpty) {
              context.read<GuidanceState>().startGuidance(
                    steps: steps,
                    fallType: a["fall_type"] ?? "fall",
                    elderId: widget.elder.id,
                    elderName: widget.elder.name,
                  );
            } else {
              debugPrint(
                  "Elder Home: guidance steps empty/invalid after validation, skipping");
            }
          } else {
            debugPrint("Elder Home: guidance.steps not a List, skipping");
          }
        }
      } catch (e) {
        debugPrint("Elder Home: alert stream parse failed: $e");
      }
    }, onError: (e) {
      debugPrint("Elder Home: alert stream error: $e");
      if (!mounted) return;
      setState(() => _connState = _ConnState.disconnected);
      _scheduleReconnect();
    }, onDone: () {
      if (!mounted) return;
      setState(() => _connState = _ConnState.disconnected);
      _scheduleReconnect();
    });
  }

  /// ADDED (real sensor-based guidance step advancement): forwards the
  /// backend's already-validated stability status/current_step
  /// straight into GuidanceState.syncStepFromSensor(), which handles
  /// auto-advancing the step and speaking it via TTS. No validation
  /// logic lives here — this screen trusts the backend's real
  /// StepValidator decision and only guards against a malformed
  /// payload shape.
  void _handleGuidanceProgress(Map<String, dynamic> message) {
    if (!mounted) return;
    final progress = message["progress"];
    if (progress is! Map) {
      debugPrint(
          "Elder Home: guidance_progress missing/invalid 'progress' field, skipping");
      return;
    }
    final backendStatus = progress["status"]?.toString() ?? "";
    final rawStep = progress["current_step"];
    final backendCurrentStep =
        rawStep is int ? rawStep : (rawStep is num ? rawStep.toInt() : null);
    context.read<GuidanceState>().syncStepFromSensor(
          backendCurrentStep: backendCurrentStep,
          backendStatus: backendStatus,
        );
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) _connect();
    });
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _socket?.sink.close();
    super.dispose();
  }

  SafetyStatus _deriveSafetyStatus(AlertState alert, GuidanceState guidance) {
    if (guidance.status == GuidanceStatus.escalated)
      return SafetyStatus.emergency;
    if (alert.hasActiveAlert && alert.alertType == "Emergency Alert")
      return SafetyStatus.emergency;
    if (_latestRiskLevel == "HIGH" || _latestRiskLevel == "CRITICAL")
      return SafetyStatus.emergency;
    if (_latestRiskLevel == "MEDIUM") return SafetyStatus.warning;
    if (_latestRiskLevel == "LOW") return SafetyStatus.safe;
    // No real reading yet, or an unrecognized value: honestly unknown,
    // NEVER assumed "safe" (prompt section 29 — this is the one rule
    // this screen must never violate).
    return SafetyStatus.unknown;
  }

  String _safetyMessage(SafetyStatus status, GuidanceStatus guidanceStatus) {
    // OPTIONAL HARDENING (final fix prompt section 8): wording-only
    // change — tells the elder guidance is actively running and that
    // they should follow it, rather than the vaguer "available". The
    // underlying risk-level logic above (_deriveSafetyStatus) is
    // untouched.
    if (guidanceStatus == GuidanceStatus.active)
      return "Guidance is active. Follow the steps.";
    return switch (status) {
      SafetyStatus.safe => "You are safe",
      SafetyStatus.warning => "Your caregiver has been notified",
      SafetyStatus.emergency => "Help has been requested",
      SafetyStatus.unknown => "Status unavailable",
    };
  }

  /// Reuses the existing escalation mechanism in both branches — never
  /// a second/new escalation endpoint.
  ///
  /// WHY TWO PATHS: GuidanceState.manualEscalate() is only safe to call
  /// when `elderId`/`elderName` are already populated, which only ever
  /// happens inside startGuidance() (see models/guidance_state.dart —
  /// it exposes no other way to set them, and the prompt explicitly
  /// forbids inventing new state inside GuidanceState). If the elder
  /// taps "I Need Help Now" from this Home screen BEFORE any guidance
  /// session has started, going through GuidanceState would escalate
  /// with an empty elderId. So: when guidance is already active, reuse
  /// guidance.manualEscalate() exactly as elder_guidance_screen.dart
  /// does; otherwise call ApiService.instance.escalate() directly —
  /// the SAME real POST /elders/{elderId}/escalate call
  /// GuidanceState.manualEscalate() itself makes internally, just with
  /// this screen's own already-known elder id. No confirmation dialog
  /// either way (prompt section 21).
  Future<void> _handleHelp(GuidanceState guidance) async {
    if (_escalating) return;
    setState(() => _escalating = true);
    try {
      if (guidance.status == GuidanceStatus.active) {
        await guidance.manualEscalate();
      } else {
        await ApiService.instance.escalate(
          elderId: widget.elder.id,
          reason: "elder_requested_help",
          fallType: "fall",
        );
        if (mounted) setState(() => _helpRequestedWithoutGuidance = true);
      }
    } catch (e) {
      debugPrint("Elder Home: escalate failed: $e");
      // HARDENING (final fix prompt section 6): the elder must never
      // see a raw exception or be left thinking help was sent when it
      // wasn't. Uses the project's existing feedback pattern (same
      // ScaffoldMessenger/SnackBar call as register_screen.dart) rather
      // than inventing a new one. _escalating is still reset in the
      // `finally` block below, so the button re-enables and the elder
      // can simply press "I Need Help Now" again.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't reach your caregiver. Please try again."),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _escalating = false);
    }
  }

  Future<void> _logout() async {
    // Reuses the existing logout mechanism — no second implementation.
    await ApiService.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final guidance = context.watch<GuidanceState>();
    final alert = context.watch<AlertState>();
    final status = _deriveSafetyStatus(alert, guidance);
    final guidanceActive = guidance.status == GuidanceStatus.active;
    final showHelpRequestedNotice = _helpRequestedWithoutGuidance &&
        guidance.status != GuidanceStatus.escalated;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const AegisAppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // CHANGED (avatar picker feature): shows the elder's
              // chosen preset avatar next to their name, falling back
              // to the exact original initial-letter look when they
              // haven't picked one yet.
              Row(
                children: [
                  AvatarCircle(
                    avatarId: widget.elder.avatarId,
                    fallbackInitial: widget.elder.name.isNotEmpty
                        ? widget.elder.name[0].toUpperCase()
                        : "?",
                    radius: 28,
                    fallbackColor: AppColors.primary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      "Hello, ${widget.elder.name}",
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),

              Semantics(
                label:
                    "Safety status: ${_safetyMessage(status, guidance.status)}",
                child: ExcludeSemantics(
                  child: SafetyStatusCard(
                    status: status,
                    elderName: widget.elder.name,
                    message: _safetyMessage(status, guidance.status),
                    riskLevel: _latestRiskLevel,
                  ),
                ),
              ),

              if (showHelpRequestedNotice) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.warningLight,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: const Text(
                    "Help has been requested.",
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],

              const SizedBox(height: AppSpacing.xl),

              // MY GUIDANCE — only a real, active guidance session is
              // ever offered; never a fabricated "guidance available"
              // state (prompt section 15/30).
              Text("My Guidance",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Text(
                guidanceActive
                    ? "Follow the steps to stay safe."
                    : "No active guidance right now.",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              // ADDED (real sensor-based guidance step advancement): a
              // short, honest status line reflecting the backend's real
              // IMU-stability read on the current step — "Still moving",
              // "Holding steady… confirming", etc. (see
              // GuidanceState.syncStepFromSensor / sensorHint). Only
              // shown while guidance is actually active, and only when
              // there is a real hint to show.
              if (guidanceActive && guidance.sensorHint != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  guidance.sensorHint!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: guidanceActive
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const ElderGuidanceScreen()),
                          )
                      : null,
                  icon: const Icon(Icons.self_improvement),
                  label: const Text("Open Guidance",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.border,
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.xl),

              // I NEED HELP NOW — always visible, never hidden behind
              // guidance being active, never a confirmation dialog.
              SizedBox(
                height: 64,
                child: ElevatedButton.icon(
                  onPressed: _escalating ? null : () => _handleHelp(guidance),
                  icon: _escalating
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.warning_amber_rounded),
                  label: Text(
                    _escalating ? "Alerting caregiver…" : "I Need Help Now",
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.emergency,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.xxl),

              // Connection status — plain language, never falsely
              // claims "Connected" (prompt section 33).
              Semantics(
                label: "Live connection status: ${_connectionLabel()}",
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.circle, size: 8, color: _connectionColor()),
                      const SizedBox(width: AppSpacing.sm),
                      Text(_connectionLabel(),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text("Logout"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _connectionLabel() {
    // HARDENING (final fix prompt section 7): wording is now explicit
    // that this is the live-alert connection only — never implies
    // anything about Component 1/sensor/MQTT status, which this screen
    // has no visibility into either way.
    return switch (_connState) {
      _ConnState.connecting => "Connecting to live alerts…",
      _ConnState.connected => "Live alerts connected",
      _ConnState.disconnected => "Live alerts unavailable",
    };
  }

  Color _connectionColor() {
    return switch (_connState) {
      _ConnState.connecting => AppColors.textSecondary,
      _ConnState.connected => AppColors.safe,
      _ConnState.disconnected => AppColors.warning,
    };
  }
}
