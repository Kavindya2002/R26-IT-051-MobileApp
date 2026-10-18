"""
test_caregiver_alert_flutter.py

Sends a LOW-severity fall scenario, with an elder profile
combination that reliably produced "Caregiver Alert" in earlier
testing (70.64% confidence), straight to the backend (no MQTT
needed) — lets you WATCH THE RESULT LIVE IN THE FLUTTER APP, the
same way test_medium_risk_flutter.py did for the Emergency Alert
test.

============================================================
BEFORE RUNNING — DO THIS FIRST
============================================================
1. Make sure the backend server is running (uvicorn).
2. Open the Flutter Caregiver App (Chrome or a real device).
3. Log in, and navigate to THIS SPECIFIC elder's Home Dashboard
   screen. The WebSocket connection only exists while you're ON
   that elder's Home Dashboard screen — if you're on a different
   screen, the alert still saves, but you won't see it pop up live.
4. Only once you're looking at that screen, run this script.

============================================================
HONEST NOTE — "CAREGIVER ALERT" IS STILL NOT GUARANTEED
============================================================
Same principle as every other test script in this set: Component
4's model decides the recipient from the elder's REAL profile in
your database (age, previous_falls, assistive_device) — this script
only controls the fall severity/type inputs. The combination below
(LOW severity, no assistive device, no previous falls) reliably
produced Caregiver Alert with your CURRENT elder + model, but if
you've since changed the elder's profile or retrained the model,
the result could differ. Whatever comes back in the printed
response is what actually happened — not a scripted guarantee.

USAGE:
    pip install requests --break-system-packages
    python test_caregiver_alert_flutter.py
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


def send_caregiver_alert_fall(token: str, elder: dict) -> None:
    body = {
        "component1": {
            "fall_detected": True,
            "fall_type": "fall_forward",
            "risk_level": "LOW",         # magnitude 3.0-4.5 m/s^2, per the Two-Branch severity bands
            "movement": "Standing",
            "confidence": 60.0,
        },
        "component2": {"location": "Bedroom", "time": "14:30"},
        "user": {
            # Deliberately overriding the elder's real DB profile
            # here with an "independent" profile — this is the exact
            # combination that reliably produced Caregiver Alert in
            # earlier testing (70.64% confidence). Remove these
            # overrides if you want the model to use the elder's
            # ACTUAL saved profile instead.
            "age": elder.get("age", 75),
            "previous_falls": 0,
            "assistive_device": "none",
        },
        "elder_id": elder["id"],
    }

    print("Sending LOW-severity fall event (targeting Caregiver Alert)...")
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
    elif alert_type == "Caregiver Alert":
        print("  -> The Caregiver App should show the full-screen")
        print("     'Caregiver Alert' voice-instruction popup automatically.")
        print("     (This is the expected result for this test.)")
    elif alert_type == "Emergency Alert":
        print("  -> The Caregiver App shows the alert, AND the linked")
        print("     Emergency Contact App should get a real-time push too.")
        print("     (The Emergency Person Home Screen's beep+voice reminder")
        print("     cycle should also start — see conversation notes.)")
    print("\nIf nothing appeared, confirm the Flutter app is actually on")
    print("this elder's Home Dashboard screen (not the Elders List or a")
    print("different elder) — the WebSocket only listens while there.")


if __name__ == "__main__":
    token = login()
    elder = get_first_elder(token)
    send_caregiver_alert_fall(token, elder)
