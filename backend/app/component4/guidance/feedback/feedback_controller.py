from typing import Any, Dict, List, Optional

from app.component4.guidance.feedback.step_validator import StepValidator


class GuidanceFeedbackController:
    def __init__(self) -> None:
        self.validator = StepValidator()
        self.active = False
        self.fall_type: Optional[str] = None
        self.current_step: Optional[int] = None
        self.total_steps = 0

    def start(self, fall_type: str, steps: List[str]) -> Dict[str, Any]:
        self.active = True
        self.fall_type = str(fall_type).strip().lower()
        self.current_step = 1 if steps else None
        self.total_steps = len(steps)
        return self.get_state()

    def stop(self) -> None:
        self.active = False
        self.fall_type = None
        self.current_step = None
        self.total_steps = 0
        self.validator = StepValidator()

    def process_sensor(self, sensor_data: Dict[str, Any]) -> Dict[str, Any]:
        if not self.active:
            return {"active": False, "status": "guidance_not_active",
                    "message": "Guidance is not currently active."}

        if self.current_step is None:
            return {"active": True, "status": "guidance_completed",
                    "message": "All guidance steps are completed."}

        validation = self.validator.validate_step(
            current_step=self.current_step, fall_type=self.fall_type, sensor_data=sensor_data
        )

        if validation.get("completed", False):
            self.current_step += 1
            if self.current_step > self.total_steps:
                self.active = False
                return {"active": False, "status": "guidance_completed",
                        "message": "All guidance steps are completed.",
                        "completed_step": self.total_steps}

        return {
            "active": self.active,
            "status": validation.get("status", "feedback_received"),
            "fall_type": self.fall_type,
            "current_step": self.current_step,
            "total_steps": self.total_steps,
            "validation": validation,
        }

    def get_state(self) -> Dict[str, Any]:
        return {
            "active": self.active, "fall_type": self.fall_type,
            "current_step": self.current_step, "total_steps": self.total_steps,
        }


guidance_feedback_controller = GuidanceFeedbackController()
