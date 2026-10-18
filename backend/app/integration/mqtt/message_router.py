"""
app/integration/mqtt/message_router.py

"""

import uuid
from typing import Any, Dict, Optional

from app.alerts.service import AlertService
from app.component1.api.router import store_prediction
from app.component4.guidance.feedback.feedback_controller import guidance_feedback_controller
from app.core.config import DEFAULT_ELDER_ID
from app.integration.component1_adapter import component1_adapter
from app.integration.component1_runtime import component1_runtime
from app.integration.pipeline import elder_care_pipeline
from app.realtime.websocket_manager import connection_manager

# Status update copy for the fall_detected=False branch. Defaults —
# adjust wording to taste, this doesn't affect any decision logic.
_STATUS_MESSAGES = {
    "LOW": "Elder is stable — no unusual activity detected.",
    "MEDIUM": "Instability detected while changing position — worth checking in when convenient.",
    "HIGH": "Instability detected after stopping from a walk — please check on them soon.",
}


class MQTTMessageRouter:
    def __init__(self) -> None:
        self.last_sensor_data: Dict[str, Any] = {}
        self.last_component1_prediction: Dict[str, Any] = {}
        self.guidance_active = False

        self._last_broadcast_status_level: Optional[str] = None

        # FIX (duplicate-alert prevention — see conversation notes /
        # alerts_rows.csv evidence): a single real fall is reported by
        # many consecutive MQTT samples (the ESP32 keeps sending
        # readings ~0.6-0.8s apart while the elder stays in the fallen
        # position), and fall_detected=True on every one of them. The
        # old code called elder_care_pipeline.predict() — which creates
        # a NEW alert row every time — unconditionally for every single
        # sample, producing dozens of duplicate alerts for one real
        # fall. This is NOT an MQTT redelivery problem (confidence and
        # explanation are identical across the duplicates, which only
        # happens when Component 1 genuinely re-evaluates the same
        # ongoing physical state each time).
        #
        # Fix: track whether a fall "episode" is already active. Only
        # the sample that TRANSITIONS fall_detected False -> True opens
        # a new episode (its own stable `_fall_episode_id`, generated
        # once) and is the one sample that reaches Component 4 / creates
        # an alert. Every subsequent sample that is still part of the
        # same ongoing episode reuses the already-decided Component 4
        # result instead of creating another alert row. The episode
        # closes (and the next fall starts a genuinely new episode, with
        # its own new alert) the moment a sample comes back with
        # fall_detected=False — i.e. Component 1 itself reports the
        # elder is no longer in a fallen state.
        #
        # This does not touch Component 1-4 themselves, AlertService,
        # or the pipeline — it only changes how often this router calls
        # into them.
        self._fall_episode_active = False
        self._fall_episode_id: Optional[str] = None
        self._fall_episode_component4: Optional[Dict[str, Any]] = None

        # FIX (restart/concurrency-safe backstop — see
        # AlertService.find_recent_open_episode()'s docstring for the
        # full reasoning and its documented limitation): the in-memory
        # state above is reset to "no active episode" on every backend
        # restart, even if the elder is still physically down and the
        # NEXT sample is really still the same ongoing fall. Before
        # opening what this process THINKS is a brand new episode, we
        # ask the database whether the most recent alert for this
        # elder already covers it. This is deliberately a narrow,
        # short-window check (see EPISODE_RECOVERY_WINDOW_SECONDS) used
        # ONLY at the moment of opening a new episode — it never
        # overrides the primary, transition-based logic above while an
        # episode is already tracked in memory.

    def process(self, sensor_data: Dict[str, Any]) -> Dict[str, Any]:
        self.last_sensor_data = sensor_data

        # ------------------------------------------------------
        # 1. COMPONENT 1 PREDICTION
        # ------------------------------------------------------
        trained_models = component1_runtime.load()
        component1_result = component1_adapter.predict(sensor_data, trained_models)
        self.last_component1_prediction = component1_result

        # ------------------------------------------------------
        # 2. STORE FOR THE REST API
        # ------------------------------------------------------
        store_prediction(component1_result)

        print(
            f"[Component 1] fall_detected={component1_result.get('fall_detected')} "
            f"fall_type={component1_result.get('fall_type')} risk_level={component1_result.get('risk_level')} "
            f"movement={component1_result.get('movement')} confidence={component1_result.get('confidence')}"
        )

        fall_detected = bool(component1_result.get("fall_detected", False))
        risk_level = str(component1_result.get("risk_level", "LOW"))

        guidance_result: Optional[Dict[str, Any]] = None
        sensor_feedback: Optional[Dict[str, Any]] = None
        component4_result: Optional[Dict[str, Any]] = None
        status_update: Optional[Dict[str, Any]] = None

        # ------------------------------------------------------
        # 3. BRANCH: real fall vs. pre-fall warning
        # ------------------------------------------------------
        if fall_detected:

            if not self._fall_episode_active:
                elder_id_for_check = DEFAULT_ELDER_ID or None
                recovered_episode = None
                if elder_id_for_check:
                    recovered_episode = AlertService.find_recent_open_episode(
                        elder_id_for_check,
                        fall_type=component1_result.get("fall_type", "fall"),
                    )

                if recovered_episode:
                    # Backstop hit: the DB already has a very recent
                    # alert matching this fall_type for this elder —
                    # most likely this process just restarted mid-fall.
                    # Treat it as the SAME episode: don't call the
                    # pipeline again (no second alert), just resume
                    # tracking it in memory so later samples keep
                    # skipping too.
                    self._fall_episode_active = True
                    self._fall_episode_id = recovered_episode.get("episode_id") or str(uuid.uuid4())
                    self._fall_episode_component4 = None
                    print(
                        f"[Integration] Recovered an already-open fall episode for elder "
                        f"{elder_id_for_check} from the database (likely a restart mid-fall) — "
                        f"not creating a duplicate alert."
                    )
                else:
                    # Genuinely new fall episode — this is the ONE
                    # sample for this episode that is allowed to reach
                    # Component 4 and create an alert.
                    self._fall_episode_active = True
                    self._fall_episode_id = str(uuid.uuid4())

                    try:
                        pipeline_result = elder_care_pipeline.predict(
                            component1_result=component1_result,
                            elder_id=elder_id_for_check,
                            episode_id=self._fall_episode_id,
                        )
                        component4_result = pipeline_result.get("component4")

                        # FIX (alert persistence failure -> safe retry):
                        # the pipeline reports whether the alert was
                        # actually PERSISTED via `alert_id` (None if
                        # elder_id was omitted, OR if AlertService.create()
                        # failed — see pipeline.py's own docstring).
                        # Locking in the episode here when the write
                        # failed would mean every later sample for this
                        # same ongoing fall keeps skipping forever, so
                        # this real fall would end up with NO alert row
                        # at all. Only commit to "episode open, don't
                        # retry" once we know an alert actually exists
                        # for it; otherwise let the NEXT sample try again.
                        if elder_id_for_check and pipeline_result.get("alert_id") is None:
                            print(
                                "[Integration] Alert persistence failed for this fall sample — "
                                "will retry on the next sample instead of marking the episode open."
                            )
                            self._fall_episode_active = False
                            self._fall_episode_id = None
                            self._fall_episode_component4 = None
                        else:
                            self._fall_episode_component4 = component4_result
                    except Exception as exc:
                        print(f"[Integration] Component 4 auto-alert failed: {exc}")
                        # Don't leave the episode "active" with no alert
                        # on record for it — a later sample should get
                        # another chance to create the alert rather than
                        # silently skipping this fall altogether.
                        self._fall_episode_active = False
                        self._fall_episode_id = None
                        self._fall_episode_component4 = None
            else:
                # Same physical fall, still being reported by
                # consecutive samples — reuse the decision already made
                # for this episode instead of creating another alert.
                component4_result = self._fall_episode_component4
                print(
                    f"[Integration] Fall episode {self._fall_episode_id} still active — "
                    f"skipping duplicate alert for this sample."
                )

            if component4_result:
                alert_type = component4_result.get("alert")
                guidance = component4_result.get("guidance") or {}
                print(
                    f"[Component 4] alert={alert_type} "
                    f"confidence={component4_result.get('confidence')} "
                    f"guidance_enabled={guidance.get('enabled')}"
                )

                # Guidance feedback-loop bookkeeping only matters
                # when the model routed this to the elder.
                if alert_type == "Voice Alert" and guidance.get("enabled"):
                    if not self.guidance_active:
                        feedback_state = guidance_feedback_controller.start(
                            component1_result.get("fall_type", "fall"), guidance.get("steps", [])
                        )
                        self.guidance_active = True
                        guidance_result = {**guidance, "feedback_state": feedback_state}
                    else:
                        guidance_result = guidance

            # A confirmed fall supersedes any stale "pre-fall" status.
            self._last_broadcast_status_level = None

        else:
            # No physical fall — a pre-fall warning status update for
            # the caregiver (see conversation notes: "fall_detected
            # false -> alert caregiver with current status").
            if risk_level.upper() != self._last_broadcast_status_level:
                status_update = self._build_status_update(risk_level)
                self._broadcast_status_update(status_update)
                self._last_broadcast_status_level = risk_level.upper()

            # FIX: Component 1 itself says the elder is no longer
            # fallen — close the fall episode so the NEXT fall_detected
            # transition starts a genuinely new episode with its own
            # new alert, instead of staying silently "stuck active"
            # forever after a real recovery.
            self._fall_episode_active = False
            self._fall_episode_id = None
            self._fall_episode_component4 = None

        # ------------------------------------------------------
        # 4. Ongoing guidance sensor feedback (unrelated to which
        #    branch fired this cycle — tracks an already-active session)
        #
        # NEW: this feedback (computed by StepValidator from the REAL
        # IMU stream — see step_validator.py) previously stayed purely
        # server-side; the elder's phone never learned a step had been
        # validated as complete, so the only way to advance was the
        # manual "Next Step" button in the Flutter app. Broadcasting it
        # over the SAME WebSocket channel used for alerts/status lets
        # the elder app auto-advance when the sensor confirms a step —
        # without removing the manual button as a fallback.
        # ------------------------------------------------------
        if self.guidance_active:
            sensor_feedback = guidance_feedback_controller.process_sensor(sensor_data)
            if not sensor_feedback.get("active", False):
                self.guidance_active = False
            self._broadcast_guidance_progress(sensor_feedback)

        return {
            "status": "success",
            "source": "HiveMQ MQTT",
            "sensor_data": sensor_data,
            "prediction": component1_result,
            "guidance": guidance_result,
            "sensor_feedback": sensor_feedback,
            "alert": component4_result,
            "status_update": status_update,
        }

    def _build_status_update(self, risk_level: str) -> Dict[str, Any]:
        normalized = risk_level.upper()
        return {
            "risk_level": normalized,
            "message": _STATUS_MESSAGES.get(normalized, _STATUS_MESSAGES["LOW"]),
        }

    def _broadcast_status_update(self, status_update: Dict[str, Any]) -> None:

        if not DEFAULT_ELDER_ID:
            return
        print(f"[Status Update] risk_level={status_update['risk_level']} message={status_update['message']}")
        try:
            connection_manager.broadcast_sync(DEFAULT_ELDER_ID, {
                "type": "status_update",
                "status": status_update,
            })
        except Exception as exc:
            print(f"[Integration] Status update broadcast failed: {exc}")

    # NEW: broadcasts the real-time StepValidator result (current_step,
    # total_steps, completed/active flags, raw validation detail) to the
    # elder's own WebSocket connection, every MQTT sample while guidance
    # is active — not just on completion — so the Flutter app can also
    # show live "stabilizing..." feedback if it chooses to, not only the
    # step-advance moment.
    def _broadcast_guidance_progress(self, sensor_feedback: Dict[str, Any]) -> None:
        if not DEFAULT_ELDER_ID:
            return
        print(
            f"[Guidance Progress] status={sensor_feedback.get('status')} "
            f"current_step={sensor_feedback.get('current_step')} "
            f"total_steps={sensor_feedback.get('total_steps')}"
        )
        try:
            connection_manager.broadcast_sync(DEFAULT_ELDER_ID, {
                "type": "guidance_progress",
                "progress": sensor_feedback,
            })
        except Exception as exc:
            print(f"[Integration] Guidance progress broadcast failed: {exc}")

    def reset_guidance(self) -> None:
        guidance_feedback_controller.stop()
        self.guidance_active = False


mqtt_message_router = MQTTMessageRouter()
