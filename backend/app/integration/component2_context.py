"""
app/integration/component2_context.py

Tracks the most recent location/time context from Component 2, so
Component 4's pipeline can fill these in automatically when a fall
is detected, instead of requiring a caller to supply them manually.

Since Component 2 now lives in the same FastAPI process (see
app/component2/mqtt_service.py), this can read that state directly
— no cross-process import needed.
"""

from typing import Optional

from app.component2.mqtt_service import get_devices_snapshot


class Component2ContextStore:
    def get_context(self) -> dict:
        devices = get_devices_snapshot()
        sensor_devices = [d for d in devices.values() if d.get("device_type") == "sensor_node"]

        if not sensor_devices:
            return {"location": None, "time": None}

        sensor_devices.sort(key=lambda d: str(d.get("last_seen") or ""), reverse=True)
        latest = sensor_devices[0]

        return {
            "location": latest.get("zone_id"),
            "time": latest.get("last_seen"),
        }


component2_context = Component2ContextStore()
