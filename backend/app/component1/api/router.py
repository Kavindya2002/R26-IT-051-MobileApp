"""
app/component1/api/router.py — Component 1 REST API.

ONE router. ONE in-memory "latest result" store. No duplicate
result.py/prediction.py files that may or may not be wired up —
that ambiguity was a real bug in the original project.

store_prediction() is called by the MQTT pipeline
(app/integration/mqtt/message_router.py) every time a real
prediction is produced, so /component1/latest reflects reality.
"""

from typing import Optional

from fastapi import APIRouter

router = APIRouter(prefix="/component1", tags=["Component 1"])

_latest_prediction: Optional[dict] = None


def store_prediction(prediction: dict) -> None:
    """Called by the MQTT pipeline after every real inference."""
    global _latest_prediction
    _latest_prediction = {
        "fall_detected": prediction.get("fall_detected"),
        "fall_type": prediction.get("fall_type"),
        "risk_level": prediction.get("risk_level"),
        "movement": prediction.get("movement", prediction.get("activity")),
        # FIX (Fall Detection screen, Flutter-side limitation closed):
        # this whitelist was the second place (after the adapter) that
        # silently dropped the real `stability` value Component 1
        # already computes — without it here too, /component1/latest
        # would never expose it no matter what the adapter returns.
        "stability": prediction.get("stability"),
        "confidence": prediction.get("confidence"),
        "explanation": prediction.get("explanation"),
        # FIX: this whitelist was silently dropping
        # Component1Adapter's new real per-sample `sample_time` —
        # without it here, /component1/latest would never expose it
        # to the Flutter app no matter what the adapter returns.
        "sample_time": prediction.get("sample_time"),
    }


@router.get("/latest")
def get_latest_prediction():
    if _latest_prediction is None:
        # No fabricated data — matches the good instinct already
        # present in the original Component 2 API.
        return {"success": True, "component": "Component 1", "result": None}

    return {"success": True, "component": "Component 1", "result": _latest_prediction}


@router.get("/health")
def component1_health():
    return {"status": "healthy", "component": "Component 1"}
