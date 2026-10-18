# AegisCare — Flutter App

Elder-care monitoring app: fall detection, environment, vitals, alerts, analytics, and step-by-step recovery guidance, built against the AegisCare FastAPI backend.

## Setup

```bash
flutter pub get
```

**Before running**, open `lib/config.dart` and set `baseUrl` to point at your backend:

```dart
static const String baseUrl = "http://127.0.0.1:8000";
```

| Environment | baseUrl |
|---|---|
| Android emulator | `http://10.0.2.2:8000` |
| iOS simulator / Chrome | `http://127.0.0.1:8000` |
| Physical phone (same wifi) | `http://<your-pc-lan-ip>:8000` |
| Deployed backend | `https://your-app.example.com` |

Then run:

```bash
flutter run
```

**Note on verification**: this project was reviewed and edited by static source analysis (brace/paren balance, import checks, grep-based regression checks) — it was **not** compiled or run on a real Flutter SDK, Android emulator, or device. The sandbox this was built in cannot reach `storage.googleapis.com` (where Flutter's own bootstrap downloads the Dart SDK from), so `flutter pub get` / `flutter run` were never actually executed. Running `flutter analyze` yourself as the first step is genuinely the most useful thing you can do before anything else below.

## Navigation structure (current)

```
Splash / Login -> [role check via GET /users/me]
    |
    +-- CAREGIVER
    |     `-- [GET /elders]
    |           +-- no elder yet -> Add Elder Screen -> Root Shell
    |           `-- elder exists -> Root Shell directly (no list screen shown)
    |                   Bottom nav: Home | Alerts | Analytics | Profile
    |
    `-- EMERGENCY_PERSON
          `-- [GET /emergency-contacts/my-elders]
                `-- My Elders Screen -> Emergency Root Shell
                        Bottom nav: Elder Details (read-only) | Alerts | Account
```

`EldersListScreen` still exists in the codebase and still works, but is **not** the caregiver's landing screen anymore — Splash/Login check the elder list themselves and route straight to that elder's Home or to Add Elder.

A "Caregiver Alert" pushes a full-screen voice-instruction popup automatically (TTS reads the alert aloud). A "LOW risk" fall starts the elder-facing Guidance Screen automatically (see `GuidanceState`).

## Design system

Centralized in `lib/theme/app_theme.dart`:

- Primary `#176B87`, Dark Primary `#0F4C5C`, Secondary Teal `#2A9D8F`
- Background `#F5F8FA`, Card `#FFFFFF`
- Safe `#16A34A`, Warning `#F59E0B`, Emergency `#DC2626`
- Typography: Inter (via `google_fonts`, already a declared dependency)
- A `Breakpoints`/`ResponsiveScaffoldBody`/`ResponsiveGrid` set in `lib/widgets/responsive.dart` — currently applied to Home Dashboard only; not yet extended to other screens.

Old navy/blue token names (`AppColors.navy`, `.cyan`, `.severity()`, etc.) are kept as **aliases** in `app_theme.dart` pointing at the new palette, so screens not yet individually rebuilt still compile and render with the new colors.

## Known backend/data gaps (documented in-code with comments)

1. **No `phone` field on `elders`** — "Call Elder" actions are honestly disabled ("No phone number available") rather than calling a fake number. Wire this up once a real phone field exists on the Elder model.
2. **No `gender` column** on `elders` — not exposed in Add/Edit Elder, to avoid a field that would silently fail to save.
3. **No Environment/Health alert history** — the `alerts` table only persists fall-triggered Component 4 decisions, so Analytics and Alerts filtering is limited to that data.
4. **No plain-language `explanation` field on persisted alerts** — Emergency Alert Detail's "Why this alert" shows "No additional explanation available." when the backend has none, rather than a fabricated sentence.
5. **Caregiver-initiated manual escalation does not exist as a button.** Verified against the real backend (`app/alerts/schemas.py`): `EscalateRequest.reason` is an unconstrained `str` that doesn't even affect server logic, so adding one would be technically safe — but no reason value for "caregiver manually triggered this" is part of the backend's own documented contract. This is a scoped-out feature, not a bug.
6. **Escalation confirmation gap (fixed this round)**: `GuidanceState.escalationConfirmed` now tracks whether `escalate()` actually reached the backend; the caregiver's guidance mirror card shows a connection warning if not. The elder-facing message is deliberately left unchanged either way.
7. **`camera_card.dart` has been removed** — it was confirmed unused after Camera/YOLO UI was removed from Environment screen. The backend's `GET /component2/cameras` endpoint and `ApiService.getCameras()` wrapper are untouched.

## Project structure

```
lib/
├── main.dart
├── config.dart                        # backend base URL
├── theme/app_theme.dart               # design tokens + backward-compat aliases
├── widgets/
│   ├── aegis_app_bar.dart
│   ├── vital_ring.dart
│   ├── status_widgets.dart            # StatusBadge, SafetyStatusCard, Loading/Empty/ErrorState
│   └── responsive.dart                # Breakpoints, ResponsiveScaffoldBody, ResponsiveGrid
├── models/
│   ├── elder.dart
│   ├── alert_state.dart
│   └── guidance_state.dart            # guidance session + TTS + escalation + escalationConfirmed
├── services/api_service.dart
└── screens/
    ├── splash_screen.dart, login_screen.dart, register_screen.dart
    ├── elders_list_screen.dart        # still exists, no longer the landing screen
    ├── add_edit_elder_screen.dart / elder_details_screen.dart
    ├── root_shell.dart                # Caregiver bottom nav: Home | Alerts | Analytics | Profile
    ├── home_dashboard_screen.dart     # responsive pattern applied here
    ├── alerts_screen.dart             # merges old History + Active Alerts
    ├── analytics_screen.dart          # new — computed client-side from real alert history
    ├── fall_detection_screen.dart / environment_screen.dart (camera-free) / vitals_screen.dart
    ├── alert_detail_screen.dart / emergency_alert_detail_screen.dart
    ├── elder_guidance_screen.dart / caregiver_guidance_mirror.dart / caregiver_alert_voice_instruction_screen.dart
    ├── guidance_support_screen.dart
    ├── profile_screen.dart (elder param added) / edit_profile_screen.dart / settings_screen.dart
    ├── my_elders_screen.dart / emergency_root_shell.dart / elder_details_readonly_screen.dart
    ├── emergency_alerts_feed_screen.dart
    └── history_screen.dart            # superseded by alerts_screen.dart; kept, unreferenced
```
