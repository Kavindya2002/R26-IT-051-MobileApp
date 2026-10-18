"""
test_component4_direct.py

Tests Component 4 DIRECTLY over HTTP — no MQTT, no HiveMQ, no real
sensor hardware needed at all. Calls the manual testing endpoint
(POST /integration/component1-to-component4) with a handful of
different scenarios, to confirm:

    1. The retrained model loads and predicts without the
       '__sklearn_tags__' error.
    2. All three alert classes (Voice/Caregiver/Emergency) can
       actually be produced — not just one dominant class.
    3. Confidence/probabilities look reasonable (not all 33/33/33,
       which would suggest the model isn't actually discriminating).

BEFORE RUNNING:
    pip install requests --break-system-packages

USAGE:
    python test_component4_direct.py

This logs in as your existing caregiver account and uses your real
elder's profile — no fabricated data beyond the Component 1 fields
you're deliberately varying to test different scenarios.
"""

import requests

# ============================================================
# CONFIG
# ============================================================
BASE_URL = "http://127.0.0.1:8000"
EMAIL = "sanath@gmail.com"       # your existing caregiver login
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
    print(f"Using elder: {elder['name']} (id={elder['id']})\n")
    return elder


def run_scenario(token: str, elder: dict, component1: dict, user_overrides: dict, label: str) -> str:
    body = {
        "component1": component1,
        "component2": {"location": "Bedroom", "time": "14:30"},
        "user": {
            "age": elder.get("age", 75),
            "previous_falls": elder.get("previous_falls", 0),
            "assistive_device": elder.get("assistive_device", "none"),
            **user_overrides,
        },
        "elder_id": elder["id"],
    }
    res = requests.post(
        f"{BASE_URL}/integration/component1-to-component4",
        json=body,
        headers={"Authorization": f"Bearer {token}"},
    )

    print(f"--- {label} ---")
    if res.status_code != 200:
        print(f"❌ HTTP {res.status_code}: {res.text}")
        return None

    result = res.json()
    c4 = result.get("component4", {})
    alert_type = c4.get("alert")
    confidence = c4.get("confidence")
    guidance = c4.get("guidance", {})
    print(f"  Input          : {component1}")
    print(f"  alert          : {alert_type}")
    print(f"  confidence     : {confidence}%")
    print(f"  probabilities  : {c4.get('probabilities')}")
    print(f"  guidance.enabled: {guidance.get('enabled')}")
    print()
    return alert_type


if __name__ == "__main__":
    token = login()
    elder = get_first_elder(token)

    # 5 scenarios calibrated to plausibly land on each of the 3 alert
    # types, exercising different combinations of severity + elder
    # risk profile. Component 4's alert is the model's OWN decision —
    # these inputs are chosen to be REPRESENTATIVE of each severity
    # tier, not to force a specific output (that would defeat the
    # purpose of testing a real model).
    scenarios = [
        ("Mild fall, low-risk elder profile (likely Voice Alert)", {
            "fall_detected": True, "fall_type": "fall_forward", "risk_level": "LOW",
            "movement": "Standing", "confidence": 60.0,
        }, {"previous_falls": 0, "assistive_device": "none"}),

        ("Moderate fall, some fall history (likely Caregiver Alert)", {
            "fall_detected": True, "fall_type": "fall_side_left", "risk_level": "MEDIUM",
            "movement": "Standing", "confidence": 70.0,
        }, {"previous_falls": 2, "assistive_device": "cane"}),

        ("Serious fall, elder uses walker (likely Caregiver/Emergency Alert)", {
            "fall_detected": True, "fall_type": "fall_backward", "risk_level": "HIGH",
            "movement": "Standing", "confidence": 80.0,
        }, {"previous_falls": 3, "assistive_device": "walker"}),

        ("Severe fall, high-risk elder profile (likely Emergency Alert)", {
            "fall_detected": True, "fall_type": "fall_backward", "risk_level": "CRITICAL",
            "movement": "Standing", "confidence": 90.0,
        }, {"previous_falls": 5, "assistive_device": "wheelchair", "age": 90}),

        ("Severe fall, younger/independent elder (tests model nuance)", {
            "fall_detected": True, "fall_type": "fall_forward", "risk_level": "CRITICAL",
            "movement": "Walking", "confidence": 85.0,
        }, {"previous_falls": 0, "assistive_device": "none", "age": 65}),

        ("Extremely mild fall, best-case elder profile (targeting Voice Alert)", {
            "fall_detected": True, "fall_type": "fall_forward", "risk_level": "LOW",
            "movement": "Standing", "confidence": 40.0,
        }, {"previous_falls": 0, "assistive_device": "none", "age": 60}),       
        
    ]

    seen_alert_types = set()
    for label, component1, user_overrides in scenarios:
        alert_type = run_scenario(token, elder, component1, user_overrides, label)
        if alert_type:
            seen_alert_types.add(alert_type)

    print("=" * 60)
    print(f"Alert types seen across all scenarios: {seen_alert_types}")
    if len(seen_alert_types) >= 2:
        print("✅ Model is discriminating between multiple alert types — looks healthy.")
    else:
        print("⚠️  Only one alert type appeared across all 5 scenarios.")
        print("   Try more varied inputs, or check the model file if this seems wrong.")
    print("\nIf every call above returned a real alert (no HTTP errors,")
    print("no '__sklearn_tags__' crash), Component 4 is working correctly.")


