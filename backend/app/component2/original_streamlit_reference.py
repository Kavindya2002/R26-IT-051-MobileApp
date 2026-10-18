"""
REFERENCE ONLY — NOT PART OF THE RUNNING BACKEND.

This is the original standalone Streamlit dashboard (main.py) that
the camera/YOLO/buzzer features in this project were ported from.
It is kept here only so the mapping from "old file" to "new files"
is traceable:

    Old (this file)                          New (actually used)
    --------------------------------------   ------------------------------------------
    CameraWorker class                    -> app/component2/camera_service.py
    get_yolo_model() / YOLO config        -> app/component2/camera_service.py
                                              + app/core/config.py (YOLO_* settings)
    control_buzzer() (MQTT publish)       -> Component2MqttService.publish_buzzer_command()
                                              in app/component2/mqtt_service.py
    render_device_cards() / zone summary  -> GET /component2/devices (api/router.py)
                                              — Flutter renders its own UI from this JSON
    render_camera_dashboard()             -> GET /component2/cameras +
                                              GET /component2/cameras/{id}/snapshot
    render_risk_map() (Plotly 3D map)     -> NOT ported — Plotly/Streamlit can't run in
                                              Flutter. The same risk_level/risk_score data
                                              is available via the JSON endpoints above;
                                              build any map/visualization in Flutter itself.
    Standalone `st.cache_resource` state  -> NOT ported — this project's whole design
                                              principle (see mqtt_service.py's docstring)
                                              is ONE process (FastAPI) owning all state,
                                              instead of a second Streamlit process trying
                                              to share memory with it (which cannot work
                                              across OS processes — that was the original
                                              project's biggest bug).

Do not `streamlit run` this file as part of the product — it will
start its own separate MQTT connection and duplicate everything the
FastAPI backend already does. It is left here purely for reference
during development.
"""

import os
import ssl
import json
import copy
import time
import math
import threading
from datetime import datetime

import cv2
import numpy as np
import streamlit as st
import paho.mqtt.client as mqtt
import plotly.graph_objects as go

from dotenv import load_dotenv

# YOLO is intentionally imported lazily so the dashboard can still start and
# report the missing dependency/model instead of crashing.
try:
    from ultralytics import YOLO
except Exception:
    YOLO = None


# ============================================================
# ENVIRONMENT
# ============================================================

load_dotenv()

st.set_page_config(
    page_title="ElderCare Monitoring",
    page_icon="🏠",
    layout="wide",
    initial_sidebar_state="expanded",
)


# ============================================================
# MQTT CONFIGURATION
# ============================================================

MQTT_HOST = os.getenv("MQTT_HOST", "your-hivemq-host")
MQTT_PORT = int(os.getenv("MQTT_PORT", "8883"))
MQTT_USERNAME = os.getenv("MQTT_USERNAME", "your-username")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "your-password")

MQTT_ROOT_TOPIC = "eldercare/#"

# Reconnect/check timing.
MQTT_KEEPALIVE = int(os.getenv("MQTT_KEEPALIVE", "60"))
MQTT_STATUS_TIMEOUT = float(os.getenv("MQTT_STATUS_TIMEOUT", "15"))

# Device heartbeat timeout. A device is shown as OFFLINE when Python has not
# received telemetry/status/discovery from it for this many seconds.
DEVICE_OFFLINE_TIMEOUT = float(os.getenv("DEVICE_OFFLINE_TIMEOUT", "15"))

# ============================================================
# YOLO CONFIGURATION
# ============================================================
#
# Set YOLO_MODEL in .env if you have your own trained model:
#
# YOLO_MODEL=best.pt
#
# If omitted, Ultralytics will use/download yolov8n.pt.
#
YOLO_MODEL_PATH = os.getenv("YOLO_MODEL", "yolov8n.pt")
YOLO_CONFIDENCE = float(os.getenv("YOLO_CONFIDENCE", "0.35"))
YOLO_IOU = float(os.getenv("YOLO_IOU", "0.45"))
YOLO_IMAGE_SIZE = int(os.getenv("YOLO_IMAGE_SIZE", "640"))
YOLO_DEVICE = os.getenv("YOLO_DEVICE", "").strip() or None

# Camera worker settings.
CAMERA_RECONNECT_SECONDS = float(
    os.getenv("CAMERA_RECONNECT_SECONDS", "3")
)
CAMERA_TARGET_FPS = float(
    os.getenv("CAMERA_TARGET_FPS", "10")
)


# ============================================================
# APPLICATION STATE
# ============================================================

@st.cache_resource
def _get_app_state():
    return {
        "devices": {},
        "zones": {},

        "mqtt_connected": False,
        "mqtt_client": None,
        "mqtt_started": False,

        "mqtt_last_change": None,
        "mqtt_last_error": None,

        "last_message": None,
        "message_count": 0,

        "yolo_model": None,
        "yolo_loading": False,
        "yolo_error": None,
    }


@st.cache_resource
def _get_state_lock():
    return threading.RLock()


APP_STATE = _get_app_state()
STATE_LOCK = _get_state_lock()


# ============================================================
# CAMERA WORKERS
# ============================================================

CAMERA_WORKERS = {}
CAMERA_WORKERS_LOCK = threading.RLock()


class CameraWorker:
    """
    One worker per discovered ESP32-CAM.

    The worker owns the OpenCV VideoCapture and continuously:
      ESP32-CAM MJPEG -> OpenCV frame -> YOLO -> JPEG
    """

    def __init__(self, device_id, stream_url):
        self.device_id = device_id
        self.stream_url = stream_url

        self.stop_event = threading.Event()
        self.thread = None

        self.lock = threading.RLock()

        self.latest_jpeg = None
        self.latest_frame_time = None
        self.latest_fps = 0.0
        self.latest_detection_count = 0
        self.last_error = None

        self.frames_seen = 0
        self.last_fps_time = time.monotonic()

    def start(self):
        if self.thread and self.thread.is_alive():
            return

        self.stop_event.clear()

        self.thread = threading.Thread(
            target=self.run,
            name=f"yolo-camera-{self.device_id}",
            daemon=True,
        )

        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def update_stream_url(self, stream_url):
        if stream_url and stream_url != self.stream_url:
            self.stream_url = stream_url
            # Force the current capture loop to reopen the new URL.
            self.stop_event.set()

    def get_snapshot(self):
        with self.lock:
            return {
                "jpeg": self.latest_jpeg,
                "frame_time": self.latest_frame_time,
                "fps": self.latest_fps,
                "detections": self.latest_detection_count,
                "error": self.last_error,
            }

    def _open_capture(self):
        # ESP32-CAM exposes an MJPEG stream over HTTP.
        cap = cv2.VideoCapture(self.stream_url)

        # These are harmless if the backend does not support them.
        try:
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        except Exception:
            pass

        if not cap.isOpened():
            cap.release()
            return None

        return cap

    def _annotate(self, frame):
        model = get_yolo_model()

        if model is None:
            return frame, 0

        try:
            kwargs = {
                "source": frame,
                "conf": YOLO_CONFIDENCE,
                "iou": YOLO_IOU,
                "imgsz": YOLO_IMAGE_SIZE,
                "verbose": False,
            }

            if YOLO_DEVICE:
                kwargs["device"] = YOLO_DEVICE

            results = model.predict(**kwargs)

            if not results:
                return frame, 0

            result = results[0]

            annotated = result.plot(
                conf=True,
                labels=True,
                boxes=True,
            )

            count = 0
            if result.boxes is not None:
                count = len(result.boxes)

            return annotated, count

        except Exception as exc:
            with STATE_LOCK:
                APP_STATE["yolo_error"] = str(exc)

            return frame, 0

    def run(self):
        frame_delay = (
            1.0 / CAMERA_TARGET_FPS
            if CAMERA_TARGET_FPS > 0
            else 0
        )

        while not self.stop_event.is_set():

            # If this worker was stopped because the URL changed,
            # reset the event and continue using the new URL.
            if self.stop_event.is_set():
                self.stop_event.clear()

            cap = self._open_capture()

            if cap is None:
                with self.lock:
                    self.last_error = (
                        f"Unable to open stream: {self.stream_url}"
                    )

                time.sleep(CAMERA_RECONNECT_SECONDS)
                continue

            with self.lock:
                self.last_error = None

            while not self.stop_event.is_set():

                loop_started = time.monotonic()

                ok, frame = cap.read()

                if not ok or frame is None:
                    with self.lock:
                        self.last_error = "Camera stream read failed."

                    break

                annotated, detection_count = self._annotate(frame)

                ok_jpeg, jpeg = cv2.imencode(
                    ".jpg",
                    annotated,
                    [
                        int(cv2.IMWRITE_JPEG_QUALITY),
                        82,
                    ],
                )

                if ok_jpeg:
                    with self.lock:
                        self.latest_jpeg = jpeg.tobytes()
                        self.latest_frame_time = datetime.now()
                        self.latest_detection_count = detection_count
                        self.last_error = None

                self.frames_seen += 1

                now_mono = time.monotonic()
                elapsed = now_mono - self.last_fps_time

                if elapsed >= 1.0:
                    with self.lock:
                        self.latest_fps = (
                            self.frames_seen / elapsed
                        )

                    self.frames_seen = 0
                    self.last_fps_time = now_mono

                processing_time = time.monotonic() - loop_started

                if frame_delay > processing_time:
                    time.sleep(
                        frame_delay - processing_time
                    )

            cap.release()

            if not self.stop_event.is_set():
                time.sleep(CAMERA_RECONNECT_SECONDS)


def ensure_camera_worker(device):
    device_id = device.get("device_id")
    stream_url = device.get("stream_url")

    if not device_id or not stream_url:
        return

    with CAMERA_WORKERS_LOCK:

        worker = CAMERA_WORKERS.get(device_id)

        if worker is None:
            worker = CameraWorker(
                device_id,
                stream_url,
            )

            CAMERA_WORKERS[device_id] = worker
            worker.start()

        elif worker.stream_url != stream_url:
            worker.update_stream_url(stream_url)

            # update_stream_url sets stop_event. The worker will reopen
            # the new URL on its next cycle.
            worker.start()


def sync_camera_workers():
    devices = get_devices_snapshot()

    for device in devices.values():

        if device.get("device_type") != "camera":
            continue

        if device.get("stream_url"):
            ensure_camera_worker(device)


# ============================================================
# YOLO MODEL
# ============================================================

def get_yolo_model():
    if YOLO is None:
        with STATE_LOCK:
            APP_STATE["yolo_error"] = (
                "Ultralytics is not installed. "
                "Install it with: pip install ultralytics"
            )
        return None

    with STATE_LOCK:

        if APP_STATE["yolo_model"] is not None:
            return APP_STATE["yolo_model"]

        if APP_STATE["yolo_loading"]:
            return None

        APP_STATE["yolo_loading"] = True

    try:
        print(f"Loading YOLO model: {YOLO_MODEL_PATH}")

        model = YOLO(YOLO_MODEL_PATH)

        with STATE_LOCK:
            APP_STATE["yolo_model"] = model
            APP_STATE["yolo_error"] = None
            APP_STATE["yolo_loading"] = False

        print("YOLO model loaded.")

        return model

    except Exception as exc:

        with STATE_LOCK:
            APP_STATE["yolo_loading"] = False
            APP_STATE["yolo_error"] = str(exc)

        print("YOLO model loading failed:", exc)

        return None


# ============================================================
# DEVICE FACTORY
# ============================================================

def create_device(device_id, device_type="unknown"):
    return {
        "device_id": device_id,
        "device_type": device_type,
        "zone_id": None,
        "ip": None,
        "mac": None,
        "rssi": None,
        "status": "OFFLINE",
        "last_seen": None,
        "sensors": {},
        "available_sensors": [],
        "actuators": [],
        "buzzer": False,
        "stream_url": None,
        "snapshot_url": None,
    }


def get_device(device_id, device_type="unknown"):

    with STATE_LOCK:

        devices = APP_STATE["devices"]

        if device_id not in devices:
            devices[device_id] = create_device(
                device_id,
                device_type,
            )

        device = devices[device_id]

        if (
            device.get("device_type") == "unknown"
            and device_type != "unknown"
        ):
            device["device_type"] = device_type

        return device


def get_devices_snapshot():
    with STATE_LOCK:
        return copy.deepcopy(APP_STATE["devices"])


def get_zones_snapshot():
    with STATE_LOCK:
        return copy.deepcopy(APP_STATE["zones"])


# ============================================================
# ZONE MANAGEMENT
# ============================================================

def update_zone_from_device(device):

    zone_id = device.get("zone_id")

    if not zone_id:
        return

    zone_id = str(zone_id)

    with STATE_LOCK:

        zones = APP_STATE["zones"]

        if zone_id not in zones:
            zones[zone_id] = {
                "zone_id": zone_id,
                "risk_score": 0,
                "risk_level": "LOW",
                "devices": [],
                "first_seen": datetime.now(),
                "last_seen": datetime.now(),
            }

        zone = zones[zone_id]

        device_id = device["device_id"]

        if device_id not in zone["devices"]:
            zone["devices"].append(device_id)

        zone["last_seen"] = datetime.now()


# ============================================================
# DISCOVERY
# ============================================================

def handle_discovery(payload):

    device_id = payload.get("device_id")

    if not device_id:
        print("Discovery message without device_id")
        return

    device_type = payload.get(
        "device_type",
        "unknown",
    )

    device = get_device(
        device_id,
        device_type,
    )

    with STATE_LOCK:

        device["device_type"] = device_type

        for field in [
            "zone_id",
            "ip",
            "mac",
            "rssi",
        ]:
            if field in payload:
                device[field] = payload[field]

        device["available_sensors"] = payload.get(
            "sensors",
            device.get("available_sensors", []),
        )

        device["actuators"] = payload.get(
            "actuators",
            device.get("actuators", []),
        )

        if device_type == "camera":

            device["stream_url"] = payload.get(
                "stream_url",
                device.get("stream_url"),
            )

            device["snapshot_url"] = payload.get(
                "snapshot_url",
                device.get("snapshot_url"),
            )

        device["status"] = "ONLINE"
        device["last_seen"] = datetime.now()

    update_zone_from_device(device)

    if device_type == "camera":
        ensure_camera_worker(device)

    print(
        f"DEVICE DISCOVERED | "
        f"{device_id} | "
        f"{device_type} | "
        f"zone={device.get('zone_id')} | "
        f"ip={device.get('ip')}"
    )


# ============================================================
# STATUS
# ============================================================

def handle_status(payload):

    device_id = payload.get("device_id")

    if not device_id:
        return

    device = get_device(device_id)

    with STATE_LOCK:

        for field in [
            "zone_id",
            "ip",
            "rssi",
        ]:
            if field in payload:
                device[field] = payload[field]

        status = str(
            payload.get("status", "online")
        ).lower()

        device["status"] = (
            "ONLINE"
            if status == "online"
            else "OFFLINE"
        )

        if "buzzer" in payload:
            device["buzzer"] = payload["buzzer"]

        device["last_seen"] = datetime.now()

    update_zone_from_device(device)


# ============================================================
# TELEMETRY
# ============================================================

def handle_telemetry(payload):

    device_id = payload.get("device_id")

    if not device_id:
        print("Telemetry without device_id")
        return

    device = get_device(
        device_id,
        "sensor_node",
    )

    with STATE_LOCK:

        device["device_type"] = "sensor_node"

        device["zone_id"] = payload.get(
            "zone_id",
            device.get("zone_id"),
        )

        device["ip"] = payload.get(
            "ip",
            device.get("ip"),
        )

        device["sensors"] = {
            "temperature": payload.get("temperature"),
            "light": payload.get("light"),
            "moisture": payload.get("moisture"),
            "motion": payload.get("motion"),
            "distance": payload.get("distance"),
            "tof_timeout": payload.get("tof_timeout"),
            "accX": payload.get("accX"),
            "accY": payload.get("accY"),
            "accZ": payload.get("accZ"),
            "gyroX": payload.get("gyroX"),
            "gyroY": payload.get("gyroY"),
            "gyroZ": payload.get("gyroZ"),
            "buzzer": payload.get("buzzer"),
        }

        if "buzzer" in payload:
            device["buzzer"] = payload["buzzer"]

        device["status"] = "ONLINE"
        device["last_seen"] = datetime.now()

    update_zone_from_device(device)


# ============================================================
# MQTT MESSAGE PROCESSOR
# ============================================================

def mqtt_message_handler(topic, payload):

    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        print("Invalid JSON received:", payload)
        return

    with STATE_LOCK:

        APP_STATE["last_message"] = {
            "topic": topic,
            "payload": data,
            "time": datetime.now(),
        }

        APP_STATE["message_count"] += 1

    if topic.endswith("/discovery"):
        handle_discovery(data)
        return

    if topic.endswith("/status"):
        handle_status(data)
        return

    if topic.endswith("/telemetry"):
        handle_telemetry(data)
        return

    print("Unhandled MQTT topic:", topic)


# ============================================================
# MQTT CALLBACKS
# ============================================================

def mqtt_on_connect(
    client,
    userdata,
    flags,
    reason_code,
    properties=None,
):
    # Paho MQTT v2 passes a ReasonCode object here.
    # Do NOT call int(reason_code): newer Paho versions do not
    # expose it as a directly-convertible integer.
    connection_ok = (
        reason_code == 0
        or str(reason_code).strip().lower() == "success"
    )

    print(
        "MQTT connected callback:",
        reason_code,
        "| success:",
        connection_ok,
    )

    with STATE_LOCK:

        APP_STATE["mqtt_connected"] = connection_ok

        APP_STATE["mqtt_last_change"] = datetime.now()

        if connection_ok:
            APP_STATE["mqtt_last_error"] = None
        else:
            APP_STATE["mqtt_last_error"] = (
                f"MQTT connection rejected: {reason_code}"
            )

    if not connection_ok:
        return

    try:

        result = client.subscribe(
            MQTT_ROOT_TOPIC,
            qos=0,
        )

        print(
            "Subscribed to",
            MQTT_ROOT_TOPIC,
            "result=",
            result,
        )

    except Exception as exc:

        with STATE_LOCK:
            APP_STATE["mqtt_last_error"] = str(exc)

        print("MQTT subscribe failed:", exc)


def mqtt_on_disconnect(
    client,
    userdata,
    disconnect_flags,
    reason_code,
    properties=None,
):
    print("MQTT disconnected:", reason_code)

    with STATE_LOCK:

        APP_STATE["mqtt_connected"] = False
        APP_STATE["mqtt_last_change"] = datetime.now()

        if reason_code != mqtt.MQTT_ERR_SUCCESS:
            APP_STATE["mqtt_last_error"] = (
                f"Disconnected: {reason_code}"
            )


def mqtt_on_message(client, userdata, msg):

    payload = msg.payload.decode(
        "utf-8",
        errors="ignore",
    )

    mqtt_message_handler(
        msg.topic,
        payload,
    )


# ============================================================
# MQTT CONNECTION MONITOR
# ============================================================

def refresh_mqtt_connection_state():

    with STATE_LOCK:
        client = APP_STATE["mqtt_client"]

    if client is None:
        with STATE_LOCK:
            APP_STATE["mqtt_connected"] = False
        return

    try:
        actual = bool(client.is_connected())

        with STATE_LOCK:
            previous = APP_STATE["mqtt_connected"]

            APP_STATE["mqtt_connected"] = actual

            if previous != actual:
                APP_STATE["mqtt_last_change"] = datetime.now()

    except Exception as exc:

        with STATE_LOCK:
            APP_STATE["mqtt_connected"] = False
            APP_STATE["mqtt_last_error"] = str(exc)


def is_mqtt_connected():

    refresh_mqtt_connection_state()

    with STATE_LOCK:
        return APP_STATE["mqtt_connected"]


def get_mqtt_client():

    with STATE_LOCK:
        return APP_STATE["mqtt_client"]


# ============================================================
# START MQTT
# ============================================================

def start_mqtt():

    with STATE_LOCK:

        existing = APP_STATE["mqtt_client"]

        if existing is not None:
            # The client already exists. Its real connection state
            # is checked on every Streamlit refresh.
            return

    print("Starting MQTT client...")

    try:

        client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id="eldercare-streamlit",
            protocol=mqtt.MQTTv311,
        )

        client.username_pw_set(
            MQTT_USERNAME,
            MQTT_PASSWORD,
        )

        # Development configuration matching the ESP32 code.
        client.tls_set(
            cert_reqs=ssl.CERT_NONE,
        )

        client.tls_insecure_set(True)

        client.reconnect_delay_set(
            min_delay=1,
            max_delay=30,
        )

        client.on_connect = mqtt_on_connect
        client.on_disconnect = mqtt_on_disconnect
        client.on_message = mqtt_on_message

        with STATE_LOCK:
            APP_STATE["mqtt_client"] = client
            APP_STATE["mqtt_started"] = True
            APP_STATE["mqtt_last_error"] = None

        # connect_async + loop_start avoids blocking Streamlit.
        client.connect_async(
            MQTT_HOST,
            MQTT_PORT,
            keepalive=MQTT_KEEPALIVE,
        )

        client.loop_start()

        print("MQTT background loop started.")

    except Exception as exc:

        print("MQTT startup failed:", exc)

        with STATE_LOCK:

            APP_STATE["mqtt_connected"] = False
            APP_STATE["mqtt_started"] = False
            APP_STATE["mqtt_last_error"] = str(exc)


# ============================================================
# MQTT PUBLISH
# ============================================================

def mqtt_publish(topic, payload):

    with STATE_LOCK:
        client = APP_STATE["mqtt_client"]

    if client is None:
        return False

    try:

        if not client.is_connected():
            refresh_mqtt_connection_state()
            return False

        result = client.publish(
            topic,
            payload,
            qos=0,
            retain=False,
        )

        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            print("MQTT published:", topic, payload)
            return True

        print("MQTT publish failed:", result.rc)
        return False

    except Exception as exc:

        with STATE_LOCK:
            APP_STATE["mqtt_connected"] = False
            APP_STATE["mqtt_last_error"] = str(exc)

        print("MQTT publish exception:", exc)
        return False


# ============================================================
# BUZZER CONTROL
# ============================================================

def control_buzzer(device_id, state):

    topic = (
        "eldercare/sensors/"
        f"{device_id}/command"
    )

    # Send compact JSON so the ESP32 command parser can recognize it.
    # The previous json.dumps() inserted spaces after ':' and ',' which
    # did not match the ESP32 string checks.
    payload = json.dumps(
        {
            "command": "buzzer",
            "state": bool(state),
        },
        separators=(",", ":"),
    )

    success = mqtt_publish(
        topic,
        payload,
    )

    if success:
        # This is only an optimistic UI update. The ESP32 telemetry/status
        # messages remain the authoritative hardware state.
        with STATE_LOCK:
            if device_id in APP_STATE["devices"]:
                APP_STATE["devices"][device_id]["buzzer"] = bool(state)

    return success


# ============================================================
# RISK ENGINE
# ============================================================

def calculate_risk(device):
    sensors = device.get("sensors", {})
    risk = 0

    # 1. Ambient Light (Lower lux = darker room = higher fall risk)
    light = sensors.get("light")
    if light is not None:
        if light < 20:
            risk += 30
        elif light < 50:
            risk += 20
        elif light < 100:
            risk += 10

    # 2. Distance / Proximity (Lower mm = closer obstacle = higher risk)
    distance = sensors.get("distance")
    if distance is not None:
        if distance < 300:
            risk += 35
        elif distance < 600:
            risk += 20
        elif distance < 1000:
            risk += 5

    # 3. Moisture (ESP32 ADC 12-bit: ~4095 = Dry, <1000 = Very Wet/Spill)
    moisture = sensors.get("moisture")
    if moisture is not None:
        if moisture < 1000:       # High wetness / water spill detected
            risk += 30
        elif moisture < 2000:     # Medium wetness
            risk += 20
        elif moisture < 3000:     # Slight dampness
            risk += 10
        # Values between 3000 and 4095 represent dry floor -> 0 added risk

    # 4. Motion
    if sensors.get("motion"):
        risk += 5

    return min(risk, 100)

def risk_level(score):

    if score < 31:
        return "LOW"

    if score < 61:
        return "MEDIUM"

    return "HIGH"


def get_risk_color(score):

    if score < 31:
        return "green"

    if score < 61:
        return "yellow"

    return "red"


def calculate_zone_risk(zone_id):

    devices = get_devices_snapshot()

    sensor_devices = [
        device
        for device in devices.values()
        if device.get("zone_id") == zone_id
        and device.get("device_type") == "sensor_node"
    ]

    if not sensor_devices:
        return 0

    return max(
        calculate_risk(device)
        for device in sensor_devices
    )


# ============================================================
# DEVICE STATUS
# ============================================================

def refresh_device_status():

    now = datetime.now()

    with STATE_LOCK:

        for device in APP_STATE["devices"].values():

            last_seen = device.get("last_seen")

            # A device that has never sent a message is offline.
            if last_seen is None:
                device["status"] = "OFFLINE"
                continue

            elapsed = (
                now - last_seen
            ).total_seconds()

            # Do NOT remove the device from the dashboard.
            # Keep it visible, but clearly mark it disconnected.
            if elapsed > DEVICE_OFFLINE_TIMEOUT:
                device["status"] = "OFFLINE"
            else:
                device["status"] = "ONLINE"

            device["seconds_since_seen"] = max(
                0,
                int(elapsed),
            )


# ============================================================
# DYNAMIC 3D MAP
# ============================================================

def _dynamic_zone_positions(zone_ids):
    """
    Generate positions from the currently discovered zones.

    IMPORTANT:
    There are no physical X/Y coordinates in the current ESP32 MQTT
    messages, so Python cannot reconstruct the real floor plan.
    This function therefore creates a dynamic spatial visualization
    from discovered zone IDs rather than hardcoding Bedroom/Living Room/
    Bathroom/Kitchen.

    If a future MQTT payload contains x/y/z coordinates, this function
    can be replaced with those real coordinates without changing the
    dashboard architecture.
    """

    count = len(zone_ids)

    if count == 0:
        return {}

    cols = max(
        1,
        math.ceil(math.sqrt(count))
    )

    spacing = 4.0

    positions = {}

    for index, zone_id in enumerate(zone_ids):

        row = index // cols
        col = index % cols

        positions[zone_id] = (
            col * spacing,
            row * spacing,
        )

    return positions


def _box_mesh(fig, x, y, width, depth, height, color, name, hover):
    x1 = x - width / 2
    x2 = x + width / 2
    y1 = y - depth / 2
    y2 = y + depth / 2

    vertices = [
        (x1, y1, 0),
        (x2, y1, 0),
        (x2, y2, 0),
        (x1, y2, 0),
        (x1, y1, height),
        (x2, y1, height),
        (x2, y2, height),
        (x1, y2, height),
    ]

    xs = [v[0] for v in vertices]
    ys = [v[1] for v in vertices]
    zs = [v[2] for v in vertices]

    i = [
        0, 0, 0,
        1, 1, 2,
        4, 4, 5,
        0, 0, 1,
        3, 3,
    ]

    j = [
        1, 2, 4,
        2, 5, 3,
        5, 6, 6,
        4, 7, 5,
        0, 7,
    ]

    k = [
        2, 3, 5,
        5, 6, 7,
        6, 7, 2,
        7, 5, 6,
        7, 4,
    ]

    fig.add_trace(
        go.Mesh3d(
            x=xs,
            y=ys,
            z=zs,
            i=i,
            j=j,
            k=k,
            color=color,
            opacity=0.58,
            flatshading=True,
            name=name,
            hovertext=hover,
            hoverinfo="text",
            showlegend=False,
        )
    )


def create_3d_map():

    fig = go.Figure()

    zones = get_zones_snapshot()

    zone_ids = sorted(zones.keys())

    if not zone_ids:

        fig.add_trace(
            go.Scatter3d(
                x=[0],
                y=[0],
                z=[0],
                mode="text",
                text=[
                    "Waiting for MQTT device discovery..."
                ],
                showlegend=False,
            )
        )

        fig.update_layout(
            scene={
                "xaxis": {"visible": False},
                "yaxis": {"visible": False},
                "zaxis": {"visible": False},
            },
            height=600,
            margin={
                "l": 0,
                "r": 0,
                "t": 0,
                "b": 0,
            },
        )

        return fig

    positions = _dynamic_zone_positions(zone_ids)

    # ========================================================
    # ZONE OBJECTS
    # ========================================================

    for zone_id in zone_ids:

        score = calculate_zone_risk(zone_id)
        level = risk_level(score)
        color = get_risk_color(score)

        x, y = positions[zone_id]

        zone = zones[zone_id]

        devices = get_devices_snapshot()

        zone_devices = [
            device
            for device in devices.values()
            if device.get("zone_id") == zone_id
        ]

        _box_mesh(
            fig,
            x=x,
            y=y,
            width=3.2,
            depth=2.7,
            height=1.8,
            color=color,
            name=zone_id,
            hover=(
                f"<b>{zone_id}</b>"
                f"<br>Risk: {score}"
                f"<br>Level: {level}"
                f"<br>Devices: {len(zone_devices)}"
            ),
        )

        fig.add_trace(
            go.Scatter3d(
                x=[x],
                y=[y],
                z=[2.1],
                mode="text",
                text=[
                    f"{zone_id}"
                    f"<br>Risk {score}"
                ],
                textfont={
                    "size": 13,
                },
                showlegend=False,
                hoverinfo="skip",
            )
        )

        # ====================================================
        # DEVICE MARKERS
        #
        # Devices are distributed around their discovered zone.
        # Their existence and labels are entirely MQTT-driven.
        # ====================================================

        for device_index, device in enumerate(zone_devices):

            angle = (
                2
                * math.pi
                * device_index
                / max(1, len(zone_devices))
            )

            radius = 1.05

            dx = x + math.cos(angle) * radius
            dy = y + math.sin(angle) * radius

            device_type = device.get(
                "device_type",
                "unknown",
            )

            device_status = device.get(
                "status",
                "OFFLINE",
            )

            marker_color = (
                "green"
                if device_status == "ONLINE"
                else "red"
            )

            symbol = (
                "diamond"
                if device_type == "camera"
                else "circle"
            )

            fig.add_trace(
                go.Scatter3d(
                    x=[dx],
                    y=[dy],
                    z=[2.5],
                    mode="markers+text",
                    text=[device.get("device_id")],
                    textposition="top center",
                    marker={
                        "size": 8,
                        "color": marker_color,
                        "symbol": symbol,
                    },
                    hovertext=(
                        f"<b>{device.get('device_id')}</b>"
                        f"<br>Type: {device_type}"
                        f"<br>Status: {device_status}"
                        f"<br>Zone: {zone_id}"
                        f"<br>IP: {device.get('ip') or '-'}"
                    ),
                    hoverinfo="text",
                    showlegend=False,
                )
            )

    # ========================================================
    # SCENE
    # ========================================================

    fig.update_layout(

        scene={
            "xaxis": {
                "title": "Dynamic X",
                "showgrid": True,
            },

            "yaxis": {
                "title": "Dynamic Y",
                "showgrid": True,
            },

            "zaxis": {
                "title": "Height",
                "showgrid": True,
            },

            "aspectmode": "data",

            "camera": {
                "eye": {
                    "x": 1.6,
                    "y": 1.6,
                    "z": 1.15,
                }
            },
        },

        height=600,

        margin={
            "l": 0,
            "r": 0,
            "t": 0,
            "b": 0,
        },

        showlegend=False,
    )

    return fig


# ============================================================
# CAMERA RENDERING
# ============================================================

def render_camera(device):

    device_id = device.get("device_id")

    with CAMERA_WORKERS_LOCK:
        worker = CAMERA_WORKERS.get(device_id)

    if worker is None:
        st.warning("Starting camera/YOLO worker...")
        ensure_camera_worker(device)
        return

    snapshot = worker.get_snapshot()

    jpeg = snapshot["jpeg"]

    if jpeg:

        st.image(
            jpeg,
            width="stretch",
        )

        info_cols = st.columns(3)

        with info_cols[0]:
            st.metric(
                "YOLO FPS",
                f"{snapshot['fps']:.1f}",
            )

        with info_cols[1]:
            st.metric(
                "Detections",
                snapshot["detections"],
            )

        with info_cols[2]:

            if snapshot["frame_time"]:
                st.metric(
                    "Frame",
                    snapshot["frame_time"].strftime(
                        "%H:%M:%S"
                    ),
                )
            else:
                st.metric(
                    "Frame",
                    "-",
                )

    else:

        st.info(
            "Waiting for annotated camera frames..."
        )

    if snapshot["error"]:
        st.caption(
            f"Camera worker: {snapshot['error']}"
        )


# ============================================================
# SIDEBAR
# ============================================================

def render_sidebar():

    st.sidebar.title("🏠 ElderCare")

    st.sidebar.caption(
        "Multimodal Environmental Risk Monitoring"
    )

    st.sidebar.divider()

    if is_mqtt_connected():
        st.sidebar.success("🟢 MQTT Connected")
    else:
        st.sidebar.error("🔴 MQTT Disconnected")

    devices = get_devices_snapshot()

    online = sum(
        1
        for device in devices.values()
        if device.get("status") == "ONLINE"
    )

    sensors = [
        device
        for device in devices.values()
        if device.get("device_type") == "sensor_node"
    ]

    cameras = [
        device
        for device in devices.values()
        if device.get("device_type") == "camera"
    ]

    offline = len(devices) - online

    st.sidebar.metric("Devices", len(devices))
    st.sidebar.metric("Connected", online)
    st.sidebar.metric("Disconnected", offline)
    st.sidebar.metric("Sensor Nodes", len(sensors))
    st.sidebar.metric("Cameras", len(cameras))

    st.sidebar.divider()

    st.sidebar.caption("MQTT Topic")
    st.sidebar.code(MQTT_ROOT_TOPIC)

    st.sidebar.caption("YOLO Model")
    st.sidebar.code(YOLO_MODEL_PATH)


# ============================================================
# DEVICE CARDS
# ============================================================

def render_device_cards():

    st.subheader("📡 Devices")

    st.caption(
        f"Connected = message received within the last "
        f"{DEVICE_OFFLINE_TIMEOUT:.0f}s • "
        "Disconnected devices remain listed for identification."
    )

    devices = get_devices_snapshot()
    device_list = list(devices.values())

    if not device_list:
        st.info("Waiting for device discovery...")
        return

    columns = st.columns(
        min(len(device_list), 4)
    )

    for index, device in enumerate(device_list):

        with columns[index % len(columns)]:

            device_id = device["device_id"]
            device_type = device["device_type"]
            zone = device.get("zone_id", "-")
            status = device.get("status", "OFFLINE")

            if status == "ONLINE":
                st.success(f"🟢 {device_id}")
            else:
                st.error(f"🔴 {device_id}")

            st.caption(
                f"{device_type} • {zone}"
            )

            if device.get("ip"):
                st.caption(
                    f"IP: {device['ip']}"
                )

            if device.get("rssi") is not None:
                st.caption(
                    f"RSSI: {device['rssi']} dBm"
                )

            last_seen = device.get("last_seen")

            if last_seen:
                seconds = device.get(
                    "seconds_since_seen",
                    0,
                )

                if device.get("status") == "ONLINE":
                    st.caption(
                        f"Last seen: {seconds}s ago"
                    )
                else:
                    st.caption(
                        f"⚠️ Disconnected • "
                        f"last seen {seconds}s ago"
                    )
            else:
                st.caption(
                    "⚠️ Never connected"
                )


# ============================================================
# ZONE SUMMARY
# ============================================================

def render_zone_summary():

    st.subheader("⚠️ Zone Risk Summary")

    devices = get_devices_snapshot()

    zone_ids = sorted({
        device.get("zone_id")
        for device in devices.values()
        if device.get("zone_id")
    })

    if not zone_ids:
        st.info("No zones detected from MQTT.")
        return

    columns = st.columns(
        min(len(zone_ids), 4)
    )

    for index, zone_id in enumerate(zone_ids):

        score = calculate_zone_risk(zone_id)
        level = risk_level(score)

        with columns[index % len(columns)]:

            if level == "LOW":
                st.success(f"🟢 {zone_id}")
            elif level == "MEDIUM":
                st.warning(f"🟡 {zone_id}")
            else:
                st.error(f"🔴 {zone_id}")

            zone_devices = [
                device
                for device in devices.values()
                if device.get("zone_id") == zone_id
            ]

            online_count = sum(
                1
                for device in zone_devices
                if device.get("status") == "ONLINE"
            )

            st.metric(
                "Risk Score",
                score,
            )

            st.caption(
                f"Devices: {online_count}/{len(zone_devices)} connected"
            )


# ============================================================
# SENSOR DASHBOARD
# ============================================================

def render_sensor_dashboard():

    st.subheader("📊 Live Sensor Data")

    devices = get_devices_snapshot()

    sensors = [
        device
        for device in devices.values()
        if device.get("device_type") == "sensor_node"
    ]

    if not sensors:
        st.info("No sensor nodes discovered.")
        return

    for device in sensors:

        device_id = device["device_id"]
        zone = device.get("zone_id", "-")
        data = device.get("sensors", {})

        score = calculate_risk(device)
        level = risk_level(score)

        st.markdown(
            f"### 🔧 {device_id} — {zone}"
        )

        cols = st.columns(6)

        with cols[0]:
            st.metric(
                "Risk",
                score,
                level,
            )

        with cols[1]:
            value = data.get("light")
            st.metric(
                "Light",
                f"{value:.1f} lx"
                if isinstance(value, (int, float))
                else "-",
            )

        with cols[2]:
            value = data.get("distance")
            st.metric(
                "Distance",
                f"{value} mm"
                if value is not None
                else "-",
            )

        with cols[3]:
            value = data.get("moisture")
            st.metric(
                "Moisture",
                value
                if value is not None
                else "-",
            )

        with cols[4]:
            motion = data.get("motion")
            st.metric(
                "Motion",
                "YES" if motion else "NO",
            )

        with cols[5]:
            value = data.get("temperature")
            st.metric(
                "Temperature",
                f"{value:.1f} °C"
                if isinstance(value, (int, float))
                else "-",
            )

        with st.expander("MPU6050 / IMU Data"):

            imu_cols = st.columns(6)

            imu_values = [
                ("Acc X", "accX"),
                ("Acc Y", "accY"),
                ("Acc Z", "accZ"),
                ("Gyro X", "gyroX"),
                ("Gyro Y", "gyroY"),
                ("Gyro Z", "gyroZ"),
            ]

            for col, (label, key) in zip(
                imu_cols,
                imu_values,
            ):

                with col:

                    value = data.get(key)

                    st.metric(
                        label,
                        f"{value:.3f}"
                        if isinstance(value, (int, float))
                        else "-",
                    )

        buzzer = device.get("buzzer", False)

        st.write(
            "Buzzer:",
            "🔊 ON" if buzzer else "🔇 OFF",
        )

        buzzer_col1, buzzer_col2 = st.columns(2)

        with buzzer_col1:

            if st.button(
                "🔊 Activate Buzzer",
                key=f"buzzer_on_{device_id}",
            ):

                success = control_buzzer(
                    device_id,
                    True,
                )

                if success:
                    st.success(
                        "Buzzer ON command sent."
                    )
                else:
                    st.error(
                        "MQTT command failed."
                    )

        with buzzer_col2:

            if st.button(
                "🔇 Stop Buzzer",
                key=f"buzzer_off_{device_id}",
            ):

                success = control_buzzer(
                    device_id,
                    False,
                )

                if success:
                    st.success(
                        "Buzzer OFF command sent."
                    )
                else:
                    st.error(
                        "MQTT command failed."
                    )

        st.divider()


# ============================================================
# CAMERA DASHBOARD
# ============================================================

def render_camera_dashboard():

    st.subheader("📹 Live Cameras + YOLO")

    cameras = [
        device
        for device in get_devices_snapshot().values()
        if device.get("device_type") == "camera"
    ]

    if not cameras:

        st.info("No cameras discovered yet.")

        st.caption(
            "The ESP32-CAM discovery message is required."
        )

        return

    # Make sure workers exist before rendering.
    for camera in cameras:
        ensure_camera_worker(camera)

    columns = st.columns(2)

    for index, camera in enumerate(cameras):

        with columns[index % 2]:

            device_id = camera["device_id"]
            zone = camera.get("zone_id", "-")

            st.markdown(
                f"### 📷 {device_id}"
            )

            st.caption(
                f"Zone: {zone}"
            )

            if camera.get("status") == "ONLINE":
                st.success("ONLINE")
            else:
                st.error("OFFLINE")

            render_camera(camera)

            if camera.get("ip"):
                st.caption(
                    f"ESP32-CAM IP: {camera['ip']}"
                )


# ============================================================
# RISK MAP
# ============================================================

def render_risk_map():

    st.subheader("🗺️ Dynamic 3D Risk Map")

    st.caption(
        "Zones and devices are generated from MQTT discovery. "
        "No room names are hardcoded in Python."
    )

    fig = create_3d_map()

    st.plotly_chart(
        fig,
        width="stretch",
        key="eldercare_3d_map",
    )

    st.caption(
        "🟢 Low Risk   🟡 Medium Risk   🔴 High Risk   "
        "• Green/red device markers = online/offline"
    )


# ============================================================
# MQTT DEBUG
# ============================================================

def render_debug():

    with st.expander("🔧 MQTT / YOLO Debug"):

        with STATE_LOCK:

            connected = APP_STATE["mqtt_connected"]
            message_count = APP_STATE["message_count"]

            last_message = copy.deepcopy(
                APP_STATE["last_message"]
            )

            mqtt_last_change = APP_STATE[
                "mqtt_last_change"
            ]

            mqtt_last_error = APP_STATE[
                "mqtt_last_error"
            ]

            yolo_loading = APP_STATE[
                "yolo_loading"
            ]

            yolo_error = APP_STATE[
                "yolo_error"
            ]

        st.write("MQTT Host:", MQTT_HOST)
        st.write("MQTT Port:", MQTT_PORT)
        st.write(
            "Device offline timeout:",
            f"{DEVICE_OFFLINE_TIMEOUT:.0f} seconds",
        )
        st.write("Connected:", connected)
        st.write(
            "Last MQTT state change:",
            mqtt_last_change,
        )
        st.write(
            "MQTT error:",
            mqtt_last_error or "-",
        )

        st.write(
            "Messages received:",
            message_count,
        )

        st.write(
            "YOLO model:",
            YOLO_MODEL_PATH,
        )

        st.write(
            "YOLO loading:",
            yolo_loading,
        )

        st.write(
            "YOLO error:",
            yolo_error or "-",
        )

        if last_message:

            st.write("Last MQTT message:")
            st.code(last_message["topic"])

            st.json(last_message["payload"])


# ============================================================
# LIVE DASHBOARD
# ============================================================

@st.fragment(run_every="1s")
def live_dashboard():

    refresh_mqtt_connection_state()
    refresh_device_status()

    # This does not touch the hardware. It only creates/maintains
    # Python-side workers for streams already discovered through MQTT.
    sync_camera_workers()

    render_device_cards()

    st.divider()

    render_zone_summary()

    st.divider()

    render_risk_map()

    st.divider()

    render_sensor_dashboard()

    st.divider()

    render_camera_dashboard()


# ============================================================
# MAIN
# ============================================================

def main():

    start_mqtt()

    render_sidebar()

    st.title("🏠 ElderCare Monitoring System")

    st.caption(
        "IoT + Computer Vision + Multimodal "
        "Environmental Risk Assessment"
    )

    if is_mqtt_connected():
        st.success("🟢 Connected to HiveMQ")
    else:
        st.error("🔴 MQTT connection unavailable")

    live_dashboard()

    st.divider()

    render_debug()


# ============================================================
# ENTRY
# ============================================================

if __name__ == "__main__":
    main()