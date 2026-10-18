import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';
import '../models/elder.dart';
import 'login_screen.dart';
import 'add_edit_elder_screen.dart';
import 'root_shell.dart';
import 'my_elders_screen.dart';
import 'elder_home_screen.dart';

/// HARDENING PASS (final SplashScreen review):
///
/// The previous version had a real role-routing gap: it only ever
/// checked for "EMERGENCY_PERSON" and otherwise fell straight through
/// to the caregiver listElders() flow — meaning an ELDER login (and
/// any unknown/unsupported role) was silently routed through
/// listElders() as if it were a CAREGIVER, which would have sent an
/// elder straight into caregiver UI (or crashed on Elder.fromJson()
/// against a caregiver-less response). This is now an explicit
/// role switch covering all three real roles plus a safe default
/// for anything else — no role is ever treated as CAREGIVER by
/// falling through.
///
/// Also fixed: a transient API failure while loading the caregiver's
/// elder list, or the elder's own linked profile, used to be
/// indistinguishable from "session expired" — both landed in the same
/// catch-all and silently bounced to Login with no explanation. Those
/// are now handled separately with their own friendly messages, and
/// an API failure is never misread as "no Elder exists" (which would
/// have incorrectly opened Add Elder for a real elder whose data
/// just failed to load this one time).
///
/// Visual layer, delay, and branding are unchanged — this is routing
/// logic hardening only.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    if (!ApiService.instance.isLoggedIn) {
      _goToLogin();
      return;
    }

    // A stored token doesn't tell us the role, so fetch the profile
    // once here to decide which home screen this session belongs to.
    Map<String, dynamic> profile;
    try {
      profile = await ApiService.instance.getMyProfile();
    } catch (_) {
      // Token expired/invalid — the session itself isn't usable, so
      // there's nothing to lose by also clearing it locally before
      // returning to Login.
      if (!mounted) return;
      await _showAccountIssueAndGoToLogin(
        "Your session has expired. Please sign in again.",
        clearSession: true,
      );
      return;
    }
    if (!mounted) return;

    final role = profile["user"]?["role"]?.toString();

    // Explicit per-role routing (prompt section 2/5): every real role
    // is handled by name, and anything else — null, empty, or an
    // unrecognized string — falls to the safe default below rather
    // than ever being treated as CAREGIVER.
    switch (role) {
      case "CAREGIVER":
        await _routeCaregiver();
        return;
      case "ELDER":
        await _routeElder();
        return;
      case "EMERGENCY_PERSON":
        _goTo(const MyEldersScreen());
        return;
      default:
        await _showAccountIssueAndGoToLogin(
          "Your account role could not be verified. Please sign in again.",
          clearSession: true,
        );
        return;
    }
  }

  // CHANGED: this used to go straight to EldersListScreen, a
  // multi-elder management list, for every caregiver login. The final
  // system is a single-elder research prototype, so this does the
  // real check here instead: fetch the actual elder list from the
  // backend and go directly to that elder's Home (RootShell) if one
  // exists, or to Add Elder if none does. EldersListScreen itself
  // still exists and still works — it is just no longer the thing a
  // caregiver lands on after login.
  Future<void> _routeCaregiver() async {
    List<dynamic> raw;
    try {
      raw = await ApiService.instance.listElders();
    } catch (_) {
      // API/network failure is NOT the same thing as "no Elder exists"
      // (prompt section 7/16) — never silently open Add Elder for a
      // real caregiver whose elder data just failed to load.
      if (!mounted) return;
      await _showAccountIssueAndGoToLogin(
        "Unable to load your account data. Please try again.",
      );
      return;
    }
    if (!mounted) return;

    if (raw.isEmpty) {
      _goTo(const AddEditElderScreen());
    } else {
      final elder = Elder.fromJson(Map<String, dynamic>.from(raw.first));
      _goTo(RootShell(elder: elder));
    }
  }

  Future<void> _routeElder() async {
    Map<String, dynamic> elderJson;
    try {
      elderJson = await ApiService.instance.getMyElderProfile();
    } catch (_) {
      // Missing linked Elder profile and a transient API failure are
      // both handled the same safe way here: never fabricate Elder
      // data, never fall back into caregiver UI (prompt section 6).
      if (!mounted) return;
      await _showAccountIssueAndGoToLogin(
        "Your Elder profile could not be loaded. Please contact your caregiver.",
      );
      return;
    }
    if (!mounted) return;
    final elder = Elder.fromJson((elderJson["elder"] as Map?)?.cast<String, dynamic>() ?? elderJson);
    _goTo(ElderHomeScreen(elder: elder));
  }

  void _goTo(Widget screen) {
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  void _goToLogin() {
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  // Shows a brief, friendly, non-technical explanation (never a raw
  // exception) before returning to Login. `clearSession` is only true
  // for a genuinely invalid/unverified session (expired token, role
  // that couldn't be verified) — a transient data-loading failure
  // does not force a logout, since the session itself may still be
  // perfectly valid.
  Future<void> _showAccountIssueAndGoToLogin(String message,
      {bool clearSession = false}) async {
    if (clearSession) {
      try {
        await ApiService.instance.logout();
      } catch (_) {
        // Best-effort only — we're returning to Login regardless.
      }
      if (!mounted) return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Account issue"),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text("OK")),
        ],
      ),
    );
    if (!mounted) return;
    _goToLogin();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: Image.asset('assets/images/aegiscare_logo.png', fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.shield_outlined, color: AppColors.secondaryTeal, size: 44)),
            ),
            const SizedBox(height: AppSpacing.xl),
            RichText(
              text: const TextSpan(
                children: [
                  TextSpan(
                      text: "Aegis",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 26)),
                  TextSpan(
                      text: "Care",
                      style: TextStyle(
                          color: AppColors.secondaryTeal,
                          fontWeight: FontWeight.w700,
                          fontSize: 26)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              "Intelligent Fall Prevention & Elderly Care",
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: AppSpacing.xxxl),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: AppColors.secondaryTeal),
            ),
          ],
        ),
      ),
    );
  }
}
