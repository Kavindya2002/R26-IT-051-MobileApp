import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import 'emergency_alert_detail_screen.dart';
import 'emergency_alert_voice_instruction_screen.dart';

/// The Emergency Person's read-only alert feed for one elder.
///
/// Deliberately shows ONLY "Emergency Alert" type entries — Voice
/// and Caregiver Alerts are not this role's concern (see the
/// least-privilege design discussed for this role). Combines the
/// real history endpoint (already filtered server-side by
/// alert_type) with the same WebSocket channel the Caregiver
/// dashboard uses, filtering client-side for Emergency Alert only
/// since the socket itself broadcasts every alert type for the elder.
///
/// HARDENING PASS (final review):
///   - Elder ID is now validated before any API/WebSocket call —
///     an empty/missing id no longer gets stringified into the
///     literal "null" and sent to the backend; it now shows a clear
///     message instead.
///   - History + WebSocket alerts are deduplicated by real alert ID
///     (falling back to a best-effort composite key only when an id
///     is genuinely absent), so the same alert never appears twice
///     even though it can legitimately arrive from both sources.
///   - The in-memory list is bounded to 100 entries so a long-running
///     session doesn't grow without limit; this only trims what's
///     shown on this device, never anything on the backend.
///   - The WebSocket now reconnects on close/error with a bounded,
///     non-zero delay instead of just logging and going silent, and
///     a small connection-status indicator reflects connected /
///     reconnecting / unavailable. All socket/timer resources are
///     cancelled in dispose(), and no reconnect or setState is ever
///     attempted after the widget is disposed.
///   - Pull-to-refresh no longer blanks an already-populated list —
///     the loading spinner only takes over the whole screen on the
///     very first load.
///   - Fall type and location are now humanized through small, honest
///     helpers (never a raw snake_case value, never a bare "-"), and
///     the timestamp is parsed safely with a "Time unavailable"
///     fallback — never DateTime.now() standing in for a missing one.
///   - The card layout now gives fall type, location, and timestamp
///     each their own line (matching the requested information
///     hierarchy) instead of combining fields on one line, and wraps
///     text with Expanded/ellipsis so long values can't overflow.
///
/// TTS ADDITION: every genuinely NEW Emergency Alert that arrives over
/// the live WebSocket feed (not a history load, not a duplicate/replay
/// — `_insertIfNew` already guarantees that) now also opens the same
/// EmergencyAlertVoiceInstructionScreen the Caregiver Dashboard uses,
/// so the Emergency Person is alerted by voice too, not just by the
/// on-screen list. No backend, Component 1-4, or WebSocket
/// architecture changes — this remains a pure consumer of the
/// existing history API and alert stream.
enum _LiveStatus { connected, reconnecting, unavailable }

// Reusable, honest humanization — only ever a known mapping or an
// explicit "unavailable" fallback, never a guessed/title-cased raw
// value and never a raw snake_case string shown to the user.
String _humanizeFallType(dynamic raw) {
  final value = raw?.toString().trim() ?? "";
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

String _humanizeLocation(dynamic raw) {
  final value = raw?.toString().trim() ?? "";
  return value.isEmpty ? "Location unavailable" : value;
}

String _formatAlertTime(dynamic raw) {
  final dt = DateTime.tryParse(raw?.toString() ?? "")?.toLocal();
  if (dt == null) return "Time unavailable";
  return DateFormat("MMM d, h:mm a").format(dt);
}

bool _isEmergencyAlert(Map<String, dynamic> alert) =>
    alert["alert_type"] == "Emergency Alert";

// Prefers the real backend alert ID; only falls back to a composite
// key (fall type + location + timestamp) on the rare chance an id is
// genuinely missing, so de-dup never silently drops a legitimately
// distinct alert that happens to share a real ID with another.
String _extractAlertId(Map<String, dynamic> alert) {
  final id = alert["id"]?.toString().trim();
  if (id != null && id.isNotEmpty) return "id:$id";
  final fallType = alert["fall_type"]?.toString() ?? "";
  final location = alert["location"]?.toString() ?? "";
  final createdAt = alert["created_at"]?.toString() ?? "";
  return "composite:$fallType|$location|$createdAt";
}

class EmergencyAlertsFeedScreen extends StatefulWidget {
  final Map<String, dynamic> elder;
  const EmergencyAlertsFeedScreen({super.key, required this.elder});

  @override
  State<EmergencyAlertsFeedScreen> createState() =>
      _EmergencyAlertsFeedScreenState();
}

class _EmergencyAlertsFeedScreenState extends State<EmergencyAlertsFeedScreen> {
  static const int _maxAlerts = 100;

  final List<Map<String, dynamic>> _alerts = [];
  final Set<String> _alertKeys = {};

  bool _loading = true;
  bool _loadInFlight = false;
  String? _error;

  _LiveStatus _liveStatus = _LiveStatus.unavailable;
  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  String get _elderId {
    final raw = widget.elder["id"];
    if (raw == null) return "";
    return raw.toString().trim();
  }

  bool get _hasValidElderId => _elderId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
    if (_hasValidElderId) _connectLiveFeed();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _socketSub?.cancel();
    _socket?.sink.close();
    super.dispose();
  }

  void _setAlerts(List<Map<String, dynamic>> alerts) {
    _alerts
      ..clear()
      ..addAll(alerts);
    _alertKeys
      ..clear()
      ..addAll(alerts.map(_extractAlertId));
  }

  // Returns true if the alert was genuinely new and inserted.
  bool _insertIfNew(Map<String, dynamic> alert) {
    final key = _extractAlertId(alert);
    if (_alertKeys.contains(key)) return false;
    _alertKeys.add(key);
    _alerts.insert(0, alert);
    while (_alerts.length > _maxAlerts) {
      final removed = _alerts.removeLast();
      _alertKeys.remove(_extractAlertId(removed));
    }
    return true;
  }

  Future<void> _load() async {
    // Prevents rapid repeated taps (pull-to-refresh / retry) from
    // firing overlapping history requests.
    if (_loadInFlight) return;
    _loadInFlight = true;

    if (!mounted) {
      _loadInFlight = false;
      return;
    }
    setState(() {
      _error = null;
      // Only take over the whole screen with a spinner on the very
      // first load — a pull-to-refresh with existing data stays
      // visible underneath the RefreshIndicator instead of blanking.
      if (_alerts.isEmpty) _loading = true;
    });

    if (!_hasValidElderId) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Unable to load emergency alerts for this elder.";
        });
      }
      _loadInFlight = false;
      return;
    }

    try {
      final raw = await ApiService.instance.getAlertHistory(
        _elderId,
        alertType: "Emergency Alert",
      );
      final alerts = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where(_isEmergencyAlert)
          .toList();
      alerts.sort((a, b) {
        final da = DateTime.tryParse(a["created_at"]?.toString() ?? "");
        final db = DateTime.tryParse(b["created_at"]?.toString() ?? "");
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da); // newest first
      });
      if (!mounted) return;
      setState(() {
        _setAlerts(alerts);
        _loading = false;
      });
    } catch (e) {
      debugPrint("Emergency alert history load failed: $e");
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Please check your connection and try again.";
      });
    } finally {
      _loadInFlight = false;
    }
  }

  void _connectLiveFeed() {
    if (_disposed || !_hasValidElderId) return;
    _reconnectTimer?.cancel();
    try {
      final socket = ApiService.instance.connectAlertStream(_elderId);
      _socket = socket;
      _socketSub = socket.stream.listen(
        _handleSocketMessage,
        onDone: _handleSocketClosed,
        onError: (Object e) {
          debugPrint("Emergency alert stream error: $e");
          _handleSocketClosed();
        },
        cancelOnError: true,
      );
      _reconnectAttempts = 0;
      if (mounted) setState(() => _liveStatus = _LiveStatus.connected);
    } catch (e) {
      debugPrint("Could not connect emergency alert stream: $e");
      _handleSocketClosed();
    }
  }

  void _handleSocketMessage(dynamic raw) {
    try {
      final message = jsonDecode(raw as String);
      if (message is! Map ||
          message["type"] != "alert" ||
          message["alert"] == null) return;
      final rawAlert = message["alert"];
      if (rawAlert is! Map) return;
      final alert = Map<String, dynamic>.from(rawAlert);
      if (!_isEmergencyAlert(alert)) return; // not this role's concern
      if (!mounted) return;
      final isNew = _insertIfNew(alert);
      setState(() {});
      // Only speak for a genuinely new alert — a history re-send or a
      // reconnect replay (already filtered out by `_insertIfNew`
      // returning false for a key already seen) must never re-trigger
      // the voice popup.
      if (isNew) _showVoicePopup(alert);
    } catch (e) {
      debugPrint("Emergency feed message parse failed: $e");
    }
  }

  /// Opens the same voice-instruction popup the Caregiver Dashboard
  /// uses for Emergency Alert, so the Emergency Person is alerted by
  /// voice here too — not just by the on-screen card. No AlertState
  /// dependency: this screen never touches AlertState (that is the
  /// Caregiver Dashboard's own state), so the alert's own fields are
  /// passed directly.
  void _showVoicePopup(Map<String, dynamic> alert) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EmergencyAlertVoiceInstructionScreen(
            elderName: widget.elder["name"]?.toString() ?? "Elder",
            fallType: alert["fall_type"]?.toString(),
            location: alert["location"]?.toString(),
            riskLevel: alert["risk_level"]?.toString(),
          ),
        ),
      );
    });
  }

  void _handleSocketClosed() {
    _socketSub?.cancel();
    _socketSub = null;
    _socket = null;
    if (_disposed || !mounted) return;
    setState(() => _liveStatus = _LiveStatus.reconnecting);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    // Controlled, bounded retry — never continuous/zero-delay.
    final delaySeconds = _reconnectAttempts >= 5 ? 15 : 4;
    if (_reconnectAttempts >= 5 && mounted) {
      // After repeated failures, be honest that live updates are
      // currently unavailable rather than showing "Reconnecting…"
      // forever; a background retry keeps trying regardless.
      setState(() => _liveStatus = _LiveStatus.unavailable);
    }
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_disposed) return;
      _connectLiveFeed();
    });
  }

  Widget _buildLiveStatus() {
    final String label;
    final Color color;
    switch (_liveStatus) {
      case _LiveStatus.connected:
        label = "Live updates connected";
        color = AppColors.safe;
        break;
      case _LiveStatus.reconnecting:
        label = "Reconnecting…";
        color = AppColors.warning;
        break;
      case _LiveStatus.unavailable:
        label = "Live updates unavailable";
        color = AppColors.textSecondary;
        break;
    }
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildAlertCard(BuildContext context, Map<String, dynamic> alert) {
    final fallType = _humanizeFallType(alert["fall_type"]);
    final location = _humanizeLocation(alert["location"]);
    final time = _formatAlertTime(alert["created_at"]);
    final elderName = widget.elder["name"]?.toString() ?? "Elder";

    return Semantics(
      button: true,
      label:
          "Emergency Alert. $fallType. $location. $time. Tap to view details.",
      child: Card(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.critical, width: 1.2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => EmergencyAlertDetailScreen(
                alert: alert,
                elderName: elderName,
                elderAddress: widget.elder["address"]?.toString(),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.emergency,
                        color: AppColors.critical, size: 22),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "Emergency Alert",
                        style: TextStyle(
                            color: AppColors.critical,
                            fontWeight: FontWeight.bold,
                            fontSize: 15),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right,
                        color: AppColors.textMuted, size: 20),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  fallType,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.location_on,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        location,
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.access_time,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        time,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final elderName = widget.elder["name"]?.toString() ?? "Elder";

    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      appBar: const AegisAppBar(title: "Emergency Alerts", showLogo: false),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ListView(
                    // ListView (not Center) so RefreshIndicator still
                    // works even while an error is showing.
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 80),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.cloud_off,
                                size: 40, color: AppColors.textMuted),
                            const SizedBox(height: 12),
                            Text("Unable to load emergency alerts",
                                style: Theme.of(context).textTheme.titleMedium,
                                textAlign: TextAlign.center),
                            const SizedBox(height: 8),
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: 16),
                            OutlinedButton(
                                onPressed: _load,
                                child: const Text("Try again")),
                          ],
                        ),
                      ),
                    ],
                  )
                : _alerts.isEmpty
                    ? ListView(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 32, vertical: 80),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.shield_outlined,
                                    size: 48, color: AppColors.low),
                                const SizedBox(height: 16),
                                Text("No emergency alerts",
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                    textAlign: TextAlign.center),
                                const SizedBox(height: 6),
                                Text(
                                  "There are currently no emergency alerts for this elder.",
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(20),
                        itemCount: _alerts.length + 2,
                        separatorBuilder: (_, i) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Elder: $elderName",
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  _buildLiveStatus(),
                                ],
                              ),
                            );
                          }
                          if (i == 1) return const SizedBox(height: 6);
                          return _buildAlertCard(context, _alerts[i - 2]);
                        },
                      ),
      ),
    );
  }
}
