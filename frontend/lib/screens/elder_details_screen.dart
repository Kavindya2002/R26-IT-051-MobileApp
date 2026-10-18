import 'package:flutter/material.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';
import 'add_edit_elder_screen.dart';
import 'root_shell.dart';

/// HARDENING PASS (final Elder Details / Elder Profile review):
///   - Elder data (address, assistive device) now uses explicit
///     "unavailable" fallback text instead of "Not provided" /
///     whatever raw string the backend sent, never null/blank.
///   - Home address gets its own dedicated, unconstrained section
///     instead of being squeezed into a label/value row — so a long
///     address wraps freely rather than being ellipsized away.
///   - Emergency contacts now has a real error state (previously a
///     failed load silently looked identical to "no contacts").
///   - Add Emergency Contact dialog validates the email client-side,
///     disables itself and shows a spinner while submitting, and maps
///     failures to friendly text instead of "Couldn't add contact: $e".
///   - Removing a contact and deleting the elder now both confirm
///     first (removal previously fired on a single tap), show a
///     per-item loading state, and never show a raw exception.
///   - Contact name/email fall back to explicit "unavailable" text
///     instead of "Unknown" / a blank subtitle.
/// No architecture change: same ApiService methods
/// (listEmergencyContacts/inviteEmergencyContact/removeEmergencyContact/
/// deleteElder), same Elder model, same RootShell/AddEditElderScreen
/// navigation, no new backend endpoint.
class ElderDetailsScreen extends StatefulWidget {
  final Elder elder;
  const ElderDetailsScreen({super.key, required this.elder});

  @override
  State<ElderDetailsScreen> createState() => _ElderDetailsScreenState();
}

class _ElderDetailsScreenState extends State<ElderDetailsScreen> {
  List<Map<String, dynamic>> _contacts = [];
  bool _loadingContacts = true;
  String? _contactsError;

  // Per-item/action loading guards — kept separate so one slow
  // operation never blocks or hides the state of another (prompt
  // section 17).
  final Set<String> _removingContactIds = <String>{};
  bool _deletingElder = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  bool _hasValue(dynamic v) => v != null && v.toString().trim().isNotEmpty;

  bool _isValidEmail(String v) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim());

  // Shared friendly-error mapper for every action on this screen.
  // Never surfaces stack traces, tokens, or raw backend/Supabase text
  // — falls back to the caller's own calm, action-specific message
  // when nothing more specific matches.
  String _friendlyError(Object e, String fallback) {
    final raw = e.toString().toLowerCase();
    if (raw.contains('socket') ||
        raw.contains('timeout') ||
        raw.contains('network') ||
        raw.contains('connection') ||
        raw.contains('failed host lookup')) {
      return "Network connection failed. Please check your connection and try again.";
    }
    if (raw.contains('401') ||
        raw.contains('unauthorized') ||
        raw.contains('permission')) {
      return "You do not have permission to perform this action.";
    }
    if (raw.contains('404') || raw.contains('not found')) {
      return "This emergency contact could not be found. It may have already been removed.";
    }
    if ((raw.contains('409') ||
            raw.contains('conflict') ||
            raw.contains('already')) &&
        (raw.contains('contact') ||
            raw.contains('linked') ||
            raw.contains('email'))) {
      return "This email is already linked as an emergency contact.";
    }
    if (raw.contains('not linked') ||
        raw.contains('no account') ||
        raw.contains('does not exist')) {
      return "This email is not linked to an Emergency account.";
    }
    if (raw.contains('400') ||
        raw.contains('invalid') ||
        raw.contains('validation')) {
      return "Some information is invalid. Please check and try again.";
    }
    if (raw.contains('500') ||
        raw.contains('502') ||
        raw.contains('503') ||
        raw.contains('server')) {
      return "Unable to connect to the server. Please try again.";
    }
    return fallback;
  }

  Future<void> _loadContacts() async {
    setState(() {
      _loadingContacts = true;
      _contactsError = null;
    });
    try {
      final contacts =
          await ApiService.instance.listEmergencyContacts(widget.elder.id);
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _loadingContacts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
        _contactsError = _friendlyError(
            e, "Couldn't load emergency contacts. Please try again.");
      });
    }
  }

  // ADDED (prompt sections 9/10/11): the dialog now validates the
  // email itself, shows its own loading state while the API call is
  // in flight (disabling the field and the Add button so a second tap
  // can't fire a duplicate request), and only closes on success —
  // on failure it stays open with a friendly inline message so the
  // caregiver can correct the email and retry without reopening it.
  Future<void> _inviteContact() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        bool submitting = false;
        String? dialogError;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final email = controller.text.trim();
              if (email.isEmpty || !_isValidEmail(email)) {
                setDialogState(
                    () => dialogError = "Enter a valid email address.");
                return;
              }
              setDialogState(() {
                submitting = true;
                dialogError = null;
              });
              try {
                final result = await ApiService.instance
                    .inviteEmergencyContact(widget.elder.id, email);
                if (!mounted) return;
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                      content: Text(_hasValue(result["message"])
                          ? result["message"].toString()
                          : "Emergency contact added.")),
                );
                _loadContacts();
              } catch (e) {
                setDialogState(() {
                  submitting = false;
                  dialogError = _friendlyError(e,
                      "Couldn't add this emergency contact. Please try again.");
                });
              }
            }

            return AlertDialog(
              title: const Text("Add emergency contact"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    enabled: !submitting,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: "Their email",
                      helperText:
                          "They must already have an Emergency/Response account.",
                      helperMaxLines: 2,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(dialogError!,
                        style: const TextStyle(
                            color: AppColors.emergency, fontSize: 13)),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.pop(dialogContext),
                  child: const Text("Cancel"),
                ),
                FilledButton(
                  onPressed: submitting ? null : submit,
                  child: submitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Add"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ADDED (prompt section 12): a single tap no longer removes a
  // contact — confirm first, then show a per-row loading state while
  // the request is in flight so a second tap on the same row can't
  // fire a duplicate request.
  Future<void> _confirmAndRemoveContact(String emergencyPersonId) async {
    if (_removingContactIds.contains(emergencyPersonId)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Remove emergency contact?"),
        content: const Text(
            "Are you sure you want to remove this emergency contact?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Remove",
                style: TextStyle(color: AppColors.emergency)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _removingContactIds.add(emergencyPersonId));
    try {
      await ApiService.instance
          .removeEmergencyContact(widget.elder.id, emergencyPersonId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Emergency contact removed.")),
      );
      await _loadContacts();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_friendlyError(e,
                "Couldn't remove the emergency contact. Please try again."))),
      );
    } finally {
      if (mounted)
        setState(() => _removingContactIds.remove(emergencyPersonId));
    }
  }

  Color _fallsColor(int falls) {
    if (falls >= 3) return AppColors.high;
    if (falls >= 1) return AppColors.medium;
    return AppColors.textMuted;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (_deletingElder) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Remove this elder?"),
        content: const Text(
            "This removes the elder profile. This action cannot be undone."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Remove",
                style: TextStyle(color: AppColors.emergency)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _deletingElder = true);
    try {
      await ApiService.instance.deleteElder(widget.elder.id);
      // On success, leave this screen — on failure (below) we stay put
      // and show a friendly error instead of silently failing.
      if (context.mounted) Navigator.of(context).pop();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(_friendlyError(
                  e, "Couldn't remove elder. Please try again."))),
        );
      }
    } finally {
      if (mounted) setState(() => _deletingElder = false);
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
    final rawName = widget.elder.name.trim();
    final displayName =
        rawName.isEmpty ? "Elder information unavailable" : rawName;
    final initial = rawName.isNotEmpty ? rawName[0].toUpperCase() : "?";
    // "none" is a real, meaningful backend value (the elder genuinely
    // uses no assistive device) — distinct from a missing/empty value,
    // which is the only case that gets the "unavailable" fallback.
    final rawDevice = widget.elder.assistiveDevice;
    final assistiveDevice = !_hasValue(rawDevice)
        ? "Assistive device unavailable"
        : (rawDevice.toLowerCase() == "none" ? "None" : rawDevice);
    final address = _hasValue(widget.elder.address)
        ? widget.elder.address!.trim()
        : "Home address unavailable";

    return Scaffold(
      backgroundColor: AppColors.background,
      // CHANGED (edit-button restyle): the small pencil/trash icons in
      // the app bar are gone — both actions now live as full-width
      // buttons in the body instead, styled exactly like
      // ProfileScreen's "Edit profile" (filled) / "Log out" (red
      // outlined) buttons, so this screen matches that same pattern.
      appBar: AegisAppBar(
        showLogo: false,
        title: "Elder profile",
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Column(
                  children: [
                    // CHANGED (avatar picker feature): shows the
                    // elder's chosen preset avatar when one is set,
                    // falling back to the exact original behavior —
                    // an initial-letter circle — when it isn't.
                    AvatarCircle(
                      avatarId: widget.elder.avatarId,
                      fallbackInitial: initial,
                      radius: 44,
                      fallbackColor: AppColors.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      displayName,
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

              _sectionLabel("Personal Information"),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      _row(context, "Age", "${widget.elder.age}"),
                      const Divider(height: 1),
                      _row(
                        context,
                        "Previous falls",
                        "${widget.elder.previousFalls}",
                        valueColor: _fallsColor(widget.elder.previousFalls),
                      ),
                    ],
                  ),
                ),
              ),

              _sectionLabel("Care Information"),
              Card(
                margin: EdgeInsets.zero,
                child: _row(context, "Assistive device", assistiveDevice),
              ),

              // HOME LOCATION — given its own card, label above value,
              // so a genuinely long address can wrap across as many
              // lines as it needs instead of being ellipsized in a
              // label/value row (prompt section 6).
              _sectionLabel("Home Location"),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.home_outlined,
                          size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(address,
                            style: Theme.of(context).textTheme.bodyLarge),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.xl),
              // ADDED (edit-button restyle): same filled-button style
              // as ProfileScreen's "Edit profile" — primary action,
              // full width, 48px tall.
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) =>
                              AddEditElderScreen(existing: widget.elder)),
                    );
                    // NOTE: this screen's Elder is passed in via the
                    // constructor (immutable for this screen's
                    // lifetime). There is no getElder(id) refetch
                    // available to this screen, so — per the prompt's
                    // own instruction not to invent a backend endpoint
                    // or fabricate updated data — we intentionally do
                    // not try to refresh it here. The caller that
                    // opened this screen (e.g. the elders list) is
                    // responsible for re-fetching if it needs the
                    // latest data after an edit.
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text("Edit elder"),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Same outlined-button style as ProfileScreen's "Elder
              // profile" button.
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => RootShell(elder: widget.elder)),
                  ),
                  icon: const Icon(Icons.dashboard_outlined),
                  label: const Text("Open dashboard"),
                ),
              ),

              _sectionLabel("Emergency Contacts"),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Trusted emergency responders",
                      style: Theme.of(context).textTheme.bodyMedium),
                  TextButton.icon(
                    onPressed: _inviteContact,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: const Text("Add"),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_loadingContacts)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_contactsError != null)
                // ERROR state — previously a failed load looked
                // identical to "no contacts yet" (prompt section 8).
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.error_outline,
                              size: 18, color: AppColors.textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(_contactsError!,
                                  style:
                                      Theme.of(context).textTheme.bodyMedium)),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      TextButton(
                          onPressed: _loadContacts,
                          child: const Text("Try again")),
                    ],
                  ),
                )
              else if (_contacts.isEmpty)
                // EMPTY state — calm, not alarming (prompt section 18).
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("No emergency contacts linked yet.",
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 2),
                      Text(
                        "Add a trusted Emergency/Response account so they can receive Emergency Alerts.",
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                )
              else
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: _contacts.asMap().entries.map((entry) {
                      final i = entry.key;
                      final c = entry.value;
                      final user = Map<String, dynamic>.from(c["users"] ?? {});
                      final contactId =
                          c["emergency_person_id"]?.toString() ?? "";
                      final removing = _removingContactIds.contains(contactId);
                      final name = _hasValue(user["name"])
                          ? user["name"].toString()
                          : "Name unavailable";
                      final email = _hasValue(user["email"])
                          ? user["email"].toString()
                          : "Email unavailable";
                      return Column(
                        children: [
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: AppColors.primaryLight,
                              child: Icon(Icons.support_agent,
                                  color: AppColors.primary, size: 20),
                            ),
                            title: Text(name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(email,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: removing
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : IconButton(
                                    icon: const Icon(Icons.close,
                                        size: 20, color: AppColors.textMuted),
                                    tooltip: "Remove emergency contact",
                                    onPressed: contactId.isEmpty
                                        ? null
                                        : () =>
                                            _confirmAndRemoveContact(contactId),
                                  ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              // ADDED (edit-button restyle): same red-outlined style
              // as ProfileScreen's "Log out" button — a clearly
              // separate, destructive action placed last.
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed:
                      _deletingElder ? null : () => _confirmDelete(context),
                  icon: _deletingElder
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.emergency),
                        )
                      : const Icon(Icons.delete_outline,
                          color: AppColors.emergency),
                  label: Text(
                    _deletingElder ? "Removing…" : "Remove elder",
                    style: const TextStyle(color: AppColors.emergency),
                  ),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.emergency)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {Color? valueColor}) {
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
            child: Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: valueColor),
              textAlign: TextAlign.left,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
