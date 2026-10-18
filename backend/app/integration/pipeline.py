"""
app/integration/pipeline.py

Connects Component 1's prediction to Component 4's alert decision.

FIX FOR THE ORIGINAL PROJECT: this pipeline used to only be
reachable through a manual HTTP call (POST /integration/...).
The MQTT message router (app/integration/mqtt/message_router.py)
now calls elder_care_pipeline.predict() automatically whenever
Component 1 detects a fall, so a real sensor event produces a real
Voice/Caregiver/Emergency Alert without a human in the loop.

SECOND FIX (this pass): every alert decision is now persisted via
AlertService, closing the "Component 4 is stateless" gap that
blocked the Flutter app's History screen. When elder_id is provided,
the elder's REAL age/previous_falls/assistive_device are looked up
instead of using hardcoded defaults.

THIRD FIX (this pass): AlertService.create() already returns the
full persisted row — Supabase assigns it a real primary key (`id`)
on insert, and that same row (`id` included) is what gets broadcast
over the WebSocket in app/alerts/service.py. This endpoint's own
HTTP response was silently discarding that return value, so a caller
going through the REST path (the Flutter app's own
triggerIntegration() call, not the WebSocket) had no real alert id to
deduplicate against — only the WebSocket side did. `alert_id` (and
the persisted `created_at`) are now included in the response so both
delivery paths carry the SAME real identifier for the same alert.
`alert_id` is null when `elder_id` wasn't provided, or when the write
itself failed (AlertService.create() logs and returns None rather
than raising, so a caregiver still gets the alert even if the DB
write didn't land) — callers must treat it as optional.

FOURTH FIX (this pass — duplicate-alert prevention, restart backstop):
added an OPTIONAL `episode_id` parameter, threaded straight into the
persisted AlertRecord when given. Only message_router.py passes it
(the stable uuid4() it generates when it opens a new fall episode —
see that module's docstring); every other caller (the manual
/integration/component1-to-component4 endpoint, /escalate) omits it
and gets exactly the previous behavior (episode_id stored as None).
This lets AlertService.find_recent_open_episode() recognize, after a
restart, which alert row an in-flight episode already belongs to.
"""

from typing import Any, Dict, Optional

from app.alerts.schemas import AlertRecord
from app.alerts.service import AlertService
from app.component4.model_loader import component4_loader
from app.component4.prediction_service import PredictionService
from app.component4.schemas import Component4Request
from app.core.config import DEFAULT_LOCATION
from app.elders.service import ElderService
from app.integration.component2_context import component2_context


class ElderCarePipeline:
    def __init__(self) -> None:
        self.component4 = PredictionService(component4_loader)

    def predict(self, component1_result: Dict[str, Any],
                component2: Optional[Dict[str, Any]] = None,
                user: Optional[Dict[str, Any]] = None,
                elder_id: Optional[str] = None,
                force_alert_type: Optional[str] = None,
                episode_id: Optional[str] = None) -> Dict[str, Any]:

        required = ["fall_detected", "fall_type", "risk_level", "movement"]
        missing = [f for f in required if f not in component1_result]
        if missing:
            raise ValueError("Missing Component 1 prediction field(s): " + ", ".join(missing))

        component2 = dict(component2 or {})
        live_context = component2_context.get_context()
        component2.setdefault("location", live_context.get("location"))
        component2.setdefault("time", live_context.get("time"))
        # FIX (see conversation notes): "unknown" was never seen in
        # Component 4's training data — DEFAULT_LOCATION is a real,
        # in-distribution value instead.
        component2["location"] = component2.get("location") or DEFAULT_LOCATION
        component2["time"] = component2.get("time") or "unknown"

        # USER PROFILE:
        # If elder_id is given, look up the elder's REAL risk profile
        # instead of using hardcoded defaults — this is what makes
        # Component 4's prediction reflect the actual person, not a
        # generic stand-in.
        user = dict(user or {})
        if elder_id and not user:
            try:
                user = ElderService.get_risk_profile(elder_id)
            except Exception as exc:
                print(f"[Pipeline] Could not load elder {elder_id} risk profile, using defaults: {exc}")
        user.setdefault("age", 75)
        user.setdefault("previous_falls", 0)
        user.setdefault("assistive_device", "none")

        component4_request = Component4Request(
            component1={
                "fall_detected": component1_result["fall_detected"],
                "fall_type": component1_result["fall_type"],
                "risk_level": component1_result["risk_level"],
                "movement": component1_result["movement"],
                "confidence": component1_result.get("confidence", 0.0),
            },
            component2=component2,
            user=user,
        )

        component4_result = self.component4.predict(component4_request)

        escalated = force_alert_type is not None
        if force_alert_type:
            # Escalation (see app/alerts/router.py's /escalate endpoint)
            # overrides the model's probabilistic pick with a certain
            # one — an elder or timeout explicitly asking for help
            # shouldn't be second-guessed by a confidence score.
            component4_result["alert"] = force_alert_type

        saved_alert: Optional[Dict[str, Any]] = None
        if elder_id:
            saved_alert = AlertService.create(
                AlertRecord(
                    elder_id=elder_id,
                    fall_type=component1_result["fall_type"],
                    # FIX: was never persisted — Analytics on the
                    # Flutter side needs this real boolean to tell an
                    # actual fall apart from a pre-fall-warning alert;
                    # fall_type alone ("No Fall" included) can't carry
                    # that distinction. Already validated as a
                    # required key of component1_result above.
                    fall_detected=component1_result["fall_detected"],
                    risk_level=component1_result["risk_level"],
                    alert_type=component4_result.get("alert", "Voice Alert"),
                    confidence=float(component4_result.get("confidence", 0.0)),
                    location=component2.get("location"),
                    explanation=component1_result.get("explanation"),
                    guidance_completed=False,
                    escalated=escalated,
                    episode_id=episode_id,
                ),
                guidance=component4_result.get("guidance"),
            )

        return {
            "status": "success",
            "integration": "Component 1 -> Component 4",
            "component1": component1_result,
            "component4": component4_result,
            # FIX (THIRD FIX, see module docstring): the real,
            # Supabase-assigned alert id — the SAME id the WebSocket
            # broadcast carries for this same alert — so the Flutter
            # app can deduplicate by real identity regardless of which
            # path (this HTTP response or the WebSocket) it sees the
            # alert through first. None if elder_id was omitted or the
            # write failed; callers must not treat null as an error.
            "alert_id": saved_alert.get("id") if saved_alert else None,
        }


elder_care_pipeline = ElderCarePipeline()
