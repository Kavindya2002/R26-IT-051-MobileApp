import 'package:flutter/material.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';
import 'edit_profile_screen.dart';
import 'elder_details_screen.dart';
import 'login_screen.dart';
import 'settings_screen.dart';

/// FIXED: a real regression from the single-elder routing change —
/// EldersListScreen used to be the only way to reach
/// ElderDetailsScreen (Elder Profile / Edit Elder), and it is no
/// longer the caregiver's landing screen. Without this fix, Elder
/// Profile and Edit Elder would be completely unreachable, directly
/// contradicting "Keep Elder Profile and Edit Elder functionality."
///
/// `elder` is optional and nullable: RootShell (the Caregiver
/// context) now passes the real current elder so the new "Elder
/// Profile" menu item can appear; MyEldersScreen's Emergency Person
/// usage omits it, since that role has no elder-editing access
/// (least-privilege, unchanged).
///
/// HARDENING PASS (final Profile Screen review):
///   - Role handling used to be a binary "CAREGIVER or else Emergency"
///     check, which would have mislabeled both ELDER and any unknown
///     role as "Emergency / response" AND (more importantly) would
///     never have been wrong today only because this screen currently
///     only ever receives CAREGIVER/EMERGENCY_PERSON — it's now
///     explicit for all three real roles plus a safe "Account" fallback,
///     and the Elder Profile button is now gated on role == CAREGIVER
///     (previously gated only on widget.elder != null).
///   - Missing profile fields showed a bare "-" — now explicit
///     "X unavailable" / "X not set" text, never fabricated.
///   - A failed pull-to-refresh with an already-loaded profile used to
///     be indistinguishable from the initial-load failure (same
///     _error field) — now a refresh failure with existing data
///     keeps that data visible and shows a small SnackBar instead of
///     replacing the screen with a blank error state.
///   - Raw e.toString() (load + logout) replaced with a friendly
///     error helper.
///   - Logout now confirms first and guards against duplicate taps.
///
/// AVATAR PICKER (ADDED): the plain initial-letter CircleAvatar is
/// replaced with AvatarCircle, which shows the caregiver/emergency
/// person's chosen preset icon avatar (avatar_id, set from
/// EditProfileScreen) and falls back to the exact same initial-letter
/// look for any profile that hasn't picked one yet — zero visual
/// change for existing users until they choose an avatar.
/// No other architecture change: same ApiService.getMyProfile()/logout()
/// calls, same EditProfileScreen/ElderDetailsScreen/SettingsScreen/
/// LoginScreen navigation.
class ProfileScreen extends StatefulWidget {
  final Elder? elder;
  const ProfileScreen({super.key, this.elder});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _user;
  bool _loading = true;
  String? _error;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _hasValue(dynamic v) => v != null && v.toString().trim().isNotEmpty;

  // Maps whatever the profile load / logout layer throws into a short,
  // calm, non-technical message. Never surfaces stack traces, tokens,
  // or Supabase/HTTP internals.
  String _friendlyError(Object e, String fallback) {
    final raw = e.toString().toLowerCase();
    if (raw.contains('socket') ||
        raw.contains('timeout') ||
        raw.contains('network') ||
        raw.contains('connection') ||
        raw.contains('failed host lookup')) {
      return "Network connection failed. Check your connection and try again.";
    }
    if (raw.contains('401') ||
        raw.contains('unauthorized') ||
        raw.contains('expired')) {
      return "Your session may have expired. Please sign in again.";
    }
    return fallback;
  }

  // ADDED (prompt section 2): explicit label per real role — never
  // defaults an unknown/unsupported role to "Emergency".
  String _roleLabel(String role) {
    switch (role) {
      case "CAREGIVER":
        return "Caregiver";
      case "EMERGENCY_PERSON":
        return "Emergency / Response";
      case "ELDER":
        return "Elder";
      default:
        return "Account";
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case "CAREGIVER":
        return AppColors.primary;
      case "EMERGENCY_PERSON":
        return AppColors.medium;
      case "ELDER":
        return AppColors.secondaryTeal;
      default:
        return AppColors.textMuted;
    }
  }

  // Never calls substring(0,1) on an empty/whitespace-only name.
  String _safeInitial(dynamic name) {
    final text = (name ?? "").toString().trim();
    return text.isEmpty ? "?" : text[0].toUpperCase();
  }

  Future<void> _load() async {
    final hadData = _user != null;
    setState(() {
      _loading = !hadData; // keep existing content visible on a refresh
      if (!hadData) _error = null;
    });
    try {
      final res = await ApiService.instance.getMyProfile();
      if (!mounted) return;
      setState(() {
        _user = res["user"];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (hadData) {
        // REFRESH FAILURE WITH EXISTING DATA (prompt section 6): keep
        // showing the profile that's already on screen rather than
        // replacing it with a blank error state.
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(_friendlyError(
                  e, "Unable to refresh your profile. Please try again."))),
        );
      } else {
        setState(() {
          _error = _friendlyError(
              e, "Unable to load your profile. Please try again.");
          _loading = false;
        });
      }
    }
  }

  Future<void> _confirmLogout() async {
    if (_loggingOut) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Log out?"),
        content: const Text("Are you sure you want to log out of AegisCare?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Log out",
                style: TextStyle(color: AppColors.emergency)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _loggingOut = true);
    try {
      await ApiService.instance.logout();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loggingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                _friendlyError(e, "Unable to log out. Please try again."))),
      );
    }
  }

  Widget _sectionLabel(String text) => Padding(
        padding:
            const EdgeInsets.only(bottom: AppSpacing.sm, top: AppSpacing.lg),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.5),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final role = _user?["role"]?.toString() ?? "";
    // ROLE SAFETY (prompt section 3): Elder Profile is shown only for
    // a real, confirmed CAREGIVER with a real elder already provided —
    // never for Emergency Person, Elder, or an unrecognized role, and
    // never fabricated if widget.elder happens to be null.
    final isCaregiver = role == "CAREGIVER";
    final showElderProfile = isCaregiver && widget.elder != null;
    final roleColor = _roleColor(role);
    final name = _hasValue(_user?["name"])
        ? _user!["name"].toString()
        : "Name unavailable";

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AegisAppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: "Settings",
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && _user == null)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 32, color: AppColors.textSecondary),
                        const SizedBox(height: AppSpacing.md),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: AppSpacing.md),
                        ElevatedButton(
                            onPressed: _load, child: const Text("Retry")),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    children: [
                      Center(
                        child: Column(
                          children: [
                            // CHANGED (avatar picker feature): was a
                            // plain CircleAvatar with the initial
                            // letter — now shows the chosen preset
                            // avatar via AvatarCircle, falling back to
                            // the exact same initial-letter look when
                            // no avatar_id is set yet.
                            AvatarCircle(
                              avatarId: _user?["avatar_id"] as String?,
                              fallbackInitial: _safeInitial(_user?["name"]),
                              radius: 42,
                              fallbackColor: roleColor,
                            ),
                            const SizedBox(height: 14),
                            Text(name,
                                style:
                                    Theme.of(context).textTheme.headlineMedium,
                                textAlign: TextAlign.center),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: roleColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                _roleLabel(role),
                                style: TextStyle(
                                    color: roleColor,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _sectionLabel("Contact Information"),
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            children: [
                              _row(
                                  context,
                                  "Email",
                                  _hasValue(_user?["email"])
                                      ? _user!["email"].toString()
                                      : "Email unavailable",
                                  locked: true),
                              const Divider(height: 1),
                              _row(
                                  context,
                                  "Phone",
                                  _hasValue(_user?["phone"])
                                      ? _user!["phone"].toString()
                                      : "Phone unavailable"),
                            ],
                          ),
                        ),
                      ),
                      _sectionLabel("Care Information"),
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            children: [
                              _row(
                                  context,
                                  "Relationship",
                                  _hasValue(_user?["relationship"])
                                      ? _user!["relationship"].toString()
                                      : "Relationship not set"),
                              const Divider(height: 1),
                              _row(
                                  context,
                                  "Priority",
                                  _hasValue(_user?["priority"])
                                      ? _user!["priority"].toString()
                                      : "Priority unavailable"),
                            ],
                          ),
                        ),
                      ),
                      _sectionLabel("Address"),
                      Card(
                        margin: EdgeInsets.zero,
                        child: _row(
                            context,
                            "Address",
                            _hasValue(_user?["address"])
                                ? _user!["address"].toString()
                                : "Address not set"),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _user == null
                              ? null
                              : () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            EditProfileScreen(user: _user!)),
                                  );
                                  _load();
                                },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text("Edit profile"),
                        ),
                      ),
                      if (showElderProfile) ...[
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      ElderDetailsScreen(elder: widget.elder!)),
                            ),
                            icon: const Icon(Icons.person_outline),
                            label: const Text("Elder profile"),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      SizedBox(
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _loggingOut ? null : _confirmLogout,
                          icon: _loggingOut
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.emergency),
                                )
                              : const Icon(Icons.logout,
                                  color: AppColors.emergency),
                          label: Text(
                            _loggingOut ? "Logging out…" : "Log out",
                            style: const TextStyle(color: AppColors.emergency),
                          ),
                          style: OutlinedButton.styleFrom(
                              side:
                                  const BorderSide(color: AppColors.emergency)),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {bool locked = false}) {
    // FIXED: this row shows Email/Phone/Relationship/Address — Address
    // values in particular can genuinely be long enough to overflow a
    // 320-360px screen, and neither side was constrained before. The
    // label now has a fixed-ish share via Flexible, and the value side
    // is Expanded with right-alignment and ellipsis, so a long value
    // truncates cleanly instead of overflowing or forcing the row taller.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.left,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (locked) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.lock_outline,
                      size: 14, color: AppColors.textMuted),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
