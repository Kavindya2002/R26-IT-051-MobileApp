"""
app/component4/guidance/guidance_service.py

"""

from typing import Any, Dict

from app.component4.guidance.guidance_controller import guidance_controller


class GuidanceService:
    @staticmethod
    def create_guidance(alert: str, risk_level: str, fall_detected: bool, fall_type: str) -> Dict[str, Any]:
        normalized_alert = str(alert).strip()
        normalized_risk = str(risk_level).strip().upper()
        normalized_fall_type = str(fall_type).strip().lower()

        if normalized_alert != "Voice Alert" or not bool(fall_detected):
            return {
                "enabled": False,
                "alert": normalized_alert,
                "risk_level": normalized_risk,
                "fall_detected": bool(fall_detected),
                "fall_type": normalized_fall_type,
                "message": "Guidance is only available when the model routes a detected fall to a Voice Alert.",
                "steps": [],
                "current_step": None,
                "total_steps": 0,
            }

        guidance = guidance_controller.get_steps(fall_type=normalized_fall_type)
        return {
            "enabled": True,
            "alert": normalized_alert,
            "risk_level": normalized_risk,
            "fall_detected": True,
            "fall_type": normalized_fall_type,
            "message": "Guidance activated — the elder can follow these recovery steps themselves.",
            "steps": guidance.get("steps", []),
            "current_step": guidance.get("current_step", 1),
            "total_steps": guidance.get("total_steps", 0),
        }


guidance_service = GuidanceService()
