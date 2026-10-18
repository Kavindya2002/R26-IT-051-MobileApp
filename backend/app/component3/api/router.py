"""
app/component3/api/router.py

ONE router for Component 3. The original project had three
overlapping files (prediction.py, result.py, status.py) — status.py
in particular always returned hardcoded zeros regardless of real
state, which silently violated the "never fabricate data" rule
followed correctly elsewhere. That's gone; there's one /latest
endpoint that reflects what the MQTT pipeline actually measured.
"""

from fastapi import APIRouter

from app.component3.mqtt_service import get_latest_component3_result, is_mqtt_connected

router = APIRouter(prefix="/component3", tags=["Component 3"])


@router.get("/latest")
def component3_latest():
    result = get_latest_component3_result()
    return {
        "success": True,
        "result": {
            "health_status": result.get("health_status"),
            "heart_rate": result.get("heart_rate"),
            "pulse_interval": result.get("pulse_interval"),
            "systolic_bp": result.get("systolic_bp"),
            "diastolic_bp": result.get("diastolic_bp"),
            "finger_detected": result.get("finger_detected"),
            "timestamp": result.get("timestamp"),
        },
    }


@router.get("/health")
def component3_health():
    return {"status": "healthy", "component": "Component 3", "mqtt_connected": is_mqtt_connected()}
