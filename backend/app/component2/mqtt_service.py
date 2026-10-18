"""
app/component2/mqtt_service.py — Component 2 environmental monitoring.

FIX FOR THE ORIGINAL PROJECT'S BIGGEST BUG:
The old design ran this MQTT client inside a separate Streamlit
process, while the FastAPI backend tried to import its state —
which can never work across two OS processes. Here, the MQTT
client lives INSIDE the FastAPI app itself (started in main.py's
lifespan, via client.loop_start() which runs its own background
thread). Any code in this same process — including the API router
and an optional dashboard — reads the SAME in-memory state.

If you want a separate visualization process later, have it call
the FastAPI HTTP endpoints instead of touching MQTT/state directly
(see app/component2/dashboard.py for exactly that pattern).

FIX (duplicate-event prevention — restart-safety backstop, same bug
class already fixed for alerts via AlertService.find_recent_open_episode(),
see app/integration/mqtt/message_router.py): the transition-based
check below (`new_level != previous_level`) only looks at THIS
PROCESS's in-memory risk_level — which resets to nothing on every
backend restart. If the physical environment is still genuinely HIGH
right after a restart, the next telemetry sample looks like a "new"
transition even though the real-world condition never actually
changed, producing a duplicate event row. _log_environment_event()
now checks the DATABASE itself (via EventService.find_recent_duplicate())
for a very recent matching event before inserting another one — see
that method's docstring in app/events/service.py for the full
reasoning and its documented trade-off.

FIX (this pass — stale "ONLINE" status, real bug found during manual
Swagger/Flutter testing): DEVICE_OFFLINE_TIMEOUT was imported from
config but never actually used anywhere in this file. A device's
status was only ever set to "ONLINE" (on discovery/telemetry) or
"OFFLINE" (only if the device itself explicitly published a status
message saying so) — a device that is powered off or loses network
abruptly can never publish that explicit "offline" message, so its
last known status (ONLINE) stayed stuck forever, with nothing to time
it out. No MQTT Last-Will-and-Testament was configured either (which
would have let the broker announce the disconnect on the device's
behalf). _apply_offline_timeout() below now recomputes "is this device
actually still online" at READ time (every get_devices_snapshot()
call) from the real last_seen timestamp vs. DEVICE_OFFLINE_TIMEOUT —
no background task needed, and it only ever demotes a stale "ONLINE"
to "OFFLINE" (never fabricates a status the device never reported).
"""

import copy
import json
import ssl
import threading
from datetime import datetime
from typing import Any, Dict, Optional

import paho.mqtt.client as mqtt

from app.core.config import (
    COMPONENT2_TOPIC,
    DEVICE_OFFLINE_TIMEOUT,
    HIVEMQ_BROKER,
    HIVEMQ_PASSWORD,
    HIVEMQ_PORT,
    HIVEMQ_USERNAME,
    MQTT_KEEPALIVE,
    DEFAULT_ELDER_ID,
)
from app.events.schemas import EventRecord
from app.events.service import EventService

_STATE_LOCK = threading.RLock()


class Component2State:
    """In-memory device/zone state, shared by the API router."""

    def __init__(self) -> None:
        self.devices: Dict[str, Dict[str, Any]] = {}
        self.zones: Dict[str, Dict[str, Any]] = {}
        self.mqtt_connected = False


_state = Component2State()


def _log_environment_event(device: dict, risk_level: str) -> None:
    if not DEFAULT_ELDER_ID:
        return
    location = device.get("zone_id") or device.get("device_id") or "unknown zone"

    # FIX (duplicate-event prevention, restart-safety backstop): check
    # the database itself for a very recent event matching this
    # elder/location/severity before inserting — not just this
    # process's in-memory risk_level state, which resets on every
    # backend restart. See app/events/service.py's
    # find_recent_duplicate() docstring for the full reasoning.
    existing = EventService.find_recent_duplicate(
        elder_id=DEFAULT_ELDER_ID,
        source="component2",
        location=location,
        severity=risk_level,
    )
    if existing:
        print(
            f"[Component 2] Recent matching event already exists for {location} "
            f"({risk_level}) — skipping duplicate (likely a backend restart, not a "
            f"genuinely new occurrence)."
        )
        return

    EventService.create(EventRecord(
        elder_id=DEFAULT_ELDER_ID,
        source="component2",
        event_type="environment_risk",
        severity=risk_level,
        location=location,
        details=f"Environmental risk in {location} reached {risk_level}.",
    ))


# ============================================================
# RISK CALCULATION (now actually persisted, unlike the original)
# ============================================================

def calculate_risk(sensors: Dict[str, Any]) -> int:
    risk = 0

    light = sensors.get("light")
    if light is not None:
        if light < 30:
            risk += 25
        elif light < 100:
            risk += 10

    distance = sensors.get("distance")
    if distance is not None:
        if distance < 300:
            risk += 35
        elif distance < 600:
            risk += 20
        elif distance < 1000:
            risk += 5

    moisture = sensors.get("moisture")
    if moisture is not None:
        if moisture > 3000:
            risk += 30
        elif moisture > 2000:
            risk += 20
        elif moisture > 1000:
            risk += 10

    temperature = sensors.get("temperature")
    if temperature is not None:
        if temperature >= 45 or temperature <= 5:
            risk += 30
        elif temperature >= 35 or temperature <= 12:
            risk += 15

    if sensors.get("motion"):
        risk += 5

    return min(risk, 100)


def risk_level_from_score(score: int) -> str:
    if score < 31:
        return "LOW"
    if score < 61:
        return "MEDIUM"
    return "HIGH"


# ============================================================
# DEVICE HELPERS
# ============================================================

def _create_device(device_id: str, device_type: str = "unknown") -> Dict[str, Any]:
    return {
        "device_id": device_id,
        "device_type": device_type,
        "zone_id": None,
        "ip": None,
        "status": "OFFLINE",
        "last_seen": None,
        "sensors": {},
        "buzzer": False,
        "stream_url": None,
        "risk_score": 0,
        "risk_level": "LOW",
    }


def _get_device(device_id: str, device_type: str = "unknown") -> Dict[str, Any]:
    with _STATE_LOCK:
        if device_id not in _state.devices:
            _state.devices[device_id] = _create_device(device_id, device_type)
        device = _state.devices[device_id]
        if device["device_type"] == "unknown" and device_type != "unknown":
            device["device_type"] = device_type
        return device


def _apply_offline_timeout(device: Dict[str, Any]) -> Dict[str, Any]:
    """Recomputes whether a device claiming "ONLINE" is actually stale,
    using its real last_seen timestamp — see the FIX note in this
    module's docstring. Only ever demotes ONLINE -> OFFLINE; never
    touches a device that is already OFFLINE, and never fabricates
    last_seen if it's missing (a device with no last_seen at all has
    never sent anything, so there's nothing to time out — it keeps
    whatever status _create_device() gave it)."""
    if device.get("status") != "ONLINE":
        return device

    last_seen = device.get("last_seen")
    if not last_seen:
        return device

    try:
        last_seen_dt = datetime.fromisoformat(last_seen)
    except (TypeError, ValueError):
        # Unparseable timestamp — don't guess, leave status as-is.
        return device

    elapsed_seconds = (datetime.now() - last_seen_dt).total_seconds()
    if elapsed_seconds > DEVICE_OFFLINE_TIMEOUT:
        device["status"] = "OFFLINE"

    return device


def get_devices_snapshot() -> Dict[str, Dict[str, Any]]:
    with _STATE_LOCK:
        snapshot = copy.deepcopy(_state.devices)
    for device in snapshot.values():
        _apply_offline_timeout(device)
    return snapshot


def is_mqtt_connected() -> bool:
    with _STATE_LOCK:
        return _state.mqtt_connected


# ============================================================
# MQTT MESSAGE HANDLERS
# ============================================================
#
# Expected topic shape: eldercare/component2/<device_id>/<kind>
# where <kind> is one of: discovery, status, telemetry

def _handle_discovery(payload: Dict[str, Any]) -> None:
    device_id = payload.get("device_id")
    if not device_id:
        return
    device_type = payload.get("device_type", "unknown")
    with _STATE_LOCK:
        device = _get_device(device_id, device_type)
        device["device_type"] = device_type
        device["zone_id"] = payload.get("zone_id", device.get("zone_id"))
        device["ip"] = payload.get("ip", device.get("ip"))
        if device_type == "camera":
            device["stream_url"] = payload.get("stream_url", device.get("stream_url"))
        device["status"] = "ONLINE"
        device["last_seen"] = datetime.now().isoformat()


def _handle_status(payload: Dict[str, Any]) -> None:
    device_id = payload.get("device_id")
    if not device_id:
        return
    with _STATE_LOCK:
        device = _get_device(device_id)
        status = str(payload.get("status", "online")).lower()
        device["status"] = "ONLINE" if status == "online" else "OFFLINE"
        if "buzzer" in payload:
            device["buzzer"] = payload["buzzer"]
        device["last_seen"] = datetime.now().isoformat()


def _handle_telemetry(payload: Dict[str, Any]) -> None:
    print(f"[DEBUG] RAW telemetry payload: {payload}")
    device_id = payload.get("device_id")
    if not device_id:
        return

    with _STATE_LOCK:
        device = _get_device(device_id, "sensor_node")
        device["device_type"] = "sensor_node"
        device["zone_id"] = payload.get("zone_id", device.get("zone_id"))

        sensors = {
            "temperature": payload.get("temperature"),
            "light": payload.get("light"),
            "moisture": payload.get("moisture"),
            "motion": payload.get("motion"),
            "distance": payload.get("distance"),
        }
        device["sensors"] = sensors

        # THE FIX: risk is calculated AND stored on the device,
        # so the API can actually return it later.
        score = calculate_risk(sensors)
        previous_level = device.get("risk_level")
        device["risk_score"] = score
        device["risk_level"] = risk_level_from_score(score)

        device["status"] = "ONLINE"
        device["last_seen"] = datetime.now().isoformat()

        # Logs a real event the moment this zone's risk enters
        # HIGH/CRITICAL (not on every single reading — only on the
        # transition into a risk state, so a steady HIGH zone doesn't
        # flood the events table). Uses DEFAULT_ELDER_ID, the same
        # single-elder-deployment assumption already used by
        # app/integration/mqtt/message_router.py, since this handler
        # has no other way to know which elder this zone belongs to.
        # _log_environment_event() itself now also checks the database
        # for a recent duplicate before inserting (see its docstring) —
        # this transition check and that DB check are complementary,
        # not redundant: this one filters out same-process repeat
        # readings cheaply; the DB check catches the restart case this
        # one cannot see.
        new_level = device["risk_level"]
        if new_level in ("HIGH", "CRITICAL") and new_level != previous_level:
            _log_environment_event(device, new_level)


_TOPIC_HANDLERS = {
    "discovery": _handle_discovery,
    "status": _handle_status,
    "telemetry": _handle_telemetry,
}


def _dispatch(topic: str, payload: Dict[str, Any]) -> None:
    kind = topic.rstrip("/").split("/")[-1]
    handler = _TOPIC_HANDLERS.get(kind)
    if handler:
        handler(payload)


# ============================================================
# MQTT CLIENT LIFECYCLE
# ============================================================

class Component2MqttService:
    def __init__(self) -> None:
        self.client: Optional[mqtt.Client] = None
        self._started = False

    def _on_connect(self, client, userdata, flags, rc, properties=None):
        with _STATE_LOCK:
            _state.mqtt_connected = rc == 0
        if rc == 0:
            print(f"[Component 2] Connected to HiveMQ. Subscribing: {COMPONENT2_TOPIC}")
            client.subscribe(COMPONENT2_TOPIC, qos=0)
        else:
            print(f"[Component 2] MQTT connect failed, rc={rc}")

    def _on_disconnect(self, client, userdata, rc, properties=None):
        with _STATE_LOCK:
            _state.mqtt_connected = False
        print("[Component 2] MQTT disconnected.")

    def _on_message(self, client, userdata, msg):
        try:
            payload = json.loads(msg.payload.decode("utf-8"))
        except json.JSONDecodeError:
            print(f"[Component 2] Invalid JSON on {msg.topic}")
            return
        _dispatch(msg.topic, payload)

    def start(self) -> None:
        if self._started:
            return

        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="eldercare-component2")
        self.client.username_pw_set(HIVEMQ_USERNAME, HIVEMQ_PASSWORD)
        self.client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message

        self.client.connect(HIVEMQ_BROKER, HIVEMQ_PORT, keepalive=MQTT_KEEPALIVE)
        self.client.loop_start()  # background network thread, same process
        self._started = True
        print("[Component 2] MQTT service started.")

    def publish_buzzer_command(self, device_id: str, on: bool) -> bool:
        """Publishes a buzzer on/off command to the device's command topic.
        Ported from the original Streamlit dashboard's control_buzzer()
        function — the ESP32 firmware is expected to subscribe to
        eldercare/component2/<device_id>/command and act on {"buzzer": bool}.
        """
        if self.client is None or not self._started:
            print("[Component 2] Cannot publish buzzer command: MQTT client not started.")
            return False
        try:
            topic = f"eldercare/component2/{device_id}/command"
            payload = json.dumps({"buzzer": on})
            result = self.client.publish(topic, payload, qos=1)
            return result.rc == mqtt.MQTT_ERR_SUCCESS
        except Exception as exc:
            print(f"[Component 2] Buzzer publish failed: {exc}")
            return False

    def stop(self) -> None:
        if self.client is not None:
            try:
                self.client.loop_stop()
                self.client.disconnect()
            except Exception:
                pass
        self._started = False
        print("[Component 2] MQTT service stopped.")


component2_mqtt_service = Component2MqttService()