"""
test_medium_risk_scenario.py

Simulates a MEDIUM risk scenario across Component 1 (Fall Detection),
Component 2 (Environment), and Component 3 (Vitals) by publishing
directly to each component's HiveMQ Cloud cluster — the same way a
real ESP32 device would.

BEFORE RUNNING:
1. pip install paho-mqtt --break-system-packages
2. Fill in the CONFIG dict below with your actual .env values
   (COMPONENT1_HIVEMQ_*, HIVEMQ_* for Component 2, COMPONENT3_HIVEMQ_*)
3. Make sure your backend (uvicorn app.main:app) is already running
   and connected, so you can watch its terminal for the results.

RUN:
    python test_medium_risk_scenario.py

WHAT TO WATCH FOR in the backend terminal after running this:
    [Component 1] fall_detected=False fall_type=... risk_level=MEDIUM ...
    [Component 2] esp32-test-01 @ Bedroom: risk=MEDIUM (45) sensors={...}
    [Component 3] finger=True hr=... bp=... status=...

============================================================
IMPORTANT HONESTY NOTE — Component 1's MEDIUM outcome
============================================================
Component 1's risk_level comes from TWO layers (see
app/component1/ml/fall_detection.py):
  1. An ML classifier decides "activity" (Sitting/Standing/Walking)
     from the raw IMU values — this is a trained model's decision,
     not something this script can force with 100% certainty.
  2. A RULE layer (analyze_sequence()) then looks at how "activity"
     changed between two consecutive samples:
         Sitting -> Standing (Unstable) => MEDIUM
         Standing -> Walking (Unstable) => MEDIUM
         Walking  -> Standing (Unstable) => HIGH
         (Unstable + accel > 3.0 m/s^2 on Standing/Walking) => CRITICAL

This script sends two samples calibrated to the SAME statistical
ranges the model was trained on (a calm "Sitting" sample, followed by
a shakier "Standing" sample whose horizontal acceleration crosses the
2.0 m/s^2 "Unstable" threshold but stays under the 3.0 m/s^2 CRITICAL
threshold on any single axis). This should reliably reproduce MEDIUM,
but because step 1 is ML-based, it isn't a mathematical guarantee —
if your terminal shows a different risk_level, that's the classifier
making its own call on borderline data, not a bug in this script.
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
    time.sleep(1.0)  # give the connection a moment to establish
    result = client.publish(topic, json.dumps(payload), qos=1)
    result.wait_for_publish(timeout=5)
    print(f"[{label}] Published to {topic}: {payload}")
    time.sleep(0.5)
    client.loop_stop()
    client.disconnect()


# ============================================================
# COMPONENT 1 — two samples: Sitting (calm) -> Standing (shaky)
# Values are in G-UNITS (raw accelerometer units), matching what a
# real ESP32 sends — the backend converts to m/s^2 internally.
# ============================================================

def run_component1_scenario():
    print("\n=== Component 1: Sitting -> Standing (targeting MEDIUM) ===")

    # Sample 1: calm, seated — near-zero horizontal movement, gravity on Z.
    sitting_sample = {
        "ax": 0.01, "ay": -0.01, "az": 0.99,
        "gx": 0.02, "gy": 0.01, "gz": 0.01,
    }
    publish_once(COMPONENT1, COMPONENT1["topic"], sitting_sample, "Component 1")
    time.sleep(1.5)  # let the backend process sample 1 before sample 2

    # Sample 2: standing up, a bit unsteady — horizontal accel crosses
    # the 2.0 m/s^2 "Unstable" threshold (0.153g * 9.81 ~= 1.5 m/s^2 on
    # each axis => combined magnitude ~2.12 m/s^2) without any single
    # axis crossing the 3.0 m/s^2 CRITICAL threshold.
    standing_sample = {
        "ax": 0.153, "ay": 0.153, "az": 1.0,
        "gx": 0.30, "gy": 0.25, "gz": 0.15,
    }
    publish_once(COMPONENT1, COMPONENT1["topic"], standing_sample, "Component 1")


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

    run_component1_scenario()
    run_component2_scenario()
    run_component3_scenario()

    print("\nDone. Check your backend terminal for:")
    print('  [Component 1] ... risk_level=MEDIUM ...   (see honesty note above the script)')
    print('  [Component 2] ... risk=MEDIUM (45) ...')
    print('  [Component 3] finger=... hr=... bp=... status=...')
