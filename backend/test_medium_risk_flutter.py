"""
test_medium_risk_flutter.py

Sends a MEDIUM-severity fall scenario straight to the backend (no
MQTT needed) and lets you WATCH THE RESULT LIVE IN THE FLUTTER APP —
this is the same call path a real sensor event uses (it calls
AlertService.create(), which broadcasts over the same WebSocket
channel the Flutter app is already listening to).

============================================================
BEFORE RUNNING — DO THIS FIRST
============================================================
1. Make sure the backend server is running (uvicorn).
2. Open the Flutter Caregiver App (Chrome or a real device).
3. Log in, and navigate to THIS SPECIFIC elder's Home Dashboard
   screen (the one matching ELDER_NAME_HINT below, or just the
   first elder in your account — see get_first_elder()).
   The WebSocket connection only exists while you're ON that
   elder's Home Dashboard screen — if you're on a different
   screen, the alert will still be saved, but you won't SEE it
   pop up live.
4. Only once you're looking at that screen, run this script.

============================================================
IMPORTANT — HONEST NOTE ON "MEDIUM RISK"
============================================================
Per the finalized "Two-Branch System" design (see conversation
notes), a MEDIUM-severity fall does NOT guarantee a specific alert
type. Component 4's own model decides the recipient — it could
come back as Voice, Caregiver, OR Emergency Alert, depending on the
elder's real profile (age, previous falls, assistive device). This
script sends genuinely MEDIUM-severity input; whichever alert type
the Flutter app shows is the model's real, live decision — not a
scripted certainty.

USAGE:
    pip install requests --break-system-packages
    python test_medium_risk_flutter.py
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
    print("👉 Make sure the Flutter app is open on THIS elder's Home Dashboard right now.\n")
    return elder


def send_medium_risk_fall(token: str, elder: dict) -> None:
    body = {
        "component1": {
            "fall_detected": True,
            "fall_type": "fall_side_left",
            "risk_level": "MEDIUM",       # magnitude 4.5-6.0 m/s^2, per the Two-Branch severity bands
            "movement": "Standing",
            "confidence": 72.0,
        },
        "component2": {"location": "Bedroom", "time": "15:00"},
        "user": {
            "age": elder.get("age", 75),
            "previous_falls": elder.get("previous_falls", 1),
            "assistive_device": elder.get("assistive_device", "cane"),
        },
        "elder_id": elder["id"],
    }

    print("Sending MEDIUM-severity fall event...")
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
    print()
    print("=" * 60)
    print("NOW CHECK THE FLUTTER APP — you should see, live:")
    print("=" * 60)
    if alert_type == "Voice Alert":
        print("  -> Nothing on the Caregiver App's alert screen directly —")
        print("     this one routes to the ELDER App instead (guidance steps).")
        print("     The Caregiver's Home Dashboard mirror card should still")
        print("     update to reflect the new alert in history.")
    elif alert_type == "Caregiver Alert":
        print("  -> The Caregiver App should show the full-screen")
        print("     'Caregiver Alert' voice-instruction popup automatically.")
    elif alert_type == "Emergency Alert":
        print("  -> The Caregiver App shows the alert, AND the linked")
        print("     Emergency Contact App should get a real-time push too.")
    print("\nIf nothing appeared, confirm the Flutter app is actually on")
    print("this elder's Home Dashboard screen (not the Elders List or a")
    print("different elder) — the WebSocket only listens while there.")


if __name__ == "__main__":
    token = login()
    elder = get_first_elder(token)
    send_medium_risk_fall(token, elder)
