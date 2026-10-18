"""
app/integration/router.py

Manual Component 1 -> Component 4 trigger, useful for testing
without real hardware, or for a viva demo where you want to punch
in a scenario by hand. The MQTT pipeline (message_router.py) now
also triggers this automatically for real sensor events — this
endpoint is for manual/demo use, not a replacement for that.

FIX (duplicate-alert guard for this manual/demo endpoint): unlike
the MQTT path (app/integration/mqtt/message_router.py), this
endpoint has no persistent per-elder in-memory episode state — each
HTTP call is a one-shot manual trigger. Previously, calling it
repeatedly in rapid succession for the same elder (e.g. clicking
"Execute" more than once in Swagger UI, or a double-submit) created
one new alert row per call with zero protection.

This fix reuses the EXACT SAME backstop check message_router.py
already relies on for MQTT restart-safety
(AlertService.find_recent_open_episode) — no new dedup mechanism is
introduced, and Component 1-4 themselves are untouched. If a recent
alert (within EPISODE_RECOVERY_WINDOW_SECONDS, same fall_type) for
this elder already exists, this call is treated as a duplicate of
that one: no new alert is persisted, and the existing alert's info
is returned instead (with "duplicate_of_recent_alert": true) so the
caller still gets a real, useful response rather than an error.

KNOWN LIMITATION (shared with the MQTT backstop, same as documented
in app/alerts/service.py): this is a narrow, time-window heuristic,
not a perfect per-event identity. Two genuinely distinct manual
triggers of the identical fall_type for the same elder within the
window would also be treated as one. Given this endpoint is for
manual/demo use (not real hardware), this trade-off is acceptable.
"""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.alerts.service import AlertService
from app.integration.pipeline import elder_care_pipeline


router = APIRouter(prefix="/integration", tags=["Integration"])


class Component1Prediction(BaseModel):
    fall_detected: bool
    fall_type: str
    risk_level: str
    movement: str
    confidence: float = 0.0


class Component2Context(BaseModel):
    location: str
    time: str


class UserInformation(BaseModel):
    age: int
    previous_falls: int
    assistive_device: str


class Component1ToComponent4Request(BaseModel):
    component1: Component1Prediction
    component2: Component2Context
    user: UserInformation
    elder_id: str | None = None


@router.post("/component1-to-component4")
def component1_to_component4(request: Component1ToComponent4Request):
    try:
        component1_payload = request.component1.model_dump()

        # FIX: see module docstring. Only applies when there is an
        # elder_id to check against and the sample actually reports a
        # fall — a "No Fall" / status-check call never needs this
        # guard, and with no elder_id there is nothing to look up.
        if request.elder_id and component1_payload.get("fall_detected"):
            existing = AlertService.find_recent_open_episode(
                elder_id=request.elder_id,
                fall_type=component1_payload.get("fall_type", "fall"),
            )
            if existing:
                return {
                    "status": "success",
                    "integration": "Component 1 -> Component 4",
                    "component1": component1_payload,
                    "component4": {
                        "alert": existing.get("alert_type"),
                        "confidence": existing.get("confidence"),
                    },
                    "alert_id": existing.get("id"),
                    "duplicate_of_recent_alert": True,
                }

        return elder_care_pipeline.predict(
            component1_result=component1_payload,
            component2=request.component2.model_dump(),
            user=request.user.model_dump(),
            elder_id=request.elder_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail={"status": "error", "message": str(exc)})
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail={"status": "error", "message": "Integration failed.", "error": str(exc)},
        )


@router.get("/health")
def integration_health():
    return {
        "status": "healthy",
        "flow": "Component 1 -> Component 4 (automatic via MQTT, manual via this endpoint)",
    }