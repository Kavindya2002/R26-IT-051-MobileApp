"""
app/component4/guidance/guidance_controller.py

FIX (fall_type / GUIDANCE_STEPS key mismatch — real bug, not a style
issue): Component 1's trained classifier (app/component1/ml/
fall_detection.py -> le_fall encoder) outputs fall_type as one of:

    "Backward Fall", "Forward Fall", "No Fall",
    "Side Fall Left", "Side Fall Right"

guidance_steps.py's GUIDANCE_STEPS dict is keyed by a different,
snake_case convention instead:

    "fall_forward", "fall_backward", "fall_side_left",
    "fall_side_right", "fall_slump", "fall" (generic fallback)

The old get_steps() only lowercased the incoming fall_type
("Forward Fall" -> "forward fall") without converting it to the
snake_case key format, so GUIDANCE_STEPS.get(normalized) could NEVER
match for a real fall event — every real fall silently fell through to
the generic "fall" steps regardless of its actual direction, even
though the direction-specific entries were sitting right there in
GUIDANCE_STEPS unused.

_FALL_TYPE_ALIASES below is the translation table between Component 1's
real output strings and GUIDANCE_STEPS's keys. Snake_case inputs (e.g.
from a manual/Swagger test that already sends "fall_forward", or
"fall_slump" which Component 1's model has no class for at all — only
reachable via manual input) pass through unchanged, since they already
match a GUIDANCE_STEPS key directly.
"""

from typing import Any, Dict

from app.component4.guidance.guidance_steps import GUIDANCE_STEPS

# Maps Component 1's real (human-readable) fall_type strings, lowercased,
# to the snake_case keys GUIDANCE_STEPS actually uses. Add an entry here
# whenever a new human-readable variant is seen from Component 1 or any
# other real upstream source — do NOT change GUIDANCE_STEPS's own keys,
# since those are the stable, documented contract for this feature's
# content.
_FALL_TYPE_ALIASES = {
    "forward fall": "fall_forward",
    "backward fall": "fall_backward",
    "side fall left": "fall_side_left",
    "side fall right": "fall_side_right",
    "left side fall": "fall_side_left",   # defensive: alternate word order
    "right side fall": "fall_side_right", # defensive: alternate word order
    "slump fall": "fall_slump",
    "slump": "fall_slump",
    "no fall": "fall",
}


class GuidanceController:
    @staticmethod
    def get_steps(fall_type: str) -> Dict[str, Any]:
        normalized = str(fall_type).strip().lower()
        # Translate a real Component 1 output ("forward fall") to the
        # GUIDANCE_STEPS key format ("fall_forward"). If `normalized`
        # is already in that format (e.g. a manual/Swagger test sending
        # "fall_forward" directly), the alias lookup misses and
        # `normalized` is used as-is — GUIDANCE_STEPS.get() then matches
        # it directly.
        normalized = _FALL_TYPE_ALIASES.get(normalized, normalized)

        steps = GUIDANCE_STEPS.get(normalized) or GUIDANCE_STEPS.get("fall", [])
        return {
            "fall_type": normalized,
            "steps": steps,
            "current_step": 1 if steps else None,
            "total_steps": len(steps),
        }


guidance_controller = GuidanceController()