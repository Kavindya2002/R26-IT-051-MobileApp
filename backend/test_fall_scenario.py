"""
test_fall_scenario.py

Simulates a REAL fall event (Component 1) alongside a MEDIUM-risk
environment reading (Component 2) and a vitals sample (Component 3),
by publishing directly to each component's HiveMQ Cloud cluster.

BEFORE RUNNING:
1. pip install paho-mqtt --break-system-packages
2. Fill in the CONFIG dict below with your actual .env values
3. Make sure your backend (uvicorn app.main:app) is already running

RUN:
    python test_fall_scenario.py

WHAT TO WATCH FOR in the backend terminal:
    [Component 1] fall_detected=True fall_type=... risk_level=CRITICAL ...
    [Component 4] alert=Emergency Alert confidence=... guidance_enabled=False
    [Component 2] esp32-test-01 @ Bedroom: risk=MEDIUM (45) sensors={...}
    [Component 3] finger=True hr=... bp=... status=...

THEN CHECK YOUR FLUTTER APP:
    - Home Dashboard's Emergency Alert banner should appear
    - Tapping it should open Alert Detail with the fall's info
    - History tab should show this alert as a new entry
      (only if DEFAULT_ELDER_ID is set in your .env to a real elder id
      — this automatic MQTT flow needs that to persist to history;
      see the "single-elder MVP limitation" note in config.py)

============================================================
WHY THIS SCRIPT TARGETS CRITICAL, NOT MEDIUM
============================================================
fall_detected is ONLY ever True when risk_level == "CRITICAL"
(see fall_detection.py's run_system()):

    fall_detected = risk_level == "CRITICAL" and prediction is not None

MEDIUM risk_level NEVER sets fall_detected=True, by design — it
represents a "watch this" signal (e.g. unsteady after standing up),
not a confirmed fall. If you want to see the Emergency Alert banner,
Component 4, and History actually populate in the Flutter app, you
need a CRITICAL scenario — that's what this script now sends.

Same ML-classifier caveat as before applies to fall_type specifically
(Forward/Backward/Side Fall) — the activity classification step is
ML-based. The rule-based CRITICAL trigger itself (raw accel > 3.0
m/s^2 while Unstable + Standing/Walking) is deterministic and should
reliably fire.
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

COMPONENT2 = {
    "broker": "c1b2ee8e40594600ba9b9be14aca99b8.s1.eu.hivemq.cloud",
    "port": 8883,
    "username": "hivemq.webclient.1786388509293",
    "password": "8vy!JUvE1@TgUGuzcN2rbf2clcor1PAS",
    "topic_prefix": "eldercare/component2",
    "device_id": "esp32-test-01",
}

COMPONENT3 = {
    "broker": "de21646cab9640a9bb82b08bf1a29887.s1.eu.hivemq.cloud",
    "port": 8883,
    "username": "kawidu",
    "password": "12345678",
    "topic": "patient/vitals",
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
    time.sleep(1.0)  # give the broker time to relay to the backend before we disconnect
    client.loop_stop()
    client.disconnect()


# ============================================================
# COMPONENT 1 — two samples: Standing (calm) -> Forward Fall
# Values are in G-UNITS (raw accelerometer units), matching what a
# real ESP32 sends — the backend converts to m/s^2 internally.
# ============================================================

def run_component1_fall_scenario():
    print("\n=== Component 1: Standing -> Forward Fall (targeting CRITICAL / fall_detected=True) ===")

    # Sample 1: standing, stable — establishes "Standing" as the
    # baseline activity the next sample's fall is measured against.
    standing_sample = {
        "ax": 0.01, "ay": -0.01, "az": 0.99,
        "gx": 0.02, "gy": 0.01, "gz": 0.01,
    }
    publish_once(COMPONENT1, COMPONENT1["topic"], standing_sample, "Component 1")
    time.sleep(1.5)  # let the backend process sample 1 before sample 2

    # Sample 2: a real forward fall — ax_raw crosses the 3.0 m/s^2
    # CRITICAL threshold (0.45g * 9.81 ~= 4.4 m/s^2) while Unstable.
    fall_sample = {
        "ax": 0.45, "ay": 0.05, "az": 0.3,
        "gx": 1.2, "gy": 0.8, "gz": 0.4,
    }
    publish_once(COMPONENT1, COMPONENT1["topic"], fall_sample, "Component 1")


# ============================================================
# COMPONENT 2 — telemetry calibrated to land in the MEDIUM band
# (score 31-60, see calculate_risk() in mqtt_service.py):
#   light=80    (30-100)   -> +10
#   distance=500 (300-600) -> +20
#   moisture=1500 (1000-2000) -> +10
#   motion=True            -> +5
#   TOTAL = 45  -> MEDIUM
# ============================================================

def run_component2_scenario():
    print("\n=== Component 2: Environment telemetry (targeting MEDIUM, score=45) ===")
    device_id = COMPONENT2["device_id"]

    discovery = {
        "device_id": device_id,
        "device_type": "sensor_node",
        "zone_id": "Bedroom",
    }
    publish_once(COMPONENT2, f"{COMPONENT2['topic_prefix']}/{device_id}/discovery", discovery, "Component 2")
    time.sleep(1.0)

    telemetry = {
        "device_id": device_id,
        "temperature": 29.5,
        "light": 80,
        "distance": 500,
        "moisture": 1500,
        "motion": True,
    }
    publish_once(COMPONENT2, f"{COMPONENT2['topic_prefix']}/{device_id}/telemetry", telemetry, "Component 2")


# ============================================================
# COMPONENT 3 — a representative vitals sample.
# NOTE: Component 3 has no "risk_level" concept (see conversation
# notes) — only health_status (Normal/Abnormal) from heart rate/BP
# thresholds. Included here for completeness, not to demonstrate a
# "MEDIUM" outcome specifically.
# ============================================================

def run_component3_scenario():
    print("\n=== Component 3: Vitals sample (for completeness — no risk_level here) ===")
    sample = {
        "timestamp": int(time.time() * 1000),
        "red": 85000,
        "ir": 92000,
    }
    publish_once(COMPONENT3, COMPONENT3["topic"], sample, "Component 3")


if __name__ == "__main__":
    print("Make sure your backend (uvicorn app.main:app) is running and connected")
    print("to all three clusters before running this script.\n")

    run_component1_fall_scenario()
    run_component2_scenario()
    run_component3_scenario()

    print("\nDone. Check your backend terminal for:")
    print('  [Component 1] fall_detected=True ... risk_level=CRITICAL ...')
    print('  [Component 4] alert=Emergency Alert ...')
    print('  [Component 2] ... risk=MEDIUM (45) ...')
    print('  [Component 3] finger=... hr=... bp=... status=...')
    print("\nThen open your Flutter app and check the Home Dashboard for the")
    print("Emergency Alert banner, and the History tab for the new entry.")
