"""
app/component3/ml/ppg_processor.py — Component 3 PPG signal processing.

This is the ONE PPG processing implementation. The original project
had this exact logic duplicated inline inside a websocket handler in
main.py; that duplicate has been removed — the MQTT service
(app/component3/mqtt_service.py) uses this class directly.
"""

from collections import deque
from typing import Any, Dict

import numpy as np
from scipy.signal import butter, filtfilt, find_peaks

try:
    import joblib
except ImportError:  # pragma: no cover
    joblib = None


class PPGProcessor:
    def __init__(self, model_path: str) -> None:
        self.model = None
        self.ir_buffer: list = []
        self.timestamps: list = []

        self.hr_smooth_buffer = deque(maxlen=10)
        self.sys_smooth_buffer = deque(maxlen=10)
        self.dia_smooth_buffer = deque(maxlen=10)
        self.pti_smooth_buffer = deque(maxlen=10)

        self.latest_result: Dict[str, Any] = {
            "heart_rate": 0.0,
            "pulse_interval": 0.0,
            "systolic_bp": 0,
            "diastolic_bp": 0,
            "health_status": "Waiting",
            "finger_detected": False,
            "timestamp": 0,
            "red": 0,
            "ir": 0,
        }

        if joblib is not None:
            try:
                self.model = joblib.load(model_path)
                print(f"[Component 3] BP model loaded from {model_path}")
            except Exception as exc:
                print(f"[Component 3] BP model failed to load: {exc}")
        else:
            print("[Component 3] joblib not installed — BP prediction disabled.")

    def reset(self) -> None:
        self.ir_buffer.clear()
        self.timestamps.clear()
        self.hr_smooth_buffer.clear()
        self.sys_smooth_buffer.clear()
        self.dia_smooth_buffer.clear()
        self.pti_smooth_buffer.clear()

    @staticmethod
    def bandpass_filter(data, lowcut=0.7, highcut=3.0, fs=50.0):
        nyq = 0.5 * fs
        low, high = lowcut / nyq, highcut / nyq
        b, a = butter(1, [low, high], btype="band")
        return filtfilt(b, a, data)

    @staticmethod
    def calculate_health_status(heart_rate: float, systolic_bp: float) -> str:
        if heart_rate <= 0:
            return "Waiting"
        if heart_rate > 120 or heart_rate < 45 or systolic_bp > 140 or systolic_bp < 90:
            return "Critical"
        if heart_rate > 100 or heart_rate < 50 or systolic_bp > 130 or systolic_bp < 100:
            return "Risky"
        return "Normal"

    def _no_finger_result(self, timestamp: int, red: int, ir: int) -> Dict[str, Any]:
        self.reset()
        result = {
            "heart_rate": 0.0, "pulse_interval": 0.0,
            "systolic_bp": 0, "diastolic_bp": 0,
            "health_status": "No Finger Detected", "finger_detected": False,
            "timestamp": timestamp, "red": red, "ir": ir,
        }
        self.latest_result = result
        return result

    def process_sample(self, timestamp: int, red: int, ir: int) -> Dict[str, Any]:
        try:
            timestamp, red, ir = int(timestamp), int(red), int(ir)
        except (TypeError, ValueError):
            return self.latest_result

        # IR < 70000 => no finger present on the sensor.
        if ir < 70000:
            return self._no_finger_result(timestamp, red, ir)

        self.ir_buffer.append(ir)
        self.timestamps.append(timestamp)
        if len(self.ir_buffer) > 250:
            self.ir_buffer.pop(0)
            self.timestamps.pop(0)

        avg_hr = pulse_interval = 0.0
        bp_sys = bp_dia = 0

        if len(self.ir_buffer) >= 80:
            try:
                time_diffs = np.diff(self.timestamps)
                mean_diff_ms = np.mean(time_diffs) if len(time_diffs) > 0 else 0
                fs = (1000.0 / mean_diff_ms) if mean_diff_ms > 0 else 50.0
                fs = fs if fs > 0 else 50.0

                raw_signal = np.array(self.ir_buffer, dtype=float)
                detrended = raw_signal - np.mean(raw_signal)

                try:
                    highcut = min(3.0, (fs / 2.0) - 0.1)
                    filtered_ir = (
                        self.bandpass_filter(detrended, lowcut=0.7, highcut=highcut, fs=fs)
                        if highcut > 0.7 else detrended
                    )
                except Exception:
                    filtered_ir = detrended

                min_dist = max(int(fs / 3.0), 5)
                std_val = np.std(filtered_ir)
                prom_val = max(std_val * 0.3, 2.0)

                peaks, _ = find_peaks(-filtered_ir, distance=min_dist, prominence=prom_val)
                if len(peaks) < 2:
                    peaks, _ = find_peaks(filtered_ir, distance=min_dist, prominence=prom_val)

                if len(peaks) >= 2:
                    peak_times = [self.timestamps[p] / 1000.0 for p in peaks]
                    intervals = np.diff(peak_times)

                    if len(intervals) > 0:
                        raw_pti = float(intervals[-1] * 1000.0)
                        raw_avg_hr = float(60.0 / np.mean(intervals))

                        if 50 <= raw_avg_hr <= 180:
                            if self.model is not None:
                                try:
                                    features = np.array([[red, ir, raw_avg_hr, raw_pti]])
                                    predicted_bp = self.model.predict(features)
                                    if predicted_bp is not None and len(predicted_bp) > 0:
                                        prediction = predicted_bp[0]
                                        if len(prediction) >= 2:
                                            self.sys_smooth_buffer.append(float(prediction[0]))
                                            self.dia_smooth_buffer.append(float(prediction[1]))
                                except Exception as exc:
                                    print(f"[Component 3] BP prediction error: {exc}")

                            self.hr_smooth_buffer.append(raw_avg_hr)
                            self.pti_smooth_buffer.append(raw_pti)

                            avg_hr = sum(self.hr_smooth_buffer) / len(self.hr_smooth_buffer)
                            pulse_interval = sum(self.pti_smooth_buffer) / len(self.pti_smooth_buffer)

                            if self.sys_smooth_buffer:
                                bp_sys = int(sum(self.sys_smooth_buffer) / len(self.sys_smooth_buffer))
                            if self.dia_smooth_buffer:
                                bp_dia = int(sum(self.dia_smooth_buffer) / len(self.dia_smooth_buffer))

            except Exception as exc:
                print(f"[Component 3] PPG processing error: {exc}")

        health_status = self.calculate_health_status(avg_hr, bp_sys)

        result = {
            "heart_rate": round(float(avg_hr), 1),
            "pulse_interval": round(float(pulse_interval), 1),
            "systolic_bp": int(bp_sys),
            "diastolic_bp": int(bp_dia),
            "health_status": health_status,
            "finger_detected": True,
            "timestamp": timestamp,
            "red": red,
            "ir": ir,
        }
        self.latest_result = result
        return result

    def get_latest_result(self) -> Dict[str, Any]:
        return dict(self.latest_result)
