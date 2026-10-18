from datetime import datetime, timezone
from typing import Any, Dict

from app.component1.ml.fall_detection import run_system


class Component1Adapter:
    """Wraps Component 1's run_system() with its own rolling history."""

    def __init__(self) -> None:
        self.history: list = []

    def predict(self, sensor_data: Dict[str, Any], trained_models: Dict[str, Any]) -> Dict[str, Any]:
        result = run_system(sensor_data, self.history, trained_models)
        return {
            "fall_detected": bool(result.get("fall_detected", False)),
            "fall_type": str(result.get("fall_type", "No Fall")),
            "risk_level": str(result.get("risk_level", "LOW")),
            # FIX (Fall Detection screen, Flutter-side limitation closed):
            # `movement` is kept EXACTLY as before (activity only — the
            # `result.get("stability", ...)` fallback here was always
            # dead code anyway, since run_system() unconditionally
            # includes "activity") so nothing that already reads
            # `movement` changes meaning.
            "movement": str(result.get("activity", result.get("stability", "stable"))),
            # NEW: run_system() has always computed a real "stability"
            # value (Stable/Unstable, from get_stability()) — it just
            # never left this adapter before. Threading it through as
            # its own field (rather than overloading `movement`) is what
            # lets the Flutter Fall Detection screen show a genuine
            # Stability row instead of "Stability unavailable", without
            # touching run_system()/the ML model itself at all.
            "stability": str(result.get("stability", "")),
            "confidence": float(result.get("confidence", 0.0)),
            "explanation": result.get("explanation", ""),
            # NEW: surfaces which layer actually produced `fall_type`
            # above. "ml_model" = the RandomForest classifier's own
            # top prediction (the normal case). "rule_fallback" = the
            # rule layer's fall_detected=True overrode a conflicting
            # ML "No Fall" result with the direction derived from the
            # same raw impact data (see fall_detection.py run_system()
            # for why this can happen and why it's not a bug). Kept as
            # its own field rather than silently folded into fall_type
            # so this stays auditable end-to-end, including in the
            # Flutter UI/logs if they choose to show it.
            "fall_type_source": str(result.get("fall_type_source", "ml_model")),
            # FIX (Flutter Home Dashboard fall-event identification):
            # a REAL server-side timestamp of when THIS sample was
            # actually processed — not a fabricated value, just the
            # wall-clock moment this inference ran. /component1/latest
            # previously exposed no per-sample identity at all, so the
            # Flutter app could not reliably tell "this poll's reading
            # is still the same fall as last poll's" apart from "this
            # is a genuinely new fall that happens to look identical".
            # Microsecond-resolution UTC ISO-8601 makes two distinct
            # samples colliding astronomically unlikely, unlike the
            # fall_type/risk_level/confidence fields alone.
            "sample_time": datetime.now(timezone.utc).isoformat(),
        }

    def reset_history(self) -> None:
        self.history.clear()


component1_adapter = Component1Adapter()
