import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';

/// Thrown whenever the backend returns a non-2xx response.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);

  @override
  String toString() => "ApiException($statusCode): $message";
}

/// One place for every HTTP call to the FastAPI backend.
/// Mirrors the routers found in the backend's `app/` folder:
///   /users, /elders, /component1, /component2, /component3,
///   /component4, /integration
class ApiService {
  ApiService._internal();
  static final ApiService instance = ApiService._internal();

  String? _accessToken;

  Uri _u(String path) => Uri.parse("${AppConfig.baseUrl}$path");

  Map<String, String> _headers({bool auth = true}) {
    final headers = {"Content-Type": "application/json"};
    if (auth && _accessToken != null) {
      headers["Authorization"] = "Bearer $_accessToken";
    }
    return headers;
  }

  Future<void> loadTokenFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString("access_token");
  }

  Future<void> _saveToken(String token) async {
    _accessToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("access_token", token);
  }

  Future<void> logout() async {
    _accessToken = null;
    cachedProfile = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("access_token");
  }

  bool get isLoggedIn => _accessToken != null;

  dynamic _decode(http.Response res) {
    final body = res.body.isNotEmpty ? jsonDecode(res.body) : null;
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body;
    }
    final msg = (body is Map && body["detail"] != null)
        ? body["detail"].toString()
        : "Request failed (${res.statusCode})";
    throw ApiException(res.statusCode, msg);
  }

  // ---------------- USERS ----------------

  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String phone,
    required String role, // "CAREGIVER" or "EMERGENCY_PERSON"
    String? address,
    String? relationship,
    int priority = 1,
  }) async {
    final res = await http.post(
      _u("/users/register"),
      headers: _headers(auth: false),
      body: jsonEncode({
        "name": name,
        "email": email,
        "password": password,
        "phone": phone,
        "role": role,
        "address": address,
        "relationship": relationship,
        "priority": priority,
      }),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final res = await http.post(
      _u("/users/login"),
      headers: _headers(auth: false),
      body: jsonEncode({"email": email, "password": password}),
    );
    final data = _decode(res);

    // Adjust this key if your Supabase auth response nests the token
    // differently, e.g. data["session"]["access_token"].
    final token = data["access_token"] ??
        (data["session"] != null ? data["session"]["access_token"] : null);
    if (token != null) {
      await _saveToken(token);
    }
    return data;
  }


  /// Current ELDER-role user's own linked elder record - used by
  /// LoginScreen/SplashScreen to route an ELDER-role account to
  /// ElderHomeScreen. Mirrors getMyProfile()'s '/users/me' pattern.
  Future<Map<String, dynamic>> getMyElderProfile() async {
    final res = await http.get(_u("/elders/me"), headers: _headers());
    return _decode(res);
  }
  // ADDED (avatar header fix): the logged-in user's own profile,
  // cached in memory the first time getMyProfile() succeeds anywhere
  // in the app (e.g. ProfileScreen). HomeDashboardScreen's header
  // reads this synchronously in initState so it can show the right
  // avatar immediately on repeat visits, instead of always showing a
  // generic icon for the brief moment before its own network fetch
  // resolves. Cleared on logout so a new login doesn't see stale data.
  Map<String, dynamic>? cachedProfile;

  Future<Map<String, dynamic>> getMyProfile() async {
    final res = await http.get(_u("/users/me"), headers: _headers());
    final data = _decode(res);
    if (data is Map && data["user"] is Map) {
      cachedProfile = Map<String, dynamic>.from(data["user"]);
    }
    return data;
  }

  Future<Map<String, dynamic>> updateMyProfile(Map<String, dynamic> fields) async {
    final res = await http.put(
      _u("/users/me"),
      headers: _headers(),
      body: jsonEncode(fields),
    );
    return _decode(res);
  }

  // ---------------- ELDERS ----------------

  Future<List<dynamic>> listElders() async {
    final res = await http.get(_u("/elders"), headers: _headers());
    final data = _decode(res);
    return data is List ? data : (data["result"] ?? data["results"] ?? data["elders"] ?? []);
  }

  Future<Map<String, dynamic>> createElder({
    required String name,
    required int age,
    int previousFalls = 0,
    String assistiveDevice = "none",
    String? address,
    String? phone,
    String? gender,
    // ADDED (avatar picker feature): the id of a preset avatar chosen
    // in the Add Elder form (e.g. "elder_1"). Optional — null means
    // the elder is created without an avatar, same as before.
    String? avatarId,
    bool grantLogin = false,
    String? loginEmail,
  }) async {
    final res = await http.post(
      _u("/elders"),
      headers: _headers(),
      body: jsonEncode({
        "name": name,
        "age": age,
        "previous_falls": previousFalls,
        "assistive_device": assistiveDevice,
        "address": address,
        "phone": phone,
        "gender": gender,
        if (avatarId != null) "avatar_id": avatarId,
        if (grantLogin) "grant_login": true,
        if (grantLogin) "login_email": loginEmail,
      }),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> updateElder(String elderId, Map<String, dynamic> fields) async {
    final res = await http.put(
      _u("/elders/$elderId"),
      headers: _headers(),
      body: jsonEncode(fields),
    );
    return _decode(res);
  }

  /// GET /elders/{elder_id} — added to the backend so this no longer
  /// needs to fetch the whole list and filter client-side.
  Future<Map<String, dynamic>> getElderById(String elderId) async {
    final res = await http.get(_u("/elders/$elderId"), headers: _headers());
    final data = _decode(res);
    return Map<String, dynamic>.from(data["elder"]);
  }

  Future<void> deleteElder(String elderId) async {
    final res = await http.delete(_u("/elders/$elderId"), headers: _headers());
    _decode(res);
  }

  // ---------------- ALERT HISTORY ----------------


  /// Environment/Health events for the Analytics screen's
  /// 'Environment & Health Events' section. If the backend doesn't
  /// have this endpoint yet, the caller (AnalyticsScreen._load())
  /// catches the failure and simply shows an empty events section
  /// rather than erroring the whole screen.
  Future<List<Map<String, dynamic>>> getElderEvents(String elderId) async {
    final uri = _u("/elders/$elderId/events");
    final res = await http.get(uri, headers: _headers());
    final data = _decode(res);
    final list = data is List ? data : (data["results"] ?? data["events"] ?? []);
    return List<Map<String, dynamic>>.from(list.map((e) => Map<String, dynamic>.from(e)));
  }
  Future<List<Map<String, dynamic>>> getAlertHistory(
    String elderId, {
    int limit = 20,
    int offset = 0,
    String? alertType,
  }) async {
    final params = {
      "limit": "$limit",
      "offset": "$offset",
      if (alertType != null) "alert_type": alertType,
    };
    final uri = _u("/elders/$elderId/alerts").replace(queryParameters: params);
    final res = await http.get(uri, headers: _headers());
    final data = _decode(res);
    return List<Map<String, dynamic>>.from(
      (data["results"] as List).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  Future<void> markGuidanceCompleted(String alertId) async {
    final res = await http.post(_u("/alerts/$alertId/guidance-completed"), headers: _headers());
    _decode(res);
  }

  // ---------------- ESCALATION ----------------

  /// POST /elders/{elder_id}/escalate — the dedicated endpoint,
  /// replacing the old work-around that force-called
  /// /integration/component1-to-component4 with a manually set
  /// risk_level=HIGH. This always resolves to alert_type
  /// "Emergency Alert" server-side and is persisted to alert history
  /// with escalated=true.
  Future<Map<String, dynamic>> escalate({
    required String elderId,
    required String reason, // "no_response_timeout" | "elder_requested_help"
    required String fallType,
  }) async {
    final res = await http.post(
      _u("/elders/$elderId/escalate"),
      headers: _headers(),
      body: jsonEncode({"reason": reason, "fall_type": fallType}),
    );
    return _decode(res);
  }

  // ---------------- EMERGENCY CONTACTS ----------------

  Future<Map<String, dynamic>> inviteEmergencyContact(String elderId, String email) async {
    final res = await http.post(
      _u("/elders/$elderId/emergency-contacts"),
      headers: _headers(),
      body: jsonEncode({"email": email}),
    );
    return _decode(res);
  }

  Future<List<Map<String, dynamic>>> listEmergencyContacts(String elderId) async {
    final res = await http.get(_u("/elders/$elderId/emergency-contacts"), headers: _headers());
    final data = _decode(res);
    return List<Map<String, dynamic>>.from(
      (data["results"] as List).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  Future<void> removeEmergencyContact(String elderId, String emergencyPersonId) async {
    final res = await http.delete(
      _u("/elders/$elderId/emergency-contacts/$emergencyPersonId"),
      headers: _headers(),
    );
    _decode(res);
  }

  /// Called by an EMERGENCY_PERSON account to see which elder(s)
  /// they've been linked to by a caregiver.
  Future<List<Map<String, dynamic>>> getMyLinkedElders() async {
    final res = await http.get(_u("/emergency-contacts/my-elders"), headers: _headers());
    final data = _decode(res);
    return List<Map<String, dynamic>>.from(
      (data["elders"] as List).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  // ---------------- REAL-TIME ALERTS (WebSocket) ----------------

  /// Connects to /ws/elder/{elder_id} for push-based alert delivery,
  /// replacing the need to poll for Component 4 results. Component
  /// 1/2/3 /latest data is still polled separately — this channel
  /// only carries alert events (see backend's AlertService.create).
  ///
  /// ws:// vs wss:// is derived from AppConfig.baseUrl automatically.
  WebSocketChannel connectAlertStream(String elderId) {
    final wsBase = AppConfig.baseUrl.replaceFirst("http", "ws");
    return WebSocketChannel.connect(Uri.parse("$wsBase/ws/elder/$elderId"));
  }

  // ---------------- COMPONENT 1: FALL DETECTION ----------------

  Future<Map<String, dynamic>> getFallLatest() async {
    final res = await http.get(_u("/component1/latest"), headers: _headers());
    return _decode(res);
  }

  // ---------------- COMPONENT 2: ENVIRONMENT ----------------

  Future<Map<String, dynamic>> getEnvironmentLatest() async {
    final res = await http.get(_u("/component2/latest"), headers: _headers());
    return _decode(res);
  }

  Future<List<dynamic>> getEnvironmentDevices() async {
    final res = await http.get(_u("/component2/devices"), headers: _headers());
    final data = _decode(res);
    return data["results"] ?? [];
  }

  /// GET /component2/cameras — list of discovered ESP32-CAM devices.
  /// Each entry includes a "snapshot_url" (relative path) — build the
  /// full image URL as "${AppConfig.baseUrl}${snapshot_url}".
  Future<List<Map<String, dynamic>>> getCameras() async {
    final res = await http.get(_u("/component2/cameras"), headers: _headers());
    final data = _decode(res);
    return List<Map<String, dynamic>>.from(
      (data["results"] as List).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  /// POST /component2/devices/{id}/buzzer — publishes a buzzer on/off
  /// command over MQTT. This only confirms the command was published,
  /// not that the physical buzzer changed — the device's own reported
  /// state (via the next /component2/devices poll) is the source of
  /// truth for whether it actually turned on/off.
  Future<void> setBuzzer(String deviceId, bool on) async {
    final res = await http.post(
      _u("/component2/devices/$deviceId/buzzer"),
      headers: _headers(),
      body: jsonEncode({"on": on}),
    );
    _decode(res);
  }

  // ---------------- COMPONENT 3: VITALS (PPG/BP) ----------------

  Future<Map<String, dynamic>> getVitalsLatest() async {
    final res = await http.get(_u("/component3/latest"), headers: _headers());
    return _decode(res);
  }

  // ---------------- COMPONENT 4: ALERTS & GUIDANCE ----------------

  Future<Map<String, dynamic>> predictComponent4(Map<String, dynamic> request) async {
    final res = await http.post(
      _u("/component4/predict"),
      headers: _headers(),
      body: jsonEncode(request),
    );
    return _decode(res);
  }

  // ---------------- INTEGRATION (manual Component1 -> Component4) ----------------

  Future<Map<String, dynamic>> triggerIntegration({
    required Map<String, dynamic> component1,
    required Map<String, dynamic> component2,
    required Map<String, dynamic> user,
    String? elderId,
  }) async {
    final res = await http.post(
      _u("/integration/component1-to-component4"),
      headers: _headers(),
      body: jsonEncode({
        "component1": component1,
        "component2": component2,
        "user": user,
        if (elderId != null) "elder_id": elderId,
      }),
    );
    return _decode(res);
  }

  // ---------------- HEALTH CHECKS ----------------

  Future<Map<String, dynamic>> healthCheck(String component) async {
    // component: "component1" | "component2" | "component3" | "component4" | "integration"
    final res = await http.get(_u("/$component/health"), headers: _headers(auth: false));
    return _decode(res);
  }
}

