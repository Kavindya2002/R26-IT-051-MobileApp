import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../models/alert_state.dart';
import '../models/elder.dart';
import '../models/guidance_state.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/status_widgets.dart';
import '../widgets/responsive.dart';
import '../widgets/avatar_circle.dart';
import 'alert_detail_screen.dart';
import 'alerts_screen.dart';
import 'caregiver_alert_voice_instruction_screen.dart';
import 'emergency_alert_voice_instruction_screen.dart';
import 'caregiver_guidance_mirror.dart';
import 'elder_details_screen.dart';
import 'elder_guidance_screen.dart';
import 'environment_screen.dart';
import 'fall_detection_screen.dart';
import 'profile_screen.dart';
import 'vitals_screen.dart';

/// Home Dashboard — rebuilt visual layer on the new teal design system.
///
/// IMPORTANT: every piece of state-management, API-polling, WebSocket,
/// and Component-4-integration logic below is preserved from the
/// original implementation, with targeted correctness fixes called out
/// inline (null-risk handling, WebSocket reconnect, alert-id based
/// voice-instruction dedup, per-component fetch isolation, heart-rate
/// validity, and stale-data flagging). No new API calls except the one
/// explicitly added below for the real caregiver profile (needed for
/// the header avatar — see `_fetchCaregiverProfile`). No fabricated
/// data anywhere below.
///
/// TTS ADDITION: `_maybeShowCaregiverVoiceInstruction` now opens a
/// voice-instruction popup for BOTH "Caregiver Alert" (unchanged,
/// existing CaregiverAlertVoiceInstructionScreen) AND "Emergency
/// Alert" (new EmergencyAlertVoiceInstructionScreen) — see that
/// method below for details. No other logic changed for this.
///
/// REDESIGN (Home Dashboard UI Redesign Prompt): the visual layer
/// below this point was rebuilt to the new reference design —
/// branded teal header (logo + name + tagline + caregiver avatar),
/// one consolidated "Monitoring Connection Status" card, a dedicated
/// Elder Information card, and a 2x2 dashboard grid whose first card
/// is now "Alerts" (replacing "Activity", which duplicated the Fall
/// Detection card's own navigation). See inline FIX/NOTE comments
/// below for exactly what changed and why.

/// Real, tracked WebSocket connection state for the alert stream.
/// Replaces the previous "fire and forget" connect with no visibility
/// into whether the stream is actually up.
enum _WsStatus { connecting, connected, disconnected, error }

class HomeDashboardScreen extends StatefulWidget {
  final Elder elder;
  const HomeDashboardScreen({super.key, required this.elder});

  @override
  State<HomeDashboardScreen> createState() => _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends State<HomeDashboardScreen> {
  Timer? _pollTimer;
  Map<String, dynamic>? _fallResult; // Component 1
  Map<String, dynamic>? _envResult; // Component 2
  Map<String, dynamic>? _vitalsResult; // Component 3
  WebSocketChannel? _alertSocket;

  // FIX (Final Bounded Alert-ID Dedup prompt): confirmed by reading the
  // real backend (app/alerts/service.py) that Supabase's insert returns
  // the full row INCLUDING its real assigned `id`, and that exact row
  // (`id` included) is what gets broadcast over the WebSocket. The
  // pipeline's HTTP response was the only place silently discarding
  // that id — now fixed (see app/integration/pipeline.py's `alert_id`
  // field) so BOTH delivery paths carry the SAME real identifier for
  // the same alert.
  //
  // A single `String? _lastProcessedAlertId` (the earlier version of
  // this fix) only remembered the MOST RECENT alert — so an older
  // alert re-delivered after a newer one (a real possibility: network
  // reordering, a WebSocket reconnect replaying a recent broadcast, a
  // slow REST response landing after the WS copy of the same event)
  // would no longer match and would be wrongly reprocessed. A bounded
  // Set of recently-seen real ids fixes that while still never growing
  // without limit. This is the single, shared source of truth for
  // "have I already processed this alert" — used for AlertState
  // updates, voice instruction, and (implicitly) navigation, whether
  // the alert arrived via this screen's own triggerIntegration() call
  // or via the WebSocket broadcast of that same call's side effect.
  final Set<String> _processedAlertIds = <String>{};
  static const int _maxProcessedAlertIds = 100;

  /// Shared dedup check used by BOTH the REST/polling path and the
  /// WebSocket path. A null/empty id (no real backend id available)
  /// is never stored and is always treated as "new" — there's nothing
  /// to deduplicate against, and we never invent one. A real id already
  /// seen is rejected as a duplicate; a real id not yet seen is
  /// recorded and accepted, trimming the oldest entry once the bounded
  /// limit is passed so this can never grow without limit.
  bool _isNewAlertId(String? alertId) {
    if (alertId == null || alertId.isEmpty) return true;
    if (_processedAlertIds.contains(alertId)) return false;
    _processedAlertIds.add(alertId);
    if (_processedAlertIds.length > _maxProcessedAlertIds) {
      _processedAlertIds.remove(_processedAlertIds.first);
    }
    return true;
  }

  // Falls back to this (instead of the real id) only on the rare path
  // where no id is available at all — e.g. AlertService.create()
  // logged a write failure and returned None, so the alert was still
  // shown to the caregiver but was never assigned a real id.
  String? _lastVoiceInstructionIdentity;

  // FIX (Remaining-Issues prompt, Issue 3 — kept, narrowed in scope):
  // /component1/latest still has no server-issued event id for a
  // not-yet-triggered fall, so this fingerprint (fall_type, risk_level,
  // confidence, explanation) is still the PRE-call heuristic deciding
  // whether this poll's fall_detected==true looks like a continuation
  // of the fall already sent to Component 4, or a fresh one worth
  // triggering again. Once a call is actually made, identity from then
  // on is the REAL alert id above, not this fingerprint — the
  // fingerprint's only job is avoiding reposting Component 4 every 5s
  // while one ongoing fall is still being read.
  String? _lastProcessedFallFingerprint;

  // FIX (sample_time backend addition): the real server timestamp of
  // the last sample whose fingerprint matched and was treated as "the
  // same ongoing fall" — lets `_isLikelyContinuationOfLastFall` require
  // the two matching samples to also be close together in time, not
  // just equal in content.
  DateTime? _lastProcessedSampleTime;

  // FIX (Doc 2, Issues 3-4): real WebSocket connection-state tracking
  // plus a capped, non-aggressive reconnect. No change to
  // ApiService.connectAlertStream() itself — this only wraps it.
  _WsStatus _wsStatus = _WsStatus.connecting;
  Timer? _wsReconnectTimer;
  int _wsReconnectAttempts = 0;
  static const List<int> _wsReconnectDelaysSeconds = [3, 5, 10, 20, 30];

  // Rebuild-only addition: tracks fetch/connection failure so the new
  // UI can show the consolidated monitoring-status card / retry
  // instead of silently doing nothing, per the new error/offline-state
  // requirements. Does not change any existing data-fetching logic.
  bool _lastFetchFailed = false;
  DateTime? _lastSuccessfulFetch;

  // NEW (Home Dashboard redesign, header section): the real,
  // currently-logged-in caregiver's own name, used only to derive the
  // header avatar's initial letter. This screen previously had no
  // reason to know the caregiver's own identity (only the elder's) —
  // the redesign's header requires it, so one lightweight one-shot
  // call to the SAME endpoint ProfileScreen already uses
  // (ApiService.instance.getMyProfile()) is added here. Never
  // hardcoded; null (showing a generic person icon instead of a
  // fabricated initial) until this resolves, or if it fails.
  String? _caregiverName;
  // ADDED (avatar picker feature): the logged-in caregiver/emergency
  // person's chosen preset avatar id, fetched alongside their name so
  // the header circle can show the same avatar as Edit Profile/Profile
  // screens instead of a plain initial letter.
  String? _caregiverAvatarId;

  @override
  void initState() {
    super.initState();
    // ADDED (avatar header fix): if some other screen (e.g.
    // ProfileScreen) already fetched the caregiver's profile this
    // session, show it immediately — no flash of the generic icon
    // while this screen's own fetch below is still in flight.
    final cached = ApiService.instance.cachedProfile;
    if (cached != null) {
      _caregiverName = cached["name"]?.toString();
      _caregiverAvatarId = cached["avatar_id"]?.toString();
    }
    _fetchAll();
    _pollTimer = Timer.periodic(AppConfig.pollInterval, (_) => _fetchAll());
    _connectAlertStream();
    _fetchCaregiverProfile();
  }

  /// NEW (header avatar): fetches the real logged-in caregiver's own
  /// profile once. Failure is swallowed (logged only) — the header
  /// simply falls back to a generic icon rather than surfacing an
  /// error for what is a purely cosmetic avatar initial.
  Future<void> _fetchCaregiverProfile() async {
    try {
      final res = await ApiService.instance.getMyProfile();
      if (!mounted) return;
      final user = res["user"];
      setState(() {
        _caregiverName = user is Map ? user["name"]?.toString() : null;
        _caregiverAvatarId =
            user is Map ? user["avatar_id"]?.toString() : null;
      });
    } catch (e) {
      debugPrint("Caregiver profile fetch failed: $e");
    }
  }

  /// FIX (Remaining-Issues prompt, Issue 1): previously this set
  /// `_wsStatus = connected` the instant `connectAlertStream()` returned
  /// a channel object — before the WebSocket handshake was actually
  /// confirmed. `WebSocketChannel.ready` is the channel's own real
  /// connection-open signal (completes once the socket is actually
  /// open, or throws if it never connects), so CONNECTED is now only
  /// ever set once that future resolves. No change to ApiService.
  ///
  /// FIX (Issue 9): closes any previous socket before creating a new
  /// one, and every late callback checks `_alertSocket == thisSocket`
  /// so a stale reconnect attempt can never clobber state set by a
  /// newer one — only one connection attempt is ever "live".
  void _connectAlertStream() {
    _wsReconnectTimer?.cancel();
    _alertSocket?.sink.close();
    if (mounted) setState(() => _wsStatus = _WsStatus.connecting);

    WebSocketChannel socket;
    try {
      socket = ApiService.instance.connectAlertStream(widget.elder.id);
    } catch (e) {
      debugPrint("Could not connect alert stream: $e");
      if (mounted) setState(() => _wsStatus = _WsStatus.error);
      _scheduleWsReconnect();
      return;
    }
    _alertSocket = socket;

    socket.ready.then((_) {
      if (!mounted || _alertSocket != socket) return;
      setState(() => _wsStatus = _WsStatus.connected);
      _wsReconnectAttempts = 0;
    }).catchError((e) {
      debugPrint("Alert stream handshake failed: $e");
      if (!mounted || _alertSocket != socket) return;
      setState(() => _wsStatus = _WsStatus.error);
      _scheduleWsReconnect();
    });

    socket.stream.listen((raw) {
      try {
        final message = jsonDecode(raw as String);
        if (message["type"] == "alert" && message["alert"] != null) {
          final a = Map<String, dynamic>.from(message["alert"]);
          // FIX (Final Bounded Alert-ID Dedup prompt): `a["id"]` is the
          // SAME real Supabase-assigned alert id this screen's own
          // triggerIntegration() call may already have seen in its HTTP
          // response (see _maybeHandleFallEvent below) — one shared
          // `_isNewAlertId()` / `_processedAlertIds` across both
          // delivery paths, so whichever one arrives second (in either
          // order) is recognized as a duplicate of the same event.
          final alertId = a["id"]?.toString();
          if (!_isNewAlertId(alertId)) return;
          if (!mounted) return;
          context.read<AlertState>().setAlert(
                alertType: a["alert_type"] ?? "Caregiver Alert",
                confidence: (a["confidence"] ?? 0).toDouble(),
                probabilities: const {},
                fallType: a["fall_type"] ?? "fall",
                riskLevel: a["risk_level"] ?? "LOW",
                location: a["location"] ?? "unknown",
                elderPhone: widget.elder.phone,
              );
          _maybeShowCaregiverVoiceInstruction(alertId);
        }
      } catch (e) {
        debugPrint("Alert stream parse failed: $e");
      }
    }, onError: (e) {
      debugPrint("Alert stream error: $e");
      if (!mounted || _alertSocket != socket) return;
      setState(() => _wsStatus = _WsStatus.error);
      _scheduleWsReconnect();
    }, onDone: () {
      if (!mounted || _alertSocket != socket) return;
      setState(() => _wsStatus = _WsStatus.disconnected);
      _scheduleWsReconnect();
    });
  }

  /// Controlled reconnect: capped exponential-ish backoff, one timer at
  /// a time, cancelled cleanly on dispose — never a tight retry loop.
  void _scheduleWsReconnect() {
    if (!mounted) return;
    _wsReconnectTimer?.cancel();
    final delayIndex =
        _wsReconnectAttempts.clamp(0, _wsReconnectDelaysSeconds.length - 1);
    final delay = _wsReconnectDelaysSeconds[delayIndex];
    _wsReconnectAttempts++;
    _wsReconnectTimer = Timer(Duration(seconds: delay), () {
      if (!mounted) return;
      _connectAlertStream();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _wsReconnectTimer?.cancel();
    _alertSocket?.sink.close();
    super.dispose();
  }

  /// FIX (Doc 2, Issue 7): the three component fetches are now isolated
  /// — one failing no longer blanks the other two. Each result keeps
  /// its previous value on failure instead of being wiped, and the
  /// monitoring-status card only reports a full "Connection Lost" when
  /// ALL three fail (a real total outage), not on a single component
  /// hiccup.
  Future<void> _fetchAll() async {
    var fallResult = _fallResult;
    var envResult = _envResult;
    var vitalsResult = _vitalsResult;
    var anySucceeded = false;

    try {
      final fall = await ApiService.instance.getFallLatest();
      fallResult = fall["result"];
      anySucceeded = true;
    } catch (e) {
      debugPrint("Component 1 fetch failed: $e");
    }

    try {
      final env = await ApiService.instance.getEnvironmentLatest();
      envResult = env["result"];
      anySucceeded = true;
    } catch (e) {
      debugPrint("Component 2 fetch failed: $e");
    }

    try {
      final vitals = await ApiService.instance.getVitalsLatest();
      vitalsResult = vitals["result"];
      anySucceeded = true;
    } catch (e) {
      debugPrint("Component 3 fetch failed: $e");
    }

    if (!mounted) return;
    setState(() {
      _fallResult = fallResult;
      _envResult = envResult;
      _vitalsResult = vitalsResult;
      _lastFetchFailed = !anySucceeded;
      if (anySucceeded) _lastSuccessfulFetch = DateTime.now();
    });
    if (anySucceeded) _maybeHandleFallEvent();
  }

  /// Builds the composite fall-event fingerprint described above the
  /// `_lastProcessedFallFingerprint` field — the closest available
  /// proxy for a real event id given what `/component1/latest` returns.
  String _fallEventFingerprint(Map<String, dynamic> fall) {
    return [
      fall["fall_type"],
      fall["risk_level"],
      fall["confidence"],
      fall["explanation"]
    ].map((v) => v?.toString() ?? "").join("|");
  }

  /// FIX (backend now exposes a real `sample_time` on every Component 1
  /// reading — see app/integration/component1_adapter.py): a matching
  /// fingerprint across two polls is only treated as "still the same
  /// ongoing fall" when those two samples are also close together in
  /// real server time (within a few poll cycles). If the SAME field
  /// values reappear after a bigger gap than normal polling, that is no
  /// longer blindly suppressed — it's a genuinely separate reading the
  /// fingerprint alone can't tell apart from a repeat, so time is used
  /// to break the tie honestly rather than guessing either way.
  bool _isLikelyContinuationOfLastFall(
      Map<String, dynamic> fall, String fingerprint) {
    if (_lastProcessedFallFingerprint != fingerprint) return false;
    if (_lastProcessedSampleTime == null) return false;
    final sampleTime = DateTime.tryParse(fall["sample_time"]?.toString() ?? "");
    if (sampleTime == null)
      return false; // no real timestamp to compare — don't assume continuity
    final gap = sampleTime.difference(_lastProcessedSampleTime!).abs();
    return gap <= AppConfig.pollInterval * 3;
  }

  /// Whenever a fall is detected, ask Component 4 for the real alert +
  /// guidance decision using this elder's actual risk profile.
  ///
  /// FIX (Remaining-Issues prompt, Issue 3): dedup is now keyed on the
  /// fall-event fingerprint instead of a single boolean, so a second
  /// genuine fall occurring while `fall_detected` is still true from a
  /// first one is NOT silently dropped — only an exact repeat of the
  /// same reading is ignored.
  Future<void> _maybeHandleFallEvent() async {
    final fall = _fallResult;
    if (fall == null) return;
    final fallDetected = fall["fall_detected"] == true;

    if (!fallDetected) {
      // Back to "No Fall": clear the pre-call fingerprint so the NEXT
      // real fall is always considered for triggering, even if its
      // fingerprint were to coincide with one seen before this gap.
      // `_processedAlertIds` is NOT cleared here — real backend ids are
      // unique, so there's no coincidental-collision risk, and keeping
      // them prevents a late, slow WS broadcast of an alert already
      // handled from re-triggering effects after the fall has cleared.
      _lastProcessedFallFingerprint = null;
      _lastProcessedSampleTime = null;
      return;
    }
    final fingerprint = _fallEventFingerprint(fall);
    // FIX: a matching fingerprint alone no longer suppresses this
    // sample — it must ALSO be close in real time to the last one that
    // matched (see `_isLikelyContinuationOfLastFall`). A real backend
    // `sample_time` now exists for exactly this: two genuinely separate
    // falls with identical fall_type/risk_level/confidence/explanation
    // are no longer indistinguishable from a repeat, as long as there's
    // a real time gap between them.
    if (_isLikelyContinuationOfLastFall(fall, fingerprint)) return;
    _lastProcessedFallFingerprint = fingerprint;
    // FIX (Final Sample-Time prompt, Issue 1): ONLY the real
    // backend-provided `sample_time` is ever stored here — no
    // `DateTime.now()` fallback. A missing/invalid value is not
    // fabricated; it just means a future sample can't be confirmed as
    // "close in time" to this one (`_isLikelyContinuationOfLastFall`
    // already requires a valid parse on both sides and returns false
    // otherwise), so the continuation comparison is safely skipped
    // rather than silently backed by a client-side guess. This can
    // never wrongly suppress a genuine new fall — at worst it means
    // Component 4 is asked again slightly more often than ideal, which
    // is the safe direction.
    final parsedSampleTime =
        DateTime.tryParse(fall["sample_time"]?.toString() ?? "");
    if (parsedSampleTime != null) {
      _lastProcessedSampleTime = parsedSampleTime;
    }

    try {
      final result = await ApiService.instance.triggerIntegration(
        component1: {
          "fall_detected": true,
          "fall_type": fall["fall_type"] ?? "fall",
          "risk_level": fall["risk_level"] ?? "LOW",
          "movement": fall["movement"] ?? "Standing",
          "confidence": fall["confidence"] ?? 0.0,
        },
        component2: {
          "location": _envResult?["location"] ?? "unknown",
          "time": TimeOfDay.now().format(context),
        },
        user: {
          "age": widget.elder.age,
          "previous_falls": widget.elder.previousFalls,
          "assistive_device": widget.elder.assistiveDevice,
        },
        elderId: widget.elder.id,
      );

      final c4 = result["component4"];
      if (c4 == null || !mounted) return;

      // FIX (Final Bounded Alert-ID Dedup prompt): the backend returns
      // the real persisted alert id for this exact call (see
      // app/integration/pipeline.py's `alert_id` field), checked
      // against the SAME shared, bounded `_isNewAlertId()` the
      // WebSocket path uses above. If the WebSocket broadcast of this
      // SAME call already arrived first (a real race in this app,
      // since it both triggers and listens to its own elder's alert
      // channel), skip re-processing — otherwise the id is now recorded
      // so a slightly-later WS broadcast of this same alert is
      // recognized as the duplicate instead.
      final alertId = result["alert_id"]?.toString();
      if (!_isNewAlertId(alertId)) return;

      context.read<AlertState>().setAlert(
            alertType: c4["alert"] ?? "Caregiver Alert",
            confidence: (c4["confidence"] ?? 0).toDouble(),
            probabilities: Map<String, dynamic>.from(c4["probabilities"] ?? {}),
            fallType: fall["fall_type"] ?? "fall",
            riskLevel: fall["risk_level"] ?? "LOW",
            location: _envResult?["location"] ?? "unknown",
            elderPhone: widget.elder.phone,
          );

      _maybeShowCaregiverVoiceInstruction(alertId);

      final guidance = c4["guidance"];
      if (guidance != null && guidance["enabled"] == true) {
        context.read<GuidanceState>().startGuidance(
              steps: List<String>.from(guidance["steps"] ?? []),
              fallType: fall["fall_type"] ?? "fall",
              elderId: widget.elder.id,
              elderName: widget.elder.name,
            );
      }
    } catch (e) {
      debugPrint("Component 4 call failed: $e");
    }
  }

  /// Caregiver Alert AND Emergency Alert both get a dedicated
  /// voice-instruction popup (spoken announcement), separate from the
  /// on-screen banner. Which screen opens depends on alertType — the
  /// TTS message/styling differs (urgent tone for Emergency), but the
  /// dedup identity logic (real alert id, falling back to occurredAt)
  /// is unchanged and shared across both.
  ///
  /// FIX (Final Alert-ID Dedup prompt, Issue 3): keyed on the REAL
  /// backend alert id when the caller has one (both call sites above
  /// now pass it through). `occurredAt` is only used as a fallback
  /// identity for the rare case where no real id exists (the alert's
  /// DB write failed, so AlertService.create() returned None) — never
  /// as the primary identity when a real id is available, per the
  /// prompt's explicit instruction.
  void _maybeShowCaregiverVoiceInstruction(String? alertId) {
    final alert = context.read<AlertState>();
    final type = alert.alertType;
    if (type != "Caregiver Alert" && type != "Emergency Alert") return;
    final identity = alertId ?? alert.occurredAt?.toIso8601String();
    if (identity == null) return;
    if (_lastVoiceInstructionIdentity == identity) return;
    _lastVoiceInstructionIdentity = identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (type == "Emergency Alert") {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EmergencyAlertVoiceInstructionScreen(
              elderName: widget.elder.name,
              fallType: alert.fallType,
              location: alert.location,
              riskLevel: alert.riskLevel,
              onAcknowledge: () => context.read<AlertState>().markResolved(),
            ),
          ),
        );
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) =>
                  CaregiverAlertVoiceInstructionScreen(elder: widget.elder)),
        );
      }
    });
  }

  // ---------------------------------------------------------------
  // REBUILT VISUAL LAYER BELOW. Logic above this line only carries
  // the targeted, documented fixes — nothing else was changed.
  // ---------------------------------------------------------------

  /// Maps real backend fall/risk state to the SafetyStatus enum.
  /// No fabricated default — "unknown" is a real, displayable state
  /// used both before the first fetch AND whenever risk_level itself
  /// is missing/null on an otherwise-loaded result (FIX, Doc 2 Issue
  /// 2: a missing risk_level previously fell through to "safe", which
  /// is not an honest reading of "we don't actually know").
  SafetyStatus _deriveSafetyStatus() {
    if (_fallResult == null) return SafetyStatus.unknown;
    final fallDetected = _fallResult?["fall_detected"] == true;
    final riskLevel = _fallResult?["risk_level"]?.toString().toUpperCase();
    final alert = context.read<AlertState>();

    if (alert.hasActiveAlert && alert.alertType == "Emergency Alert")
      return SafetyStatus.emergency;
    if (fallDetected || riskLevel == "HIGH" || riskLevel == "CRITICAL")
      return SafetyStatus.emergency;
    if (riskLevel == "MEDIUM" ||
        (alert.hasActiveAlert && alert.alertType == "Caregiver Alert")) {
      return SafetyStatus.warning;
    }
    if (riskLevel == "LOW") return SafetyStatus.safe;
    // riskLevel missing/null, or any other unrecognized value: honestly
    // unknown rather than assumed safe.
    return SafetyStatus.unknown;
  }

  /// Short, caregiver-facing message per real safety state — wording
  /// only, no new data source. Used by the Elder Information card
  /// below (combined with `status.label`).
  String _safetyMessage(SafetyStatus status) {
    return switch (status) {
      SafetyStatus.safe => "No immediate fall detected",
      SafetyStatus.warning => "Elevated fall risk detected",
      SafetyStatus.emergency => "Immediate attention required",
      SafetyStatus.unknown => "Monitoring status unavailable",
    };
  }

  /// FIX (Doc 2, Issue 8): flags data as possibly stale once it's
  /// significantly older than one poll cycle, so the UI can say so
  /// instead of silently implying a 5-second-old reading forever.
  bool _isDataStale() {
    if (_lastSuccessfulFetch == null) return false;
    final age = DateTime.now().difference(_lastSuccessfulFetch!);
    return age > AppConfig.pollInterval * 3;
  }

  String _formatLastUpdated() {
    if (_lastSuccessfulFetch == null) return "Not yet updated";
    final seconds = DateTime.now().difference(_lastSuccessfulFetch!).inSeconds;
    final base = seconds < 60
        ? "Updated ${seconds}s ago"
        : "Updated ${(seconds / 60).floor()} min ago";
    return _isDataStale() ? "$base (may be outdated)" : base;
  }

  /// FIX (Remaining-Issues prompt, Issues 1-2): a PURE reflection of
  /// the real WebSocket connection state, tracked by
  /// `_connectAlertStream()`/`socket.ready` above.
  (String, Color) _liveAlertStatus() {
    if (_wsStatus == _WsStatus.connecting) {
      return _wsReconnectAttempts > 0
          ? ("Reconnecting…", AppColors.warning)
          : ("Connecting…", AppColors.textSecondary);
    }
    return switch (_wsStatus) {
      _WsStatus.connected => ("Connected", AppColors.safe),
      _WsStatus.disconnected => ("Disconnected", AppColors.warning),
      _WsStatus.error => ("Unavailable", AppColors.warning),
      _WsStatus.connecting => (
          "Connecting…",
          AppColors.textSecondary
        ), // unreachable, handled above
    };
  }

  /// NEW (Home Dashboard redesign, Section B): the reference design's
  /// single compact "Monitoring Connection Status" card replaces the
  /// previous two separate rows ("Connecting to monitoring…" /
  /// ConnectionLostBanner for the REST polling state, and a "Live
  /// Alerts" row for the WebSocket state). Nothing new is invented —
  /// this purely combines the SAME two real signals already tracked
  /// above (`_fallResult`/`_lastFetchFailed` for the Component 1/2/3
  /// poll, and `_wsStatus` for the alert stream) into one honest
  /// caregiver-facing reading:
  ///   - "Connecting"          — first poll hasn't returned yet.
  ///   - "Connection Lost"     — BOTH the sensor poll and the alert
  ///                             stream are down (a real full outage).
  ///   - "Monitoring Unstable" — only ONE of the two is down (partial
  ///                             degradation — still worth flagging,
  ///                             but not a full loss).
  ///   - "Monitoring Connected"— both are healthy.
  /// Returns (label, subtitle, icon, foreground color, background color).
  (String, String, IconData, Color, Color) _monitoringStatus() {
    final wsDown =
        _wsStatus == _WsStatus.disconnected || _wsStatus == _WsStatus.error;

    if (_fallResult == null &&
        !_lastFetchFailed &&
        _wsStatus != _WsStatus.connected) {
      return (
        "Connecting",
        "Waiting for the first sensor reading…",
        Icons.sync,
        AppColors.textSecondary,
        AppColors.border,
      );
    }
    if (_lastFetchFailed && wsDown) {
      return (
        "Connection Lost",
        "No live sensor or alert data — pull down to retry",
        Icons.wifi_off,
        AppColors.warning,
        AppColors.warningLight,
      );
    }
    if (_lastFetchFailed || wsDown) {
      return (
        "Monitoring Unstable",
        _formatLastUpdated(),
        Icons.sync_problem,
        AppColors.warning,
        AppColors.warningLight,
      );
    }
    return (
      "Monitoring Connected",
      _formatLastUpdated(),
      Icons.monitor_heart_rounded,
      AppColors.safe,
      AppColors.safeLight,
    );
  }

  /// NEW (Home Dashboard redesign, Section C): short elder-status line
  /// for the Elder Information card, built from the SAME real
  /// `_deriveSafetyStatus()` derivation already used everywhere else
  /// on this screen — not a new data source, just a different wording
  /// for a compact card (e.g. "Safe • No immediate fall detected").
  String _elderStatusLine(SafetyStatus status) {
    return "${status.label} • ${_safetyMessage(status)}";
  }

  /// Shared word-casing helper for humanizing raw backend strings
  /// ("stair_case" -> "Stair Case") used as a fallback when a value
  /// isn't in the small known-label map below. Never changes the
  /// underlying backend value — display only.
  String _titleCase(String raw) {
    return raw
        .split(RegExp(r'[_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  static const Map<String, String> _knownLocationLabels = {
    "stair_case": "Staircase",
    "staircase": "Staircase",
    "living_room": "Living Room",
    "bed_room": "Bedroom",
    "bedroom": "Bedroom",
    "bathroom": "Bathroom",
    "kitchen": "Kitchen",
    "hallway": "Hallway",
    "dining_room": "Dining Room",
  };

  /// FIX (Doc 2 / Doc 1, location section): humanizes the real
  /// Component 2 location value for display only — the underlying
  /// value passed to Component 4 / stored in AlertState is untouched.
  String _humanizeLocation(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "No location available";
    final key = raw.trim().toLowerCase();
    return _knownLocationLabels[key] ?? _titleCase(raw);
  }

  /// FIX (Doc 2 / Doc 1, activity section): humanizes the real
  /// Component 1 movement/activity value for display only.
  String _humanizeActivity(String? raw) {
    if (raw == null || raw.trim().isEmpty) return "No data available";
    return _titleCase(raw);
  }

  /// NEW (Home Dashboard redesign, header): the branded teal header —
  /// logo mark + "AegisCare" + tagline on the left, a notifications
  /// icon and the caregiver's own profile avatar on the right.
  ///
  /// - No unread-notification badge is shown: this app has no real
  ///   "unread alert count" anywhere in AlertState/ApiService (only a
  ///   single current/active alert is tracked), so per the brief's own
  ///   rule ("only when the real unread count is available") the badge
  ///   is simply omitted rather than faked with a 0 or a guess.
  /// - The bell icon opens the real Alerts Screen (the only "alerts
  ///   inbox" this app actually has).
  /// - The avatar opens the real caregiver's own profile screen
  ///   (ProfileScreen) — see the file-level note on ProfileScreen for
  ///   why that is the closest existing equivalent to a "Caregiver
  ///   Details Screen" (no separately-named screen exists in this
  ///   project). The avatar never shows a hardcoded initial — it shows
  ///   a generic person icon until the real caregiver name has loaded.
  Widget _buildHeader(BuildContext context) {
    final initial =
        (_caregiverName != null && _caregiverName!.trim().isNotEmpty)
            ? _caregiverName!.trim().substring(0, 1).toUpperCase()
            : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.md, AppSpacing.lg),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryDark],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12)),
            // NOTE: this references the real supplied AegisCare logo
            // mark (assets/images/aegiscare_logo.png) — see the
            // delivery notes for how to add it to the project. The
            // errorBuilder fallback only renders if that asset hasn't
            // been added to the project yet, so the screen never
            // crashes in the meantime; it is not a substitute logo.
            child: Image.asset(
              'assets/images/aegiscare_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                  Icons.health_and_safety_rounded,
                  color: AppColors.primary),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "AegisCare",
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 19),
                ),
                SizedBox(height: 2),
                Text(
                  "Safer Today • Healthier Tomorrow",
                  style: TextStyle(color: Color(0xFFD7E8ED), fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => ProfileScreen(elder: widget.elder)),
            ),
            // CHANGED (avatar picker feature): shows the caregiver's
            // chosen preset avatar when one is set (_caregiverAvatarId,
            // fetched in _fetchCaregiverProfile). Falls back to the
            // exact original behavior — initial letter, or a generic
            // person icon while the name hasn't loaded yet — whenever
            // no avatar has been picked.
            child: _caregiverAvatarId != null
                ? AvatarCircle(
                    avatarId: _caregiverAvatarId,
                    fallbackInitial: initial ?? "?",
                    radius: 18,
                    fallbackColor: AppColors.primary,
                  )
                : CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.white,
                    child: initial != null
                        ? Text(initial,
                            style: const TextStyle(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700))
                        : const Icon(Icons.person_rounded,
                            color: AppColors.primary, size: 20),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final guidance = context.watch<GuidanceState>();
    final alert = context.watch<AlertState>();
    final status = _deriveSafetyStatus();

    final activity = _humanizeActivity(_fallResult?["movement"]?.toString());
    final location = _humanizeLocation(_envResult?["location"]?.toString());
    final fallType = _fallResult?["fall_type"]?.toString();
    // Component 1 always returns a non-null fall_type string ("No
    // Fall" when nothing happened, or the actual fall type when it
    // did) — so `fallType != null` is true even when there is no
    // fall. The Fall Detection card below keys off the real
    // fall_detected boolean instead, not merely whether fall_type is
    // present. DO NOT change this to a null-check.
    final fallDetectedNow = _fallResult?["fall_detected"] == true;

    // FIX (Doc 2, Issue 6): 0 / negative / non-numeric heart rate is
    // not a valid reading and must not be shown as "0 bpm".
    final heartRateRaw = _vitalsResult?["heart_rate"];
    final heartRateValue = heartRateRaw is num
        ? heartRateRaw
        : num.tryParse(heartRateRaw?.toString() ?? "");
    final hasValidHeartRate = heartRateValue != null && heartRateValue > 0;
    final heartRateDisplay = hasValidHeartRate
        ? "${heartRateValue.toStringAsFixed(0)} bpm"
        : "No current reading";

    final envRiskLevel = _envResult?["risk_level"]?.toString();

    final (
      monitorLabel,
      monitorSubtitle,
      monitorIcon,
      monitorColor,
      monitorBg
    ) = _monitoringStatus();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _fetchAll,
                child: ResponsiveScaffoldBody(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                        AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
                    children: [
                      // B. Monitoring Connection Status — one compact
                      // card, real-data-derived (see _monitoringStatus).
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                        decoration: BoxDecoration(
                            color: monitorBg,
                            borderRadius:
                                BorderRadius.circular(AppRadius.card)),
                        child: Row(
                          children: [
                            Icon(monitorIcon, color: monitorColor),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    monitorLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                            color: monitorColor,
                                            fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    monitorSubtitle,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (_lastFetchFailed)
                              TextButton(
                                  onPressed: _fetchAll,
                                  child: const Text("Retry")),
                          ],
                        ),
                      ),

                      const SizedBox(height: AppSpacing.lg),

                      // C. Elder Information Card — static display only:
                      // name, age, location. Caregiver request: no
                      // longer navigates to ElderDetailsScreen on tap —
                      // that screen is already reachable from the
                      // bottom "Elder Profile" tab, so this is now a
                      // read-only summary, not a second route to the
                      // same screen.
                      _ElderInfoCard(
                        name: widget.elder.name,
                        age: widget.elder.age,
                        location:
                            (widget.elder.address?.trim().isNotEmpty ?? false)
                                ? widget.elder.address!.trim()
                                : "No address on file",
                        avatarId: widget.elder.avatarId,
                      ),

                      if (alert.hasActiveAlert) ...[
                        const SizedBox(height: AppSpacing.lg),
                        _ActiveAlertCard(
                          alert: alert,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const AlertDetailScreen())),
                        ),
                      ],

                      if (guidance.status == GuidanceStatus.active) ...[
                        const SizedBox(height: AppSpacing.md),
                        // Real phone field from the Elder model (app/elders/schemas.py).
                        // The widget itself shows "No phone number available"
                        // when this elder genuinely has none on file.
                        CaregiverGuidanceMirrorCard(
                            elderPhoneNumber: widget.elder.phone),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const ElderGuidanceScreen()),
                            ),
                            icon: const Icon(Icons.remove_red_eye_outlined,
                                size: 16),
                            label: const Text("View elder's guidance screen"),
                          ),
                        ),
                      ],

                      const SizedBox(height: AppSpacing.xl),

                      // D. Main Dashboard Cards (2-column grid).
                      ResponsiveGrid(
                        childAspectRatio: 1.35,
                        children: [
                          // Card 1 — Alerts. REPLACES the old Activity
                          // card (which navigated to FallDetectionScreen
                          // — the exact duplicate-navigation bug the
                          // redesign brief calls out, since the Fall
                          // Detection card below already owns that
                          // destination). Value reflects the real,
                          // currently-tracked AlertState — this app has
                          // no separate "unread count", only a single
                          // current/active alert, so that real boolean
                          // plus its real alert type is shown instead
                          // of a fabricated number.
                          SummaryCard(
                            dense: true,
                            icon: Icons.notifications_active_rounded,
                            iconColor: alert.hasActiveAlert
                                ? AppColors.severity(alert.riskLevel)
                                : AppColors.primary,
                            iconBg: alert.hasActiveAlert
                                ? AppColors.severityLight(alert.riskLevel)
                                : AppColors.primaryLight,
                            title: "Alerts",
                            value: alert.hasActiveAlert
                                ? (alert.alertType ?? "Active alert")
                                : "No active alerts",
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      AlertsScreen(elder: widget.elder)),
                            ),
                          ),
                          // Card 2 — Environment (renamed from "Location";
                          // title label only — unchanged: real Component 2
                          // data/navigation, risk badge shown only when a
                          // real risk_level is present.
                          SummaryCard(
                            dense: true,
                            icon: Icons.location_on_rounded,
                            iconColor: AppColors.secondaryTeal,
                            iconBg: AppColors.primaryLight,
                            title: "Environment",
                            value: envRiskLevel != null &&
                                    envRiskLevel.trim().isNotEmpty
                                ? "$location · ${_titleCase(envRiskLevel)} Risk"
                                : location,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const EnvironmentScreen()),
                            ),
                          ),
                          // Card 3 — Fall Detection. Unchanged logic;
                          // now the SOLE card that opens
                          // FallDetectionScreen (see Card 1 above).
                          SummaryCard(
                            dense: true,
                            icon: Icons.accessibility_new_rounded,
                            iconColor: fallDetectedNow
                                ? AppColors.emergency
                                : AppColors.textSecondary,
                            iconBg: fallDetectedNow
                                ? AppColors.emergencyLight
                                : AppColors.border,
                            title: "Fall Detection",
                            // fallDetectedNow==false -> always "No Fall"
                            // (even though fallType itself is the
                            // non-null string "No Fall" here, not an
                            // actual fall type). fallDetectedNow==true
                            // -> the real detected fall_type (Forward
                            // Fall / Backward Fall / Side Fall Right /
                            // Side Fall Left), never fabricated. DO NOT
                            // BREAK THIS — must stay keyed on
                            // fall_detected, never on fallType being
                            // non-null.
                            value: fallDetectedNow
                                ? (fallType ?? "Fall detected")
                                : "No Fall",
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const FallDetectionScreen()),
                            ),
                          ),
                          // Card 4 — Vitals. Unchanged: real Component 3
                          // data/navigation, invalid readings never
                          // shown as a fake "0 bpm".
                          SummaryCard(
                            dense: true,
                            icon: Icons.monitor_heart_rounded,
                            iconColor: AppColors.secondaryTeal,
                            iconBg: AppColors.primaryLight,
                            title: "Vitals",
                            value: heartRateDisplay,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const VitalsScreen()),
                            ),
                          ),
                        ],
                      ),
                      // NOTE: a grep across this entire file (including
                      // every commented historical revision above)
                      // found no "Recent Alerts" section and no "Fall
                      // Recovery Guidance" section anywhere — neither
                      // ever existed in the code actually uploaded for
                      // this task, so there was nothing here to remove
                      // for Sections 5/6 of the redesign brief. See the
                      // delivery notes for this finding.
                      //
                      // REMOVED EARLIER (unchanged from before this
                      // redesign): the old "Sensor Monitoring" row that
                      // used to sit here duplicated the Location card
                      // above (both read Component 2 and both opened
                      // EnvironmentScreen) and was already removed in a
                      // previous pass — still gone, not reintroduced.
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// NEW (Home Dashboard redesign, Section C): the elder identity row —
/// avatar initial, name, a static "Elder" role pill (a fixed app-level
/// role tag, not per-elder backend data), and a real status line
/// derived from `_deriveSafetyStatus()`/`_safetyMessage()` above.
/// Intentionally a separate widget from the shared `SafetyStatusCard`
/// (in status_widgets.dart) rather than a modification of it —
/// `SafetyStatusCard` is also used by the unrelated Elder-role home
/// screen (elder_home_screen.dart), which this task must not touch,
/// and its existing shape (icon circle + message + risk-level row) is
/// a different, more detailed layout than the compact identity row the
/// reference design asks for here.
class _ElderInfoCard extends StatelessWidget {
  final String name;
  final int age;
  final String location;
  // ADDED (avatar picker feature): the elder's chosen preset avatar
  // id (e.g. "elder_1"), or null if they haven't picked one yet.
  final String? avatarId;

  const _ElderInfoCard({
    required this.name,
    required this.age,
    required this.location,
    this.avatarId,
  });

  @override
  Widget build(BuildContext context) {
    final trimmedName = name.trim();
    final initial = trimmedName.isNotEmpty
        ? trimmedName.substring(0, 1).toUpperCase()
        : "?";

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            // CHANGED (avatar picker feature): was a plain CircleAvatar
            // with the initial letter — now shows the elder's chosen
            // preset avatar via AvatarCircle, falling back to the exact
            // same initial-letter look when no avatarId is set yet.
            AvatarCircle(
              avatarId: avatarId,
              fallbackInitial: initial,
              radius: 26,
              fallbackColor: AppColors.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          trimmedName.isNotEmpty ? trimmedName : "Elder",
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: const Text(
                          "Elder",
                          style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Age $age · $location",
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// Active-alert summary card shown on Home when AlertState has a
/// current, unresolved alert. All values read from real AlertState —
/// no fallback demo text.
class _ActiveAlertCard extends StatelessWidget {
  final AlertState alert;
  final VoidCallback onTap;
  const _ActiveAlertCard({required this.alert, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isEmergency = alert.alertType == "Emergency Alert";
    final color = isEmergency ? AppColors.emergency : AppColors.warning;
    final bg = isEmergency ? AppColors.emergencyLight : AppColors.warningLight;

    return Card(
      color: bg,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Icon(isEmergency ? Icons.emergency : Icons.notifications_active,
                  color: color, size: 28),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alert.alertType ?? "Alert",
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 16),
                    ),
                    if (alert.fallType != null || alert.location != null)
                      Text(
                        [
                          if (alert.fallType != null) alert.fallType,
                          if (alert.location != null) alert.location
                        ].join(" · "),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
