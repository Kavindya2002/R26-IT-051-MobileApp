"""
test_low_risk_guidance.py

Simulates a LOW-risk fall (the guidance-eligible scenario) to test
the Elder App's real-time TTS guidance auto-play end to end.

============================================================
IMPORTANT — READ THIS FIRST
============================================================
fall_detected=True and risk_level="LOW" can NEVER happen together
from real Component 1 sensor data — see fall_detection.py:

    fall_detected = risk_level == "CRITICAL" and prediction is not None

fall_detected is ONLY ever True when risk_level == "CRITICAL". No
combination of accelerometer values can produce fall_detected=True
with risk_level="LOW" through the real rule engine — the two are
mutually exclusive by design.

This is exactly why COMPONENT1_DEMO_OVERRIDE exists (see
app/integration/component1_adapter.py and .env.example). Before
running this script:

1. Open your backend's .env file.
2. Set:
       COMPONENT1_DEMO_OVERRIDE=guidance
3. Restart the backend (uvicorn app.main:app --reload).

With that override active, ANY sensor reading you publish gets
forcibly reported as fall_detected=True, risk_level="LOW" —
regardless of the actual accelerometer values below. This script's
sample values are therefore arbitrary; they exist only so the
message has a valid, parseable payload.

Remember to set COMPONENT1_DEMO_OVERRIDE=none afterwards so real
sensor data isn't silently overridden going forward.

BEFORE RUNNING:
    pip install paho-mqtt --break-system-packages

RUN:
    python test_low_risk_guidance.py

WHAT TO WATCH FOR in the backend terminal:
    [Component 1] fall_detected=True fall_type=... risk_level=LOW ...
    [Component 4] alert=Voice Alert confidence=... guidance_enabled=True

THEN CHECK:
    - Flutter Caregiver app: Home Dashboard should show the guidance
      mirror card, and "View elder's guidance screen" should work.
    - Elder App: should auto-switch to the Elder Guidance Screen and
      start speaking the steps aloud (TTS) — no interaction needed.
"""

import json
import ssl
import time

import paho.mqtt.client as mqtt

# ============================================================
# CONFIG — fill these in from your own .env file
# ============================================================

COMPONENT1 = {
    "broker": "48d92cd1b9814701b2c4559d693e4ce3.s1.eu.hivemq.cloud",
    "port": 8883,
    "username": "elderKavindu",
    "password": "elderKavindu123",
    "topic": "elder/device01/imu",
}


def make_client(username: str, password: str) -> mqtt.Client:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.username_pw_set(username, password)
    client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
    return client


def publish_once(cfg: dict, topic: str, payload: dict, label: str) -> None:
    client = make_client(cfg["username"], cfg["password"])
    client.connect(cfg["broker"], cfg["port"], keepalive=30)
    client.loop_start()
    time.sleep(2.0)  # give the TLS handshake/session time to fully establish
    result = client.publish(topic, json.dumps(payload), qos=1)
    result.wait_for_publish(timeout=5)
    print(f"[{label}] Published to {topic}: {payload}")
    time.sleep(1.0)
    client.loop_stop()
    client.disconnect()


if __name__ == "__main__":
    print("=" * 60)
    print("REMINDER: set COMPONENT1_DEMO_OVERRIDE=guidance in your")
    print(".env and restart the backend BEFORE running this script.")
    print("=" * 60)
    print()

    # Arbitrary, plausible-looking sensor sample — actual values don't
    # matter while the override is active (see module docstring).
    sample = {
        "ax": 0.05, "ay": -0.03, "az": 0.98,
        "gx": 0.10, "gy": 0.08, "gz": 0.05,
    }
    publish_once(COMPONENT1, COMPONENT1["topic"], sample, "Component 1")

    print("\nDone. Check your backend terminal for:")
    print('  [Component 1] fall_detected=True ... risk_level=LOW ...')
    print('  [Component 4] alert=Voice Alert ... guidance_enabled=True')
    print("\nThen check the Elder App — it should auto-switch to the")
    print("guidance screen and start speaking the steps aloud.")
    print("\nDon't forget to set COMPONENT1_DEMO_OVERRIDE=none afterwards.")
