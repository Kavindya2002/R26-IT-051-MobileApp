"""
app/component2/api/router.py

Reads directly from app.component2.mqtt_service's in-memory state,
which lives in the SAME process as this API (fixed from the
original cross-process design).
"""

from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel

from app.component2.camera_service import camera_manager, yolo_status
from app.component2.mqtt_service import (
    component2_mqtt_service,
    get_devices_snapshot,
    is_mqtt_connected,
)

router = APIRouter(prefix="/component2", tags=["Component 2"])


def _serialize(device: Dict[str, Any]) -> Dict[str, Any]:
    sensors = device.get("sensors", {})
    return {
        "device_id": device.get("device_id"),
        "location": device.get("zone_id"),
        "zone": device.get("zone_id"),
        "device_status": device.get("status"),
        "temperature": sensors.get("temperature"),
        "light": sensors.get("light"),
        "moisture": sensors.get("moisture"),
        "motion": sensors.get("motion"),
        "distance": sensors.get("distance"),
        "buzzer": device.get("buzzer"),
        "risk_score": device.get("risk_score"),
        "risk_level": device.get("risk_level"),
        "updated_time": device.get("last_seen"),
    }


def _serialize_camera(device: Dict[str, Any]) -> Dict[str, Any]:
    snapshot = camera_manager.get_snapshot(device["device_id"]) or {}
    return {
        "device_id": device.get("device_id"),
        "zone": device.get("zone_id"),
        "device_status": device.get("status"),
        "ip": device.get("ip"),
        "fps": snapshot.get("fps", 0),
        "detections": snapshot.get("detections", 0),
        "last_frame_time": snapshot.get("frame_time"),
        "stream_error": snapshot.get("error"),
        "snapshot_url": f"/component2/cameras/{device.get('device_id')}/snapshot",
    }


def _latest_sensor_device() -> Optional[Dict[str, Any]]:
    devices = get_devices_snapshot()
    sensor_devices = [d for d in devices.values() if d.get("device_type") == "sensor_node"]
    if not sensor_devices:
        return None
    sensor_devices.sort(key=lambda d: str(d.get("last_seen") or ""), reverse=True)
    return sensor_devices[0]


@router.get("/latest")
def component2_latest():
    device = _latest_sensor_device()
    if device is None:
        return {"success": True, "result": None}
    return {"success": True, "result": _serialize(device)}


@router.get("/devices")
def component2_devices():
    devices = get_devices_snapshot()
    results = [_serialize(d) for d in devices.values() if d.get("device_type") == "sensor_node"]
    return {"success": True, "count": len(results), "results": results}


@router.get("/cameras")
def component2_cameras():
    """Lists discovered ESP32-CAM devices with live stream stats.
    Each camera's actual frame is served separately by /cameras/{id}/snapshot
    so this listing stays lightweight (Flutter polls this for the list,
    and polls/embeds the snapshot URL per camera it wants to show)."""
    devices = get_devices_snapshot()
    results = [_serialize_camera(d) for d in devices.values() if d.get("device_type") == "camera"]
    return {"success": True, "count": len(results), "results": results, "yolo": yolo_status()}


@router.get("/cameras/{device_id}/snapshot")
def component2_camera_snapshot(device_id: str):
    """Returns the latest YOLO-annotated JPEG frame for one camera.
    Flutter can poll this on a timer (e.g. every 500ms-1s) using
    Image.network() with a cache-busting query param, or embed it as
    a MJPEG-like refresh loop."""
    snapshot = camera_manager.get_snapshot(device_id)
    if snapshot is None:
        raise HTTPException(status_code=404, detail=f"Camera '{device_id}' not found or not streaming yet.")
    if snapshot.get("jpeg") is None:
        raise HTTPException(status_code=503, detail=snapshot.get("error") or "No frame available yet.")
    return Response(content=snapshot["jpeg"], media_type="image/jpeg")


class BuzzerCommand(BaseModel):
    on: bool


@router.post("/devices/{device_id}/buzzer")
def component2_set_buzzer(device_id: str, command: BuzzerCommand):
    """Publishes a buzzer on/off command to the device over MQTT.
    The device's own local state (device['buzzer']) updates once the
    ESP32 reports back its new status — this endpoint only confirms
    the command was published, not that the buzzer physically changed."""
    ok = component2_mqtt_service.publish_buzzer_command(device_id, command.on)
    if not ok:
        raise HTTPException(status_code=503, detail="Could not publish buzzer command (MQTT unavailable).")
    return {"success": True, "device_id": device_id, "buzzer_requested": command.on}


@router.get("/health")
def component2_health():
    return {
        "status": "healthy",
        "component": "Component 2",
        "mqtt_connected": is_mqtt_connected(),
        "yolo": yolo_status(),
    }
