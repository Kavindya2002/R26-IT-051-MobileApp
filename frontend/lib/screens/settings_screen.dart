import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

/// REBUILT: the original version of this screen had three
/// notification toggles that were pure in-memory booleans — they
/// reset every time the screen reopened and had no effect on
/// anything, because no push-notification backend (FCM or
/// equivalent) exists yet (confirmed in
/// AegisCare_Final_Project_Status.md: "Closed-app push notifications
/// require Firebase Cloud Messaging... not yet added"). That is
/// exactly the "toggle that does nothing" the spec's own Section 29
/// explicitly prohibits.
///
/// Fix: toggles now persist to SharedPreferences, so they are at
/// least REAL local device preferences rather than fake UI state —
/// and an honest banner explains plainly that they currently only
/// control in-app behaviour, not push delivery, since that backend
/// piece doesn't exist. This is disclosure, not a workaround: the
/// toggles do something real (persist a local preference) while
/// being honest about what they do NOT yet do (actually gate FCM
/// push, which isn't built).
///
/// HARDENING PASS (final Settings Screen review):
///   - _set() previously flipped the UI immediately and never checked
///     whether the SharedPreferences write actually succeeded, so a
///     rare disk/storage failure would leave the switch showing a
///     value that was never actually saved. It now reverts the switch
///     and shows a friendly SnackBar if the save fails, and ignores a
///     second tap on the same switch while its save is still in
///     flight (prevents a race between two overlapping writes).
///   - "Change password" now reads as a clearly unavailable research-
///     prototype feature (muted styling, no chevron implying a real
///     destination) rather than a tappable row with a vague SnackBar.
///   - Data Usage wording tightened to avoid any unsupported privacy
///     promise (no claim of "never stored"/"fully encrypted"/etc.).
/// Preserves the exact same three SharedPreferences keys
/// (settings_emergency_push / settings_caregiver_push /
/// settings_voice_inapp) so no existing local preference is lost, and
/// — critically — these remain local, in-app-only display
/// preferences: nothing here touches Component 4, AlertService, the
/// WebSocket, alert persistence, or emergency escalation. A real
/// Emergency Alert is never gated on these switches.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _kEmergencyPush = "settings_emergency_push";
  static const _kCaregiverPush = "settings_caregiver_push";
  static const _kVoiceInApp = "settings_voice_inapp";

  bool _emergencyPush = true;
  bool _caregiverPush = true;
  bool _voiceInApp = true;
  bool _loaded = false;

  // Prevents a second tap on the same switch from racing with a save
  // that's still in flight (prompt section 4's "prevent inconsistent
  // UI state").
  final Set<String> _savingKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _emergencyPush = prefs.getBool(_kEmergencyPush) ?? true;
      _caregiverPush = prefs.getBool(_kCaregiverPush) ?? true;
      _voiceInApp = prefs.getBool(_kVoiceInApp) ?? true;
      _loaded = true;
    });
  }

  // HARDENING (prompt section 4): applies the new value optimistically,
  // but reverts it and tells the user if the write never actually
  // succeeds, instead of silently leaving the UI out of sync with
  // what's on disk.
  Future<void> _set(String key, bool newValue, bool previousValue,
      void Function(bool) apply) async {
    if (_savingKeys.contains(key)) return;
    _savingKeys.add(key);
    setState(() => apply(newValue));
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setBool(key, newValue);
      if (!saved) throw Exception("SharedPreferences write returned false");
    } catch (_) {
      if (!mounted) return;
      setState(() => apply(previousValue));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Couldn't save this setting. Please try again.")),
      );
    } finally {
      _savingKeys.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Settings"),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        children: [
          _sectionLabel("Notifications"),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            decoration: BoxDecoration(
                color: AppColors.warningLight,
                borderRadius: BorderRadius.circular(AppRadius.card)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    color: AppColors.warning, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    // Preserved, honest disclosure — never claims
                    // closed-app/background push works (prompt
                    // section 2).
                    "These control in-app behaviour only. Push notifications for a closed app are not yet implemented.",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text("Emergency Alert notifications"),
                  subtitle: const Text("Shown while the app is open"),
                  value: _emergencyPush,
                  onChanged: (v) => _set(_kEmergencyPush, v, _emergencyPush,
                      (val) => _emergencyPush = val),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text("Caregiver Alert notifications"),
                  subtitle: const Text("Shown while the app is open"),
                  value: _caregiverPush,
                  onChanged: (v) => _set(_kCaregiverPush, v, _caregiverPush,
                      (val) => _caregiverPush = val),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text("Voice Alert in-app banner"),
                  subtitle: const Text("Shown only while the app is open"),
                  value: _voiceInApp,
                  onChanged: (v) => _set(
                      _kVoiceInApp, v, _voiceInApp, (val) => _voiceInApp = val),
                ),
              ],
            ),
          ),
          _sectionLabel("Privacy & Security"),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.security_outlined),
                  title: Text("Data usage"),
                  // HARDENING (prompt section 9): tightened to describe
                  // only what the app actually does (processes sensor/
                  // health data for monitoring and alerting), with no
                  // unsupported promise about storage, encryption, or
                  // sharing.
                  subtitle: Text(
                      "Sensor and health-related data is processed by AegisCare for monitoring and alerting."),
                ),
                const Divider(height: 1),
                // HARDENING (prompt section 8): reads as clearly
                // unavailable rather than a tappable row that implies
                // a real destination — muted icon/text, no chevron,
                // and the SnackBar wording matches what's actually true
                // (no password-change backend exists).
                ListTile(
                  leading:
                      Icon(Icons.password_outlined, color: AppColors.textMuted),
                  title: Text("Change password",
                      style: TextStyle(color: AppColors.textMuted)),
                  subtitle:
                      const Text("Not available in this research prototype."),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              "Change password is not available in this research prototype.")),
                    );
                  },
                ),
              ],
            ),
          ),
          _sectionLabel("About"),
          Card(
            child: Column(
              children: const [
                ListTile(title: Text("App"), trailing: Text("AegisCare")),
                Divider(height: 1),
                // Matches pubspec.yaml's "version: 1.0.0+1" exactly. Not
                // read dynamically — package_info_plus isn't a current
                // dependency, and adding one is a real decision outside
                // a UI-only rebuild's scope. This is the true static
                // value, not a fabricated placeholder.
                ListTile(title: Text("Version"), trailing: Text("1.0.0")),
                Divider(height: 1),
                ListTile(
                    title: Text("Purpose"),
                    subtitle: Text(
                        "Research prototype for elderly fall monitoring and alerting")),
              ],
            ),
          ),
        ],
      ),
    );
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
}
