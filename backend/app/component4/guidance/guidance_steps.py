"""
app/component4/guidance/guidance_steps.py

"""

GUIDANCE_STEPS = {
    "fall_forward": [
        "Stay calm and do not move suddenly.",
        "Check whether you can move your arms and legs.",
        "Slowly turn yourself into a comfortable position.",
        "Use nearby support if you need help maintaining balance.",
        "If you feel stable, slowly return to a sitting or standing position.",
    ],
    "fall_backward": [
        "Stay calm and avoid sudden movements.",
        "Check whether you can move your arms and legs.",
        "Slowly move into a comfortable position.",
        "Use nearby support if available.",
        "If you feel stable, slowly sit up before attempting to stand.",
    ],
    "fall_side_left": [
        "Stay calm and remain still for a moment.",
        "Check whether you can move your arms and legs.",
        "Slowly adjust your position if you are comfortable.",
        "Use nearby support if available.",
        "If you feel stable, slowly return to a sitting or standing position.",
    ],
    "fall_side_right": [
        "Stay calm and remain still for a moment.",
        "Check whether you can move your arms and legs.",
        "Slowly adjust your position if you are comfortable.",
        "Use nearby support if available.",
        "If you feel stable, slowly return to a sitting or standing position.",
    ],
    "fall_slump": [
        "Stay calm and avoid sudden movements.",
        "Check whether you are comfortable and able to move.",
        "Try to maintain a stable position.",
        "Use nearby support if available.",
        "If you feel stable, slowly return to a comfortable sitting position.",
    ],
    "fall": [  # generic fallback
        "Stay calm and do not move suddenly.",
        "Check whether you can move your arms and legs.",
        "Slowly move into a comfortable position.",
        "Use nearby support if necessary.",
        "Only stand up if you feel stable.",
    ],
}
