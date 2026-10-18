import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../models/elder.dart';
import 'add_edit_elder_screen.dart';
import 'elder_home_screen.dart';
import 'root_shell.dart';
import 'my_elders_screen.dart';
import 'register_screen.dart';

/// Login logic is unchanged from the original except for the explicit
/// role switch added below (see _login()). Visual layer updated to
/// the new theme (already mostly inherited via the AppColors.navy
/// / .cyan aliases). Added: a real show/hide password toggle.
///
/// DELIBERATELY NOT ADDED: a "Forgot Password" link. The spec asks
/// for one, but no password-reset endpoint exists in ApiService or
/// the backend — per the spec's own rule in its Forgot Password
/// section ("Do not simulate password reset"), adding a screen that
/// can't actually reset anything would violate that same rule. This
/// should be added once a real backend endpoint exists.

// ADDED (final hardening prompt, section 3): same simple-but-real
// email check used elsewhere in this app (add_edit_elder_screen.dart) —
// stronger than contains("@") without a third-party package. Rejects
// "abc", "abc@", "@domain.com", "abc@domain" (no TLD), "abc @gmail.com"
// (embedded space); accepts normal addresses like "user@example.com".
final RegExp _loginEmailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

bool _isValidLoginEmail(String v) => _loginEmailPattern.hasMatch(v.trim());

// ADDED (final hardening prompt, section 2): maps login/profile-fetch
// failures to a short, non-technical message. Never surfaces Supabase/
// FastAPI/HTTP/stack-trace detail. Falls back to one generic line when
// nothing specific matches.
String _friendlyLoginError(Object e) {
  final raw = e.toString().toLowerCase();
  if (raw.contains('invalid') &&
      (raw.contains('credential') ||
          raw.contains('password') ||
          raw.contains('login'))) {
    return "Incorrect email or password. Please try again.";
  }
  if (raw.contains('401') ||
      raw.contains('400') ||
      raw.contains('unauthorized') ||
      raw.contains('credential')) {
    return "Incorrect email or password. Please try again.";
  }
  if (raw.contains('socket') ||
      raw.contains('timeout') ||
      raw.contains('network') ||
      raw.contains('connection') ||
      raw.contains('failed host lookup') ||
      raw.contains('500') ||
      raw.contains('502') ||
      raw.contains('503')) {
    return "Unable to sign in right now. Please check your connection and try again.";
  }
  return "Something went wrong while signing in. Please try again.";
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ApiService.instance.login(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
      if (!mounted) return;
      final role = result["user"]?["role"]?.toString();

      // CHANGED (ELDER role integration, prompt section 37): this used
      // to be "EMERGENCY_PERSON -> Emergency Home, anything else ->
      // Caregiver" — an implicit fallback that would have silently
      // treated a brand-new ELDER login as a CAREGIVER (and sent it
      // into listElders()/Add Elder, a caregiver-only flow). Every
      // supported role is now handled explicitly, and an unrecognized
      // role fails safely instead of ever defaulting to Caregiver.
      switch (role) {
        case "EMERGENCY_PERSON":
          Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MyEldersScreen()));
          return;

        case "ELDER":
          // HARDENING (final hardening prompt, section 6): a failure
          // here must never open ElderHomeScreen with fake/partial
          // data — caught separately so it gets its own specific
          // friendly message instead of the generic login-failure one,
          // and login itself already succeeded at this point, so this
          // is reported as a profile problem, not a credentials one.
          try {
            final elderJson = await ApiService.instance.getMyElderProfile();
            if (!mounted) return;
            final elder = Elder.fromJson((elderJson["elder"] as Map?)?.cast<String, dynamic>() ?? elderJson);
            Navigator.of(context).pushReplacement(MaterialPageRoute(
                builder: (_) => ElderHomeScreen(elder: elder)));
          } catch (e) {
            if (!mounted) return;
            setState(() {
              _error =
                  "Your Elder profile could not be found. Please contact your caregiver.";
            });
          }
          return;

        case "CAREGIVER":
          // Unchanged: same single-elder fix as Splash — go directly to
          // the elder's Home if one exists, or Add Elder if not,
          // instead of the multi-elder EldersListScreen.
          final raw = await ApiService.instance.listElders();
          if (!mounted) return;
          if (raw.isEmpty) {
            Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const AddEditElderScreen()));
          } else {
            final elder = Elder.fromJson(Map<String, dynamic>.from(raw.first));
            Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => RootShell(elder: elder)));
          }
          return;

        default:
          // Unknown/unsupported role: fail safely rather than ever
          // opening the Caregiver interface for a role we don't
          // recognize (prompt section 3/26, Test 4).
          setState(() {
            _error =
                "This account type is not supported by this app. Please contact support.";
          });
          return;
      }
    } catch (e) {
      // HARDENING (final hardening prompt, section 2): never show the
      // raw exception (Supabase/FastAPI/network detail) to the user.
      print("LOGIN ERROR: $e");
      setState(() => _error = _friendlyLoginError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 48),
                decoration: const BoxDecoration(
                  color: AppColors.primaryDark,
                  borderRadius:
                      BorderRadius.vertical(bottom: Radius.circular(28)),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                      child: Image.asset('assets/images/aegiscare_logo.png', fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.shield_outlined, color: AppColors.secondaryTeal, size: 30)),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    RichText(
                      text: const TextSpan(
                        children: [
                          TextSpan(
                              text: "Aegis",
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 24)),
                          TextSpan(
                              text: "Care",
                              style: TextStyle(
                                  color: AppColors.secondaryTeal,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 24)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text("Elder Care & Safety",
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text("Welcome Back",
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        "Sign in to keep watching over your loved ones",
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                            labelText: "Email",
                            prefixIcon: Icon(Icons.mail_outline)),
                        // HARDENING (final hardening prompt, section 3):
                        // stronger than contains("@") — same approach as
                        // add_edit_elder_screen.dart's email check.
                        validator: (v) {
                          final text = (v ?? "").trim();
                          if (text.isEmpty || !_isValidLoginEmail(text)) {
                            return "Enter a valid email address.";
                          }
                          return null;
                        },
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: "Password",
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                            tooltip: _obscurePassword
                                ? "Show password"
                                : "Hide password",
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? "Enter your password"
                            : null,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        // HARDENING (final hardening prompt, section 20):
                        // keyboard "Done" can submit, but goes through
                        // the exact same _login() guard against
                        // duplicate requests (section 9/10) as the
                        // button — disabled whenever _loading is true.
                        onFieldSubmitted: (_) {
                          if (!_loading) _login();
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        Text(_error!,
                            style: const TextStyle(color: AppColors.emergency)),
                      ],
                      const SizedBox(height: AppSpacing.xl),
                      ElevatedButton.icon(
                        onPressed: _loading ? null : _login,
                        icon: _loading
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.login),
                        label: Text(_loading ? "Signing in..." : "Sign In"),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const RegisterScreen()),
                        ),
                        child: const Text("Don't have an account? Register"),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

