"""
app/integration/mqtt/subscriber.py — Component 1's MQTT ingestion.

FIX FOR THE ORIGINAL PROJECT: this subscriber existed and worked
correctly in isolation, but was never started by the combined
FastAPI backend's main.py — grep for "subscriber" in the original
main.py returned zero matches. It is now started from app/main.py's
lifespan via component2_mqtt_service-style loop_start(), so it
actually runs whenever the backend runs.

FIX (this pass — Paho MQTT v2 callback signature): the installed
paho-mqtt version is 2.1.0 (see requirements.txt), which uses
CallbackAPIVersion.VERSION2. Under v2, on_disconnect is called with
SIX positional arguments: (client, userdata, disconnect_flags,
reason_code, properties=None) — i.e. the same shape as on_connect's
(client, userdata, flags, rc, properties=None), just for the
disconnect event. _on_disconnect below was still written with the
OLDER 5-argument shape (missing the disconnect_flags parameter),
which raised a real exception on every disconnect:

    TypeError: Component1MqttSubscriber._on_disconnect() takes from
    4 to 5 positional arguments but 6 were given

(confirmed directly from a real backend server log). _on_connect was
already correct — only _on_disconnect needed the extra parameter.

FIX (this pass — broader MQTT reliability, not just the signature):
- `reconnect_delay_set()` makes Paho's built-in automatic-reconnect
  backoff EXPLICIT and bounded (1s, doubling, capped at 30s) instead
  of relying silently on whatever the library's own default happens
  to be. `loop_start()` already retries on an unexpected disconnect
  without any code here needing to call connect() again — this just
  makes that behavior visible/intentional rather than implicit.
- `_on_connect` already re-subscribes on every successful connect
  (including a reconnect), so no separate "resubscribe after
  reconnect" logic is needed — confirmed correct, left unchanged.
- `start()` now guards `self.client.connect(...)` itself: a DNS/
  network failure at the FIRST connect attempt (e.g. HiveMQ briefly
  unreachable at backend startup) is logged instead of raising out of
  `start()` and potentially taking the whole FastAPI startup down with
  it. `_started` stays False in that case so a later explicit retry
  (e.g. the next deploy) can still succeed; Paho's own automatic
  reconnect only applies AFTER a first successful connect, so this
  specific case needed its own guard.
- `stop()` now also clears `self.client` and re-raises nothing, and
  `start()` can run again afterwards (building a fresh client) without
  ever having two clients/subscriptions live at once, since the old
  one is always fully disconnected and discarded first.
- No credentials (password, broker auth) are ever logged — only the
  topic name and connection/disconnection state.
"""

import json
import ssl
import threading
from typing import Optional

import paho.mqtt.client as mqtt

from app.core.config import (
    COMPONENT1_HIVEMQ_BROKER,
    COMPONENT1_HIVEMQ_PASSWORD,
    COMPONENT1_HIVEMQ_PORT,
    COMPONENT1_HIVEMQ_USERNAME,
    COMPONENT1_TOPIC,
    MQTT_KEEPALIVE,
)
from app.integration.mqtt.message_router import mqtt_message_router
from app.integration.mqtt.sensor_parser import parse_sensor_payload


class Component1MqttSubscriber:
    def __init__(self) -> None:
        self.client: Optional[mqtt.Client] = None
        self._started = False
        self.connected = False

    def _on_connect(self, client, userdata, flags, rc, properties=None):
        self.connected = rc == 0
        if rc == 0:
            print(f"[Component 1] Connected to HiveMQ. Subscribing: {COMPONENT1_TOPIC}")
            client.subscribe(COMPONENT1_TOPIC, qos=0)
        else:
            print(f"[Component 1] MQTT connect failed, rc={rc}")

    # FIX: added the missing `disconnect_flags` positional parameter
    # (renamed `rc` to `reason_code` to match Paho v2's own naming,
    # behavior is unchanged — this field was only ever used to flip
    # `self.connected` to False, never branched on). This is the exact
    # signature Paho v2 calls on_disconnect with; see module docstring.
    def _on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties=None):
        self.connected = False
        if reason_code != 0:
            print(f"[Component 1] Unexpected MQTT disconnect, reason_code={reason_code}")

    def _on_message(self, client, userdata, msg):
        try:
            sensor_data = parse_sensor_payload(msg.payload)
        except ValueError as exc:
            print(f"[Component 1] Invalid sensor payload: {exc}")
            return

        try:
            result = mqtt_message_router.process(sensor_data)
        except Exception as exc:
            print(f"[Component 1] Prediction pipeline failed: {exc}")
            return

        print(f"[Component 1] {json.dumps(result['prediction'], indent=2)}")

    def start(self) -> None:
        if self._started:
            return

        # Load/train models once, up front, so the first MQTT
        # message doesn't pay the training cost.
        from app.integration.component1_runtime import component1_runtime
        component1_runtime.load()

        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="eldercare-component1")
        client.username_pw_set(COMPONENT1_HIVEMQ_USERNAME, COMPONENT1_HIVEMQ_PASSWORD)
        client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.on_message = self._on_message
        # Explicit, bounded backoff for Paho's own automatic reconnect
        # (used for any disconnect AFTER the first successful connect
        # below) — 1s initial delay, doubling up to a 30s cap, rather
        # than relying silently on the library's own default.
        client.reconnect_delay_set(min_delay=1, max_delay=30)

        try:
            client.connect(COMPONENT1_HIVEMQ_BROKER, COMPONENT1_HIVEMQ_PORT, keepalive=MQTT_KEEPALIVE)
        except Exception as exc:
            # Don't let a transient network/DNS failure at startup take
            # the whole FastAPI app down with it. _started stays False,
            # self.client stays None, so a later explicit start() call
            # (e.g. after a redeploy) gets a clean retry.
            print(f"[Component 1] MQTT initial connect failed, will not retry automatically: {exc}")
            return

        self.client = client
        self.client.loop_start()
        self._started = True
        print("[Component 1] MQTT subscriber started.")

    def stop(self) -> None:
        if self.client is not None:
            try:
                self.client.loop_stop()
                self.client.disconnect()
            except Exception:
                pass
        self.client = None
        self._started = False
        print("[Component 1] MQTT subscriber stopped.")


component1_subscriber = Component1MqttSubscriber()
