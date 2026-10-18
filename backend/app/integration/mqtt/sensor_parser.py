"""
app/integration/mqtt/sensor_parser.py

Converts a raw ESP32 IMU payload (ax, ay, az, gx, gy, gz) into the
field names Component 1 expects (accel_x, accel_y, ... gyro_z).

UNIT FIX (see conversation notes): live device readings showed
accel_z ~ 0.997 at rest, while Component 1's training data
(fall_detection.py's generate_dataset()) encodes gravity as ~9.81 —
i.e. the ESP32 accelerometer reports in g-units (±1g = ±9.81 m/s²),
not the m/s² units the model was trained on. 0.997 * 9.81 ≈ 9.78,
matching the training data almost exactly, which confirms this is a
unit mismatch rather than a sensor fault.

Only accel_x/y/z are converted. Gyro values (gx/gy/gz) are left
untouched — their live values already sit within the training
distribution's range, so no conversion is needed there.

This fixes the RULE-BASED layer of Component 1 (fall_detected,
risk_level — see analyze_sequence() in fall_detection.py), which
depends on raw acceleration crossing a ±3.0 m/s² threshold. It does
NOT fully fix the ML classifiers (fall_type, activity) — those are
pattern-learned from synthetic data and have a separate limitation
even with correct units (see conversation notes on retraining with
real data as a follow-up, out of scope here).
"""

import json
from typing import Any, Dict

REQUIRED_FIELDS = ["accel_x", "accel_y", "accel_z", "gyro_x", "gyro_y", "gyro_z"]

_FIELD_MAP = {
    "accel_x": "ax", "accel_y": "ay", "accel_z": "az",
    "gyro_x": "gx", "gyro_y": "gy", "gyro_z": "gz",
}

# Standard gravity, used to convert accelerometer readings from
# g-units (what this ESP32 reports) to m/s² (what the model expects).
_G_TO_MS2 = 9.81
_ACCEL_FIELDS = {"accel_x", "accel_y", "accel_z"}


def parse_sensor_payload(payload: Any) -> Dict[str, float]:
    if isinstance(payload, bytes):
        try:
            payload = payload.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError(f"Invalid UTF-8 sensor payload: {exc}")

    if isinstance(payload, str):
        try:
            data = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid JSON sensor payload: {exc}")
    elif isinstance(payload, dict):
        data = payload
    else:
        raise ValueError("Sensor payload must be JSON bytes, JSON string, or dictionary.")

    if not isinstance(data, dict):
        raise ValueError("Sensor JSON must contain an object.")

    missing_device_fields = [f for f in _FIELD_MAP.values() if f not in data]
    if missing_device_fields:
        raise ValueError("Missing ESP32 IMU fields: " + ", ".join(missing_device_fields))

    sensor_data = {}
    for component1_field, device_field in _FIELD_MAP.items():
        try:
            value = float(data[device_field])
        except (TypeError, ValueError):
            raise ValueError(f"Invalid numeric value for {device_field}: {data[device_field]}")

        if component1_field in _ACCEL_FIELDS:
            value *= _G_TO_MS2  # g-units -> m/s², see module docstring

        sensor_data[component1_field] = value

    missing = [f for f in REQUIRED_FIELDS if f not in sensor_data]
    if missing:
        raise ValueError("Missing Component 1 fields: " + ", ".join(missing))

    return sensor_data
