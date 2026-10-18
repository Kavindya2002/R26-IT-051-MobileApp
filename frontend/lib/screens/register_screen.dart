import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';

/// Registration API call unchanged. Visual layer updated: removed
/// explicit OutlineInputBorder() on each field, which was overriding
/// the app's InputDecorationTheme and making this screen look
/// inconsistent with the rest of the new design. Added: a real
/// client-side Confirm Password check (no backend change — the
/// password itself was always validated server-side; this just
/// catches a typo before submitting) and show/hide toggles.
///
/// HARDENING PASS (final register-screen review): stronger email/
/// phone/name validation, a friendly error-mapping helper (no raw
/// e.toString() shown to the user), a small non-dominant error card
/// instead of bare red text, subtle section grouping labels, and
/// keyboard/autofill polish (textInputAction chaining, autofill
/// hints). No backend/API contract change — same ApiService.register()
/// call with the same named parameters, and ELDER is still not, and
/// must never be, selectable from this public registration screen.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _relationshipCtrl = TextEditingController();
  final _confirmPasswordFocus = FocusNode();
  final _phoneFocus = FocusNode();
  // ROLE SAFETY: public registration only ever supports these two
  // string values. ELDER accounts are never created from this screen —
  // they only ever come from the caregiver-provisioned elder-account
  // flow (Add/Edit Elder's "Give this elder app access"). There is no
  // dropdown entry, no hidden value, and no code path here that can
  // submit "ELDER".
  String _role = "CAREGIVER";
  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _confirmPasswordFocus.dispose();
    _phoneFocus.dispose();
    super.dispose();
  }

  // ADDED (hardening, section 3): a real, but intentionally simple,
  // email check — rejects empty/whitespace-only input, a missing local
  // part or domain, and malformed structure, without pulling in a
  // third-party package.
  bool _isValidEmail(String v) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim());

  // ADDED (hardening, section 6): basic Sri Lankan mobile format check
  // — accepts "0712345678" and "+94712345678", rejects alphabetic
  // input, obviously malformed numbers, and anything too short.
  bool _isValidLkPhone(String v) =>
      RegExp(r'^(0\d{9}|\+94\d{9})$').hasMatch(v.trim().replaceAll(' ', ''));

  // ADDED (hardening, section 8): maps whatever the backend/network
  // layer throws into a short, calm, non-technical message. Never
  // surfaces stack traces, tokens, Supabase internals, or raw HTTP
  // detail — falls back to one generic line when nothing matches.
  String _friendlyRegisterError(Object e) {
    final raw = e.toString().toLowerCase();
    if (raw.contains('already') &&
        (raw.contains('registered') ||
            raw.contains('email') ||
            raw.contains('exists'))) {
      return "This email is already registered. Please sign in instead.";
    }
    if (raw.contains('409') || raw.contains('conflict')) {
      return "This email is already registered. Please sign in instead.";
    }
    if (raw.contains('400') ||
        raw.contains('invalid') ||
        raw.contains('validation')) {
      return "Invalid email or password format. Please check your details and try again.";
    }
    if (raw.contains('socket') ||
        raw.contains('timeout') ||
        raw.contains('network') ||
        raw.contains('connection') ||
        raw.contains('failed host lookup')) {
      return "Network connection failed. Please check your connection and try again.";
    }
    if (raw.contains('500') ||
        raw.contains('502') ||
        raw.contains('503') ||
        raw.contains('server')) {
      return "Unable to connect to the server. Please try again.";
    }
    return "Registration failed. Please try again.";
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ApiService.instance.register(
        name: _nameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        phone: _phoneCtrl.text.trim(),
        role: _role,
        address:
            _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim(),
        relationship: _relationshipCtrl.text.trim().isEmpty
            ? null
            : _relationshipCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Account created successfully. Please sign in.")),
      );
      // Unchanged: return to Login, never into a caregiver/emergency
      // dashboard directly, and no fake session state is created here
      // — the user still has to actually sign in.
      Navigator.of(context).pop();
    } catch (e) {
      // HARDENING (section 8): never show the raw exception.
      setState(() => _error = _friendlyRegisterError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
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
    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Create account"),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sectionLabel("Account Information"),
                TextFormField(
                  controller: _nameCtrl,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                      labelText: "Full name",
                      prefixIcon: Icon(Icons.person_outline)),
                  // HARDENING (section 5): rejects empty/whitespace-only
                  // and extremely short values; normal names with
                  // spaces are still accepted. Trimmed only when sent
                  // to the backend (see _register()), not here.
                  validator: (v) {
                    final text = (v ?? "").trim();
                    if (text.length < 2) return "Enter your name";
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                      labelText: "Email", prefixIcon: Icon(Icons.mail_outline)),
                  // HARDENING (section 3): stronger than contains("@").
                  validator: (v) {
                    final text = (v ?? "").trim();
                    if (text.isEmpty || !_isValidEmail(text))
                      return "Enter a valid email address";
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  onFieldSubmitted: (_) => FocusScope.of(context)
                      .requestFocus(_confirmPasswordFocus),
                  decoration: InputDecoration(
                    labelText: "Password (min 8 chars)",
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      tooltip:
                          _obscurePassword ? "Show password" : "Hide password",
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  // Preserved exactly: 8-char minimum, password itself
                  // never trimmed or altered before submission.
                  validator: (v) => (v == null || v.length < 8)
                      ? "Password must be 8+ characters"
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _confirmPasswordCtrl,
                  focusNode: _confirmPasswordFocus,
                  obscureText: _obscureConfirm,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  onFieldSubmitted: (_) =>
                      FocusScope.of(context).requestFocus(_phoneFocus),
                  decoration: InputDecoration(
                    labelText: "Confirm password",
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      tooltip:
                          _obscureConfirm ? "Show password" : "Hide password",
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: (v) => (v != _passwordCtrl.text)
                      ? "Passwords do not match"
                      : null,
                ),
                _sectionLabel("Contact Information"),
                TextFormField(
                  controller: _phoneCtrl,
                  focusNode: _phoneFocus,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                      labelText: "Phone",
                      prefixIcon: Icon(Icons.phone_outlined)),
                  // HARDENING (section 6): real Sri Lankan format check
                  // instead of a bare length check.
                  validator: (v) {
                    final text = (v ?? "").trim();
                    if (text.isEmpty || !_isValidLkPhone(text))
                      return "Enter a valid phone number";
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _addressCtrl,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                      labelText: "Address (optional)",
                      prefixIcon: Icon(Icons.home_outlined)),
                ),
                _sectionLabel("AegisCare Access"),
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                      labelText: "Role",
                      prefixIcon: Icon(Icons.badge_outlined)),
                  // ROLE SAFETY (section 2): exactly these two options,
                  // human-readable labels, no ELDER entry anywhere in
                  // this list.
                  items: const [
                    DropdownMenuItem(
                        value: "CAREGIVER", child: Text("Caregiver")),
                    DropdownMenuItem(
                        value: "EMERGENCY_PERSON",
                        child: Text("Emergency contact")),
                  ],
                  onChanged: (v) => setState(() => _role = v ?? "CAREGIVER"),
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _relationshipCtrl,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) {
                    if (!_loading) _register();
                  },
                  decoration: const InputDecoration(
                    labelText: "Relationship to elder (optional)",
                    prefixIcon: Icon(Icons.diversity_1_outlined),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  // HARDENING (section 11): a small, non-dominant error
                  // card — icon + readable text — instead of bare red
                  // text, so a validation/registration failure doesn't
                  // visually overwhelm the form.
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.emergency),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            color: AppColors.emergency, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_error!,
                              style:
                                  const TextStyle(color: AppColors.emergency)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _register,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text("Create Account"),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Already have an account? Sign In"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
