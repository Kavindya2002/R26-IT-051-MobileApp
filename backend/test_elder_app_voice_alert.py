"""
test_elder_app_voice_alert.py

Sends a fall scenario calibrated to the STRONGEST real Voice Alert
pattern found in the training dataset — targeting the Elder App's
guidance flow (see conversation notes: guidance is enabled only
when the model's own decision is "Voice Alert").

============================================================
CRITICAL FIX — CATEGORY VALUE FORMAT (see conversation notes)
============================================================
Every earlier test script in this project (test_component4_direct.py,
test_medium_risk_flutter.py, test_caregiver_alert_flutter.py) sent
FallType/AssistiveDevice/Time values that DON'T match the exact
strings Component 4's OneHotEncoder was trained on:

    Wrong (earlier scripts)      Correct (matches training data)
    -----------------------      --------------------------------
    fall_forward              -> "Forward Fall"
    fall_backward              -> "Backward Fall"
    fall_side_left              -> "Side Fall Left"
    none / cane / walker /
      wheelchair                -> "No Device" / "Cane" / "Walker" / "Crutches"
    "14:30" (clock time)        -> "Morning" / "Afternoon" / "Evening" / "Night"

OneHotEncoder(handle_unknown="ignore") does NOT raise an error on a
mismatched value — it silently encodes it as all-zeros, meaning the
model received NO information for that feature on every earlier
test call. This script uses the CORRECT category strings throughout,
so this is the first test in this project where the model is
actually seeing all 9 real input features.

This also means: PRODUCTION alerts have the same issue for
Time (Component 2 sends an ISO timestamp, not a category) and
AssistiveDevice (real elder profiles are typically saved lowercase,
e.g. "walker", not "Walker") — both silently zeroed out on every
real alert too. That's a separate fix (a normalization/mapping step
before calling Component 4) — flagged here, not applied by this
script, which only controls what IT sends directly.

============================================================
BEFORE RUNNING
============================================================
1. Backend server running (uvicorn).
2. Elder App open (see setup from earlier in this project), paired
   to this elder, showing "Monitoring Active — Connected".
3. Only once you see that screen, run this script.

============================================================
HONEST NOTE — STILL NOT A GUARANTEE
============================================================
Voice Alert was still only 1.55% of all confirmed-fall training
rows even within its best-supported pattern (264 of 17,062 rows).
This scenario uses the single most common combination among those
264 rows (LOW severity, Slump fall, Sitting, No Device, 0 previous
falls, ~68 years old) — the closest thing to a "best shot" this
dataset supports, not a certainty.

USAGE:
    pip install requests --break-system-packages
    python test_elder_app_voice_alert.py
"""

import requests

BASE_URL = "http://127.0.0.1:8000"
EMAIL = "sanath@gmail.com"
PASSWORD = "sanath1234"


def login() -> str:
    res = requests.post(f"{BASE_URL}/users/login", json={"email": EMAIL, "password": PASSWORD})
    res.raise_for_status()
    data = res.json()
    token = data.get("access_token") or data.get("session", {}).get("access_token")
    if not token:
        raise RuntimeError(f"Could not find access_token in login response: {data}")
    print("✅ Logged in.\n")
    return token


def get_first_elder(token: str) -> dict:
    res = requests.get(f"{BASE_URL}/elders", headers={"Authorization": f"Bearer {token}"})
    res.raise_for_status()
    elders = res.json().get("elders", [])
    if not elders:
        raise RuntimeError("No elders found for this account — add one first.")
    elder = elders[0]
    print(f"Using elder: {elder['name']} (id={elder['id']})")
    print("👉 Make sure the Elder App is paired to THIS elder and shows 'Connected' right now.\n")
    return elder


def send_voice_alert_fall(token: str, elder: dict) -> None:
    body = {
        "component1": {
            "fall_detected": True,
            "fall_type": "Slump",          # CORRECT format — most common Voice Alert fall type (69/264)
            "risk_level": "LOW",           # magnitude 3.0-4.5 m/s^2 — most common (182/264)
            "movement": "Sitting",         # CORRECT format — most common (74/264)
            "confidence": 55.0,
        },
        "component2": {
            "location": "Bedroom",         # already correct format in earlier scripts too
            "time": "Afternoon",           # CORRECT format — was "14:30" before (wrong)
        },
        "user": {
            "age": 68,                     # median age among Voice Alert rows
            "previous_falls": 0,           # most common (141/264)
            "assistive_device": "No Device",  # CORRECT format — was "none" before (wrong)
        },
        "elder_id": elder["id"],
    }

    print("Sending LOW-severity Slump fall (targeting Voice Alert, correct category formats)...")
    res = requests.post(
        f"{BASE_URL}/integration/component1-to-component4",
        json=body,
        headers={"Authorization": f"Bearer {token}"},
    )

    if res.status_code != 200:
        print(f"❌ HTTP {res.status_code}: {res.text}")
        return

    result = res.json()
    c4 = result.get("component4", {})
    alert_type = c4.get("alert")
    guidance = c4.get("guidance", {})

    print("\n" + "=" * 60)
    print("BACKEND RESPONSE (what the model actually decided)")
    print("=" * 60)
    print(f"  alert          : {alert_type}")
    print(f"  confidence     : {c4.get('confidence')}%")
    print(f"  probabilities  : {c4.get('probabilities')}")
    print(f"  guidance.enabled: {guidance.get('enabled')}")
    if guidance.get("enabled"):
        print(f"  guidance.steps  : {guidance.get('steps')}")
    print()
    print("=" * 60)
    print("NOW CHECK THE ELDER APP — you should see, live:")
    print("=" * 60)
    if alert_type == "Voice Alert":
        print("  -> The Elder App should auto-switch to the Elder Guidance")
        print("     Screen and start speaking the steps aloud (TTS).")
        print("     (This is the expected result for this test.)")
    else:
        print(f"  -> Model routed this to '{alert_type}' instead of Voice Alert —")
        print("     the Elder App will NOT show guidance for this one.")
        print("     Check the Caregiver App / Emergency Person Home Screen instead.")
    print("\nIf nothing appeared in the Elder App, confirm it's actually")
    print("paired to this elder_id and shows 'Connected' — the WebSocket")
    print("only delivers guidance while that connection is live.")


if __name__ == "__main__":
    token = login()
    elder = get_first_elder(token)
    send_voice_alert_fall(token, elder)
