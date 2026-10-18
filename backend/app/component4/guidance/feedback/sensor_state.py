from dataclasses import dataclass
from typing import Any, Dict


@dataclass
class SensorState:
    accel_x: float
    accel_y: float
    accel_z: float
    gyro_x: float
    gyro_y: float
    gyro_z: float

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SensorState":
        required = ["accel_x", "accel_y", "accel_z", "gyro_x", "gyro_y", "gyro_z"]
        missing = [f for f in required if f not in data]
        if missing:
            raise ValueError("Missing IMU sensor fields: " + ", ".join(missing))
        try:
            return cls(**{f: float(data[f]) for f in required})
        except (TypeError, ValueError) as exc:
            raise ValueError("Invalid IMU sensor values.") from exc

    def to_dict(self) -> Dict[str, float]:
        return {
            "accel_x": self.accel_x, "accel_y": self.accel_y, "accel_z": self.accel_z,
            "gyro_x": self.gyro_x, "gyro_y": self.gyro_y, "gyro_z": self.gyro_z,
        }
