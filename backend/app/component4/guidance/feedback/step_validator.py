"""
app/component4/guidance/feedback/step_validator.py

REAL movement-threshold logic (replaces the old always-False stub).

HOW THIS WORKS (read before changing thresholds):
    Component 4's guidance feature has no labeled dataset of "what a
    completed recovery step looks like" — Component 1's ML models were
    trained only to classify activity/fall_type/risk, never
    step-completion. Building a per-step semantic classifier would mean
    inventing numbers with no data behind them.

    Instead, this reuses the EXACT SAME rule-based stability check
    Component 1 already trusts for its own fall_detected logic
    (see app/component1/ml/fall_detection.py -> get_stability()):

        horizontal_magnitude = sqrt(accel_x^2 + accel_y^2)
        gravity_deviation    = |accel_z| - 9.81  (absolute)
        Stable  <=>  horizontal_magnitude <= 2.0  AND  gravity_deviation <= 1.5

    Every guidance step's instruction is some variant of "stay calm /
    move slowly / settle into a stable position" — so "this step is
    done" is approximated as "the elder's IMU readings have been
    CONSISTENTLY stable for several consecutive samples", not just one
    (one sample alone is noise — a brief pause mid-thrash would false-
    positive). STABLE_STREAK_REQUIRED below controls how many
    consecutive stable samples are required before a step is marked
    complete.

    LIMITATION (be honest about this with the user/report): this is a
    general "has the elder settled down" gate, not a verification that
    the SPECIFIC action described in that step (e.g. "turn yourself
    into position") was actually performed. It cannot be fully correct
    without real labeled hardware data for step completion — that data
    does not exist yet. This is the best defensible approximation
    available from the real sensor pipeline today, using thresholds
    Component 1 already relies on (not invented for this file).
"""

from typing import Any, Dict, List, Optional

from app.component4.guidance.feedback.sensor_state import SensorState

# Same thresholds as app/component1/ml/fall_detection.py's get_stability().
# Kept as separate constants here (not imported) so this file has no
# runtime dependency on Component 1's module — values are intentionally
# identical to stay consistent with what Component 1 already calls "stable".
_HORIZONTAL_MAGNITUDE_THRESHOLD = 2.0
_GRAVITY_DEVIATION_THRESHOLD = 1.5
_GRAVITY_MS2 = 9.81

# How many CONSECUTIVE stable samples are required before a step counts
# as completed. Higher = fewer false-positives from a brief lull, but
# slower to register real completion. 3 is a reasonable starting point;
# tune after real device testing.
STABLE_STREAK_REQUIRED = 3


def _is_stable(sensor: SensorState) -> bool:
    horizontal_magnitude = (sensor.accel_x ** 2 + sensor.accel_y ** 2) ** 0.5
    gravity_deviation = abs(abs(sensor.accel_z) - _GRAVITY_MS2)
    return (
        horizontal_magnitude <= _HORIZONTAL_MAGNITUDE_THRESHOLD
        and gravity_deviation <= _GRAVITY_DEVIATION_THRESHOLD
    )


class StepValidator:
    def __init__(self) -> None:
        self.last_sensor_state: Optional[SensorState] = None
        self._recent_stable_flags: List[bool] = []

    def update_sensor(self, sensor_data: Dict[str, Any]) -> Dict[str, Any]:
        sensor = SensorState.from_dict(sensor_data)
        self.last_sensor_state = sensor
        return {"status": "sensor_updated", "sensor": sensor.to_dict()}

    def _reset_streak(self) -> None:
        self._recent_stable_flags = []

    def validate_step(self, current_step: int, fall_type: str,
                       sensor_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        if sensor_data is not None:
            self.update_sensor(sensor_data)

        if self.last_sensor_state is None:
            return {
                "step": current_step, "completed": False,
                "status": "waiting_for_sensor_feedback",
                "message": "Waiting for IMU sensor feedback.",
            }

        stable_now = _is_stable(self.last_sensor_state)
        self._recent_stable_flags.append(stable_now)
        if len(self._recent_stable_flags) > STABLE_STREAK_REQUIRED:
            self._recent_stable_flags.pop(0)

        base = {
            "step": current_step,
            "fall_type": str(fall_type).strip().lower(),
            "sensor": self.last_sensor_state.to_dict(),
            "stable_now": stable_now,
            "stable_streak": sum(1 for f in self._recent_stable_flags if f),
            "stable_streak_required": STABLE_STREAK_REQUIRED,
        }

        if not stable_now:
            # Any unstable sample breaks the streak — still moving/thrashing.
            self._reset_streak()
            return {
                **base,
                "completed": False,
                "status": "movement_detected",
                "message": "Movement still detected — take your time and try to settle into a stable position.",
            }

        if len(self._recent_stable_flags) < STABLE_STREAK_REQUIRED:
            return {
                **base,
                "completed": False,
                "status": "stabilizing",
                "message": "Holding steady — keep still a moment longer to confirm this step.",
            }

        # STABLE_STREAK_REQUIRED consecutive stable samples -> step done.
        self._reset_streak()
        return {
            **base,
            "completed": True,
            "status": "step_completed",
            "message": "Stable position confirmed. Moving to the next step.",
        }


step_validator = StepValidator()