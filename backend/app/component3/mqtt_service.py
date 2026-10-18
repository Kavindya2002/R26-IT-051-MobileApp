"""
app/component3/mqtt_service.py — Component 3 PPG/BP monitoring.

Same fix as Component 2: this MQTT subscriber runs INSIDE the
FastAPI process (started from app.main's lifespan). The original
project had a standalone websocket-based main.py AND a separate,
never-started MQTT implementation; this is now the single,
actually-running path, and the API router reads its state directly.

FIX (root cause of "Component 3 never gives sensor values" — confirmed
by comparing this file against app/core/config.py): config.py defines
Component 3 with its OWN dedicated HiveMQ Cloud cluster
(COMPONENT3_HIVEMQ_BROKER/PORT/USERNAME/PASSWORD), separate from the
shared broker Component 2 uses (HIVEMQ_BROKER/PORT/USERNAME/PASSWORD).
This file had been importing and connecting with the SHARED
HIVEMQ_* constants instead of the COMPONENT3_HIVEMQ_* ones, so the
Component 3 MQTT subscriber was connecting to the wrong broker
entirely. Any device/simulator publishing PPG samples to Component
3's real cluster was never seen by this subscriber — it was listening
on a different cluster — which is why /component3/latest always
stayed at the default "Waiting" / finger_detected=false state. Fixed
by switching every reference below back to the COMPONENT3_HIVEMQ_*
constants, matching what config.py already defines and what the
original (now-commented) version of this file above used correctly.
"""

import json
import ssl
import threading
from pathlib import Path
from typing import Any, Dict, Optional

from app.core.config import DEFAULT_ELDER_ID
from app.events.schemas import EventRecord
from app.events.service import EventService

# Tracks the last-seen health_status so an event is logged only on
# the transition INTO Risky/Critical, not on every single sample —
# same "log transitions, not every reading" rule as Component 2.
_last_health_status: Optional[str] = None


def _log_vitals_event(status: str, heart_rate: float, systolic_bp: float) -> None:
    if not DEFAULT_ELDER_ID:
        return
    EventService.create(EventRecord(
        elder_id=DEFAULT_ELDER_ID,
        source="component3",
        event_type="vitals_risk",
        severity=status,
        location=None,
        details=f"Vitals status reached {status} (heart rate {heart_rate:.0f} bpm, systolic {systolic_bp:.0f} mmHg).",
    ))

import paho.mqtt.client as mqtt

from app.component3.ml.ppg_processor import PPGProcessor
from app.core.config import (
    COMPONENT3_HIVEMQ_BROKER,
    COMPONENT3_HIVEMQ_PASSWORD,
    COMPONENT3_HIVEMQ_PORT,
    COMPONENT3_HIVEMQ_USERNAME,
    COMPONENT3_TOPIC,
    MQTT_KEEPALIVE,
)

MODEL_PATH = Path(__file__).resolve().parent / "models" / "bp_model.joblib"

_LOCK = threading.RLock()
_processor = PPGProcessor(str(MODEL_PATH))
_mqtt_connected = False


def get_latest_component3_result() -> Dict[str, Any]:
    with _LOCK:
        return _processor.get_latest_result()


def is_mqtt_connected() -> bool:
    with _LOCK:
        return _mqtt_connected


class Component3MqttService:
    def __init__(self) -> None:
        self.client: Optional[mqtt.Client] = None
        self._started = False

    def _on_connect(self, client, userdata, flags, rc, properties=None):
        global _mqtt_connected
        with _LOCK:
            _mqtt_connected = rc == 0
        if rc == 0:
            print(f"[Component 3] Connected to HiveMQ. Subscribing: {COMPONENT3_TOPIC}")
            client.subscribe(COMPONENT3_TOPIC, qos=0)
        else:
            print(f"[Component 3] MQTT connect failed, rc={rc}")

    def _on_disconnect(self, client, userdata, rc, properties=None):
        global _mqtt_connected
        with _LOCK:
            _mqtt_connected = False

    def _on_message(self, client, userdata, msg):
        try:
            payload = json.loads(msg.payload.decode("utf-8"))
        except json.JSONDecodeError:
            print(f"[Component 3] Invalid JSON on {msg.topic}")
            return

        if not all(k in payload for k in ("timestamp", "red", "ir")):
            print("[Component 3] Payload missing required fields: timestamp, red, ir")
            return

        global _last_health_status
        with _LOCK:
            result = _processor.process_sample(
                timestamp=payload["timestamp"],
                red=payload["red"],
                ir=payload["ir"],
            )
            status = result.get("health_status")
            if status in ("Risky", "Critical") and status != _last_health_status:
                _log_vitals_event(
                    status,
                    heart_rate=result.get("heart_rate", 0.0),
                    systolic_bp=result.get("systolic_bp", 0.0),
                )
            _last_health_status = status

    def start(self) -> None:
        if self._started:
            return

        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="eldercare-component3")
        self.client.username_pw_set(COMPONENT3_HIVEMQ_USERNAME, COMPONENT3_HIVEMQ_PASSWORD)
        self.client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message

        self.client.connect(COMPONENT3_HIVEMQ_BROKER, COMPONENT3_HIVEMQ_PORT, keepalive=MQTT_KEEPALIVE)
        self.client.loop_start()
        self._started = True
        print("[Component 3] MQTT service started.")

    def stop(self) -> None:
        if self.client is not None:
            try:
                self.client.loop_stop()
                self.client.disconnect()
            except Exception:
                pass
        self._started = False
        print("[Component 3] MQTT service stopped.")


component3_mqtt_service = Component3MqttService()