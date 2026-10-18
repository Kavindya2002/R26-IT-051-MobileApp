
import 'package:flutter/material.dart';
import '../constants/avatar_presets.dart';
import '../models/elder.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/avatar_picker_sheet.dart';
import 'root_shell.dart';

/// Save logic unchanged. Visual layer reorganized into the spec's
/// section groupings (Personal Information / Care Information /
/// Registered Home Address).
///
/// DELIBERATELY NOT ADDED: a Gender field and Latitude/Longitude
/// fields. The spec asks for both "if supported" / "ONLY if the
/// backend supports them" — the real Elder model
/// (lib/models/elder.dart) has neither field. Adding them here would
/// either silently drop whatever the user types (since toJson()
/// wouldn't send them) or require a real backend/model change, which
/// is out of scope for a UI-only rebuild. A Location/Coordinates
/// section is also omitted for the same reason — see the earlier
/// Nominatim-geocoding discussion for how this would be added
/// properly once that backend work happens.
///
/// Emergency Contact linking already exists as a separate flow
/// (invite via email, reachable from Elder Details) rather than
/// being folded into this form — left as-is rather than restructured,
/// since that would change real navigation behaviour, not just styling.
// ADDED (final hardening prompt, section 3): a real, but intentionally
// simple, email check — stronger than contains("@") without pulling in
// a third-party package. Rejects "abc", "abc@", "@domain.com",
// "abc@domain" (no TLD) and "abc @gmail.com" (embedded space), accepts
// normal addresses like "elder@example.com".
final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

// ADDED (final hardening prompt, section 4): basic Sri Lankan mobile
// format check. Accepts "0712345678" (0 + 9 digits) and "+94712345678"
// (+94 + 9 digits); rejects anything that isn't plausibly a phone
// number. Phone stays optional — this is only run when non-empty.
final RegExp _lkPhonePattern = RegExp(r'^(0\d{9}|\+94\d{9})$');

bool _isValidEmail(String v) => _emailPattern.hasMatch(v.trim());

bool _isValidLkPhone(String v) =>
    _lkPhonePattern.hasMatch(v.trim().replaceAll(' ', ''));

// ADDED (final hardening prompt, section 2): maps whatever the backend/
// Supabase/network layer throws into a short, non-technical message.
// Never surfaces stack traces, raw HTTP bodies, SQL or Python exception
// text — if nothing specific matches, falls back to one generic line.
String _friendlyErrorMessage(Object e) {
  final raw = e.toString().toLowerCase();
  if (raw.contains('already') &&
      (raw.contains('email') ||
          raw.contains('registered') ||
          raw.contains('exists'))) {
    return "This email is already in use. Please use another email.";
  }
  if (raw.contains('409') || raw.contains('conflict')) {
    return "This email is already in use. Please use another email.";
  }
  if (raw.contains('401') ||
      raw.contains('403') ||
      raw.contains('permission') ||
      raw.contains('unauthorized') ||
      raw.contains('forbidden')) {
    return "You do not have permission to perform this action.";
  }
  if (raw.contains('400') ||
      raw.contains('invalid') ||
      raw.contains('validation')) {
    return "Some information is invalid. Please check the form and try again.";
  }
  if (raw.contains('socket') ||
      raw.contains('timeout') ||
      raw.contains('network') ||
      raw.contains('connection') ||
      raw.contains('failed host lookup') ||
      raw.contains('500') ||
      raw.contains('502') ||
      raw.contains('503')) {
    return "Unable to save elder details. Please check your connection and try again.";
  }
  return "Something went wrong while saving. Please try again.";
}

class AddEditElderScreen extends StatefulWidget {
  final Elder? existing;
  const AddEditElderScreen({super.key, this.existing});

  @override
  State<AddEditElderScreen> createState() => _AddEditElderScreenState();
}

class _AddEditElderScreenState extends State<AddEditElderScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _ageCtrl;
  late final TextEditingController _fallsCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _phoneCtrl;
  // ADDED (ELDER role integration): "Give this elder app access"
  // section. _loginEmailCtrl is only read when _grantLogin is true.
  // Both are meaningless (and hidden — see build() below) once this
  // elder already has app access linked (widget.existing!.hasAppAccess),
  // since granting it twice would try to create a second account.
  late final TextEditingController _loginEmailCtrl;
  bool _grantLogin = false;
  String _device = "none";
  String? _gender;
  bool _saving = false;
  String? _error;
  // ADDED (avatar picker feature): the id of the preset avatar chosen
  // for this elder (e.g. "elder_1"). Null until the caregiver picks
  // one, which AvatarCircle treats as "show the initial-letter
  // fallback" — see lib/constants/avatar_presets.dart.
  String? _avatarId;

  bool get _isEditing => widget.existing != null;
  bool get _alreadyHasAppAccess => widget.existing?.hasAppAccess ?? false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? "");
    _ageCtrl = TextEditingController(text: e?.age.toString() ?? "");
    _fallsCtrl =
        TextEditingController(text: e?.previousFalls.toString() ?? "0");
    _addressCtrl = TextEditingController(text: e?.address ?? "");
    _phoneCtrl = TextEditingController(text: e?.phone ?? "");
    _loginEmailCtrl = TextEditingController();
    _device = e?.assistiveDevice ?? "none";
    _gender = e?.gender;
    _avatarId = e?.avatarId;
  }

  // ADDED (avatar picker feature): opens the same bottom-sheet picker
  // used elsewhere in the app, scoped to the Elder preset set so the
  // icons/colors shown here are distinct from the Caregiver ones.
  Future<void> _pickAvatar() async {
    final picked = await showAvatarPicker(
      context,
      presets: AvatarPresets.elder,
      currentId: _avatarId,
      title: "Choose an avatar",
    );
    if (picked != null) setState(() => _avatarId = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // ADDED (ELDER role integration): only meaningful when this elder
    // doesn't already have app access — the toggle itself is hidden in
    // that case (see build()), but this guards the save logic too.
    final grantingLogin = _grantLogin && !_alreadyHasAppAccess;
    final loginEmail = _loginEmailCtrl.text.trim();

    if (grantingLogin && (loginEmail.isEmpty || !_isValidEmail(loginEmail))) {
      setState(() {
        _saving = false;
        _error = loginEmail.isEmpty
            ? "Enter an email for the elder's app login, or turn off app access."
            : "Enter a valid email address.";
      });
      return;
    }

    try {
      Map<String, dynamic>? loginResult;
      if (_isEditing) {
        final result =
            await ApiService.instance.updateElder(widget.existing!.id, {
          "name": _nameCtrl.text.trim(),
          "age": int.parse(_ageCtrl.text.trim()),
          "previous_falls": int.parse(_fallsCtrl.text.trim()),
          "assistive_device": _device,
          "address": _addressCtrl.text.trim().isEmpty
              ? null
              : _addressCtrl.text.trim(),
          "phone":
              _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
          "gender": _gender,
          "avatar_id": _avatarId,
          if (grantingLogin) "grant_login": true,
          if (grantingLogin) "login_email": loginEmail,
        });
        if (!mounted) return;
        if (result["temporary_password"] != null) loginResult = result;
        if (loginResult != null)
          await _showTemporaryPasswordDialog(loginResult);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        final result = await ApiService.instance.createElder(
          name: _nameCtrl.text.trim(),
          age: int.parse(_ageCtrl.text.trim()),
          previousFalls: int.parse(_fallsCtrl.text.trim()),
          assistiveDevice: _device,
          address: _addressCtrl.text.trim().isEmpty
              ? null
              : _addressCtrl.text.trim(),
          phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
          gender: _gender,
          avatarId: _avatarId,
          grantLogin: grantingLogin,
          loginEmail: grantingLogin ? loginEmail : null,
        );
        if (!mounted) return;
        if (result["temporary_password"] != null) {
          await _showTemporaryPasswordDialog(result);
          if (!mounted) return;
        }

        // Go straight to the new elder's Home Dashboard instead of
        // back to the Elders List — that's what people actually want
        // right after adding someone, and it sidesteps ever having to
        // wonder whether the list "refreshed".
        final newElder =
            Elder.fromJson(Map<String, dynamic>.from(result["elder"]));
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => RootShell(elder: newElder)),
        );
      }
    } catch (e) {
      // HARDENING (final hardening prompt, section 2): never show the
      // raw exception (which can contain Supabase/FastAPI technical
      // detail) to the caregiver — map it to a short friendly message.
      setState(() => _error = _friendlyErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ADDED (ELDER role integration, prompt section 8): shown exactly
  // once, only to the caregiver who just granted access, and never
  // persisted anywhere on this device — it only ever lives in this
  // dialog's widget tree for as long as the caregiver is looking at
  // it. The caregiver is expected to pass it on to the elder directly
  // (in person, a message, etc.) outside the app.
  Future<void> _showTemporaryPasswordDialog(Map<String, dynamic> result) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Elder app access created"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Email: ${result["login_email"]}"),
            const SizedBox(height: AppSpacing.sm),
            Text("Temporary password: ${result["temporary_password"]}",
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.md),
            const Text(
              "This is shown once and is not saved anywhere in the app. "
              "Share it with the elder directly so they can log in.",
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("Done"),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding:
            const EdgeInsets.only(bottom: AppSpacing.sm, top: AppSpacing.lg),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 0.5)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AegisAppBar(
          showLogo: false, title: _isEditing ? "Edit elder" : "Add elder"),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sectionLabel("Personal Information"),
                Center(
                  child: GestureDetector(
                    onTap: _pickAvatar,
                    child: Stack(
                      children: [
                        AvatarCircle(
                          avatarId: _avatarId,
                          fallbackInitial: _nameCtrl.text.trim().isNotEmpty
                              ? _nameCtrl.text.trim()[0].toUpperCase()
                              : "E",
                          radius: 42,
                          fallbackColor: AppColors.primary,
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.edit,
                                size: 14, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _pickAvatar,
                    child: const Text("Change avatar"),
                  ),
                ),
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                      labelText: "Full name",
                      prefixIcon: Icon(Icons.person_outline)),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? "Enter a valid name."
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _ageCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: "Age", prefixIcon: Icon(Icons.cake_outlined)),
                  validator: (v) {
                    // HARDENING (final hardening prompt, section 5):
                    // 0-130 was too broad for an elder-care app; 60-120
                    // is a sensible range for this project's scope.
                    // Frontend validation only — no backend change, no
                    // fake default age introduced.
                    final n = int.tryParse(v ?? "");
                    if (n == null || n < 60 || n > 120)
                      return "Enter an age between 60 and 120.";
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: _gender,
                  decoration: const InputDecoration(
                      labelText: "Gender (optional)",
                      prefixIcon: Icon(Icons.person_2_outlined)),
                  items: const [
                    DropdownMenuItem(value: "male", child: Text("Male")),
                    DropdownMenuItem(value: "female", child: Text("Female")),
                    DropdownMenuItem(value: "other", child: Text("Other")),
                  ],
                  onChanged: (v) => setState(() => _gender = v),
                ),

                _sectionLabel("Care Information"),
                TextFormField(
                  controller: _fallsCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: "Previous falls",
                      prefixIcon: Icon(Icons.history)),
                  validator: (v) {
                    final n = int.tryParse(v ?? "");
                    if (n == null || n < 0) return "Enter a valid number.";
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: _device,
                  decoration: const InputDecoration(
                      labelText: "Assistive device",
                      prefixIcon: Icon(Icons.accessible_outlined)),
                  items: const [
                    DropdownMenuItem(value: "none", child: Text("None")),
                    DropdownMenuItem(value: "cane", child: Text("Cane")),
                    DropdownMenuItem(value: "walker", child: Text("Walker")),
                    DropdownMenuItem(
                        value: "wheelchair", child: Text("Wheelchair")),
                  ],
                  onChanged: (v) => setState(() => _device = v ?? "none"),
                ),

                _sectionLabel("Contact"),
                TextFormField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: "Phone number (optional)",
                    prefixIcon: Icon(Icons.phone_outlined),
                    helperText: "Enables the real Call Elder action on alerts",
                  ),
                  // HARDENING (final hardening prompt, section 4): phone
                  // stays fully optional — empty always passes. When
                  // something is entered, it must look like a real Sri
                  // Lankan mobile number (0XXXXXXXXX or +94XXXXXXXXX).
                  validator: (v) {
                    final text = (v ?? "").trim();
                    if (text.isEmpty) return null;
                    if (!_isValidLkPhone(text))
                      return "Enter a valid phone number.";
                    return null;
                  },
                ),

                _sectionLabel("Registered Home Address"),
                TextFormField(
                  controller: _addressCtrl,
                  decoration: const InputDecoration(
                      labelText: "Address (optional)",
                      prefixIcon: Icon(Icons.home_outlined)),
                ),

                // ADDED (ELDER role integration, prompt section 11):
                // a quiet, optional section — never visually dominant,
                // no technical Supabase/Auth wording exposed to the
                // caregiver. Shown as a simple status line instead of
                // a toggle once this elder already has access linked,
                // since granting it again isn't a valid action.
                _sectionLabel("App Access"),
                if (_alreadyHasAppAccess)
                  Row(
                    children: const [
                      Icon(Icons.check_circle, size: 18, color: AppColors.safe),
                      SizedBox(width: AppSpacing.sm),
                      Expanded(
                          child: Text("This elder already has app access.")),
                    ],
                  )
                else ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Give this elder app access"),
                    subtitle: const Text(
                        "Lets the elder log in and use guidance on their own phone."),
                    value: _grantLogin,
                    onChanged: (v) => setState(() => _grantLogin = v),
                  ),
                  if (_grantLogin) ...[
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: _loginEmailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: "Elder email",
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (v) {
                        // HARDENING (final hardening prompt, section 3):
                        // only required/validated while app access is
                        // being granted — stronger than contains("@"),
                        // without a third-party package.
                        if (!_grantLogin) return null;
                        final text = (v ?? "").trim();
                        if (text.isEmpty || !_isValidEmail(text)) {
                          return "Enter a valid email address.";
                        }
                        return null;
                      },
                    ),
                  ],
                ],

                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(_error!,
                      style: const TextStyle(color: AppColors.emergency)),
                ],
                const SizedBox(height: AppSpacing.xxl),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(_isEditing ? "Save changes" : "Save & Continue"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
