"""
simulate_sensors.py

Publishes FAKE sensor data over real MQTT to HiveMQ, so Component
1/2/3's in-memory "latest" state (what Home Dashboard actually polls)
gets updated — unlike test_component4_direct.py, which calls
Component 4's decision logic directly over HTTP and never touches
MQTT at all. That script and this one test two different, genuinely
separate layers of the real system; this one is NOT a replacement
for that one.

Payload shapes below were read directly from the real backend source,
not guessed:
    Component 1: app/integration/mqtt/sensor_parser.py  (ax/ay/az/gx/gy/gz)
    Component 2: app/component2/mqtt_service.py          (discovery/telemetry)
    Component 3: app/component3/mqtt_service.py          (timestamp/red/ir)

WHERE TO RUN THIS FROM:
    Place this file in the SAME folder as your backend's real .env
    (e.g. eldercare-backend/), so it loads your REAL HiveMQ broker,
    credentials, and topic names — not guessed defaults. If your
    actual topic env vars (COMPONENT1_TOPIC etc.) differ from this
    script's fallback defaults, your .env values win automatically.

BEFORE RUNNING:
    pip install paho-mqtt python-dotenv --break-system-packages

USAGE:
    python simulate_sensors.py --component1          # one fall event
    python simulate_sensors.py --component2           # one zone, one reading
    python simulate_sensors.py --component3           # ~4s of PPG samples
    python simulate_sensors.py --all                  # all three, in sequence
    python simulate_sensors.py --component2 --risk high   # force a HIGH-risk zone reading
"""

import argparse
import json
import math
import ssl
import time

import paho.mqtt.client as mqtt
from dotenv import load_dotenv
import os

load_dotenv()

# ============================================================
# CONFIG — same env vars, same defaults, as app/core/config.py.
# If your .env sets these differently, those values are used
# automatically (load_dotenv() reads the same file).
# ============================================================
HIVEMQ_BROKER = os.getenv("HIVEMQ_BROKER")
HIVEMQ_PORT = int(os.getenv("HIVEMQ_PORT", "8883"))
HIVEMQ_USERNAME = os.getenv("HIVEMQ_USERNAME")
HIVEMQ_PASSWORD = os.getenv("HIVEMQ_PASSWORD")

COMPONENT1_TOPIC = os.getenv("COMPONENT1_TOPIC", "eldercare/component1/imu")
COMPONENT2_TOPIC_BASE = os.getenv("COMPONENT2_TOPIC", "eldercare/component2/#").rstrip("/#")
COMPONENT3_TOPIC = os.getenv("COMPONENT3_TOPIC", "eldercare/component3/vitals")

if not all([HIVEMQ_BROKER, HIVEMQ_USERNAME, HIVEMQ_PASSWORD]):
    raise SystemExit(
        "Missing HIVEMQ_BROKER / HIVEMQ_USERNAME / HIVEMQ_PASSWORD.\n"
        "Run this script from the same folder as your backend's real .env file."
    )


def connect() -> mqtt.Client:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="aegiscare-simulator")
    client.username_pw_set(HIVEMQ_USERNAME, HIVEMQ_PASSWORD)
    client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
    client.connect(HIVEMQ_BROKER, HIVEMQ_PORT, keepalive=30)
    client.loop_start()
    time.sleep(1.5)  # give the connection a moment to actually establish
    return client


def publish(client: mqtt.Client, topic: str, payload: dict, label: str):
    client.publish(topic, json.dumps(payload), qos=0)
    print(f"  -> [{topic}] {label}: {payload}")


# ============================================================
# COMPONENT 1 — a confirmed-fall-shaped IMU burst.
# Real Component 1 does its own fall-detection ML on raw ax/ay/az/
# gx/gy/gz; this sends a simple "sudden deceleration" shaped burst,
# not a guaranteed trigger — the model decides, same as with real
# hardware. If it doesn't trigger a fall, that's the model's real
# decision, not a bug in this simulator.
# ============================================================
def simulate_component1(client: mqtt.Client):
    print("\n[Component 1] Publishing an IMU burst shaped like a forward fall...")
    # FIXED: the real CRITICAL trigger (fall_detection.py's
    # analyze_sequence()) requires ALL of: stability == "Unstable",
    # the ML-predicted activity in ["Standing","Walking"], AND
    # ax_raw > 3.0 (or the equivalent for other directions). The
    # previous spike's az=2.0 was far enough from gravity (9.81) that
    # the trained activity classifier likely predicted something
    # other than Standing/Walking (plausibly Lying Down, given that
    # orientation), silently failing the activity condition even
    # though the raw-threshold condition was satisfied. This keeps az
    # close to gravity-normal so orientation still reads as upright,
    # while ax is still well past the 3.0 threshold and horizontal
    # magnitude (sqrt(ax^2+ay^2)) stays above the 2.0 instability
    # threshold too.
    samples = (
        [{"ax": 0.0, "ay": 0.0, "az": 9.8, "gx": 0.0, "gy": 0.0, "gz": 0.0}] * 5
        + [{"ax": 5.0, "ay": 0.5, "az": 8.8, "gx": 90.0, "gy": 20.0, "gz": 10.0}] * 3
        + [{"ax": 0.2, "ay": 0.1, "az": 0.3, "gx": 0.0, "gy": 0.0, "gz": 0.0}] * 10
    )
    for s in samples:
        publish(client, COMPONENT1_TOPIC, s, "IMU sample")
        time.sleep(0.1)
    print("[Component 1] Done. Check GET /component1/latest or Home Dashboard's Fall Detection card.")
    print("NOTE: this is still the real ML activity classifier's own decision —")
    print("if it still doesn't trigger, the model itself may classify this")
    print("specific input differently; that's a real model result, not a bug here.")


# ============================================================
# COMPONENT 2 — one zone, discovery + a telemetry reading.
# --risk {low,medium,high} controls which plausible sensor values
# are sent; the actual LOW/MEDIUM/HIGH/CRITICAL label is still the
# real calculate_risk() scoring the backend applies, not something
# this script decides directly.
# ============================================================
def simulate_component2(client: mqtt.Client, risk: str = "high"):
    device_id = "sim-sensor-01"
    zone_id = "Bathroom"

    print(f"\n[Component 2] Registering device '{device_id}' in zone '{zone_id}'...")
    publish(
        client,
        f"{COMPONENT2_TOPIC_BASE}/{device_id}/discovery",
        {"device_id": device_id, "device_type": "sensor_node", "zone_id": zone_id, "ip": "192.168.1.50"},
        "discovery",
    )
    time.sleep(0.5)

    presets = {
        "low": {"temperature": 24, "light": 400, "moisture": 10, "motion": False, "distance": 1500},
        "medium": {"temperature": 22, "light": 80, "moisture": 40, "motion": True, "distance": 700},
        "high": {"temperature": 20, "light": 15, "moisture": 85, "motion": True, "distance": 150},
    }
    sensors = presets.get(risk, presets["high"])
    sensors["device_id"] = device_id
    sensors["zone_id"] = zone_id

    print(f"[Component 2] Publishing a '{risk}' telemetry reading...")
    publish(client, f"{COMPONENT2_TOPIC_BASE}/{device_id}/telemetry", sensors, "telemetry")
    print("[Component 2] Done. Check GET /component2/devices or Home Dashboard's Environment card.")


# ============================================================
# COMPONENT 3 — a burst of PPG samples.
# The real PPGProcessor buffers/smooths across many samples before
# it reports a heart rate or BP — a single sample will likely just
# show "Waiting"/"No Finger Detected". This sends ~4 seconds at
# ~50Hz (the real sensor's rate) of a plausible oscillating
# red/ir waveform, so the processor has enough to actually compute
# a reading.
# ============================================================
def simulate_component3(client: mqtt.Client, duration_seconds: float = 4.0, hz: float = 50.0):
    print(f"\n[Component 3] Publishing ~{duration_seconds:.0f}s of PPG samples at {hz:.0f}Hz...")
    n_samples = int(duration_seconds * hz)
    interval = 1.0 / hz
    base_red, base_ir = 150000, 120000

    start = time.time()
    for i in range(n_samples):
        t = i / hz
        # A simple sinusoid at ~75bpm (1.25Hz) riding on a baseline,
        # with finger-presence-shaped amplitude — plausible, not a
        # claim of medical accuracy.
        red = int(base_red + 8000 * math.sin(2 * math.pi * 1.25 * t))
        ir = int(base_ir + 6000 * math.sin(2 * math.pi * 1.25 * t + 0.3))
        payload = {"timestamp": int((start + t) * 1000), "red": red, "ir": ir}
        client.publish(COMPONENT3_TOPIC, json.dumps(payload), qos=0)
        time.sleep(interval)
    print(f"  -> published {n_samples} samples on [{COMPONENT3_TOPIC}]")
    print("[Component 3] Done. Check GET /component3/latest or Home Dashboard's Vitals card.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Publish fake sensor data over real MQTT for testing.")
    parser.add_argument("--component1", action="store_true", help="Simulate a fall event (IMU)")
    parser.add_argument("--component2", action="store_true", help="Simulate an environment zone reading")
    parser.add_argument("--component3", action="store_true", help="Simulate a PPG vitals burst")
    parser.add_argument("--all", action="store_true", help="Run all three, in sequence")
    parser.add_argument("--risk", choices=["low", "medium", "high"], default="high", help="Component 2 preset")
    args = parser.parse_args()

    if not any([args.component1, args.component2, args.component3, args.all]):
        parser.print_help()
        raise SystemExit("\nPick at least one: --component1, --component2, --component3, or --all")

    print(f"Connecting to {HIVEMQ_BROKER}:{HIVEMQ_PORT} ...")
    client = connect()
    print("Connected.\n")

    try:
        if args.all or args.component1:
            simulate_component1(client)
        if args.all or args.component2:
            simulate_component2(client, risk=args.risk)
        if args.all or args.component3:
            simulate_component3(client)
    finally:
        client.loop_stop()
        client.disconnect()
        print("\nDisconnected. Check your Flutter app's Home Dashboard now.")