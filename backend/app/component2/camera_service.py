"""
app/component2/camera_service.py — ESP32-CAM + YOLO detection.

Ported from the original standalone Streamlit dashboard (main.py) into
the same single-process architecture as component2_mqtt_service and
component3_mqtt_service — see mqtt_service.py's module docstring for
why that matters (the original bug was running this kind of worker in
a separate OS process that couldn't share state with FastAPI).

Each discovered camera device (device_type == "camera", published via
MQTT discovery with a "stream_url") gets one CameraWorker. The worker
owns an OpenCV VideoCapture on the ESP32-CAM's MJPEG stream, runs each
frame through YOLO, and keeps only the latest annotated JPEG in memory
— the API layer (api/router.py) just reads that snapshot, it never
touches OpenCV/YOLO directly.

YOLO is imported lazily so the rest of the backend still starts and
serves Components 1/3/4 even if ultralytics/opencv aren't installed
or a model fails to download.
"""

import threading
import time
from datetime import datetime
from typing import Any, Dict, Optional

try:
    import cv2
except Exception:
    cv2 = None

try:
    from ultralytics import YOLO
except Exception:
    YOLO = None

from app.core.config import (
    YOLO_CONFIDENCE,
    YOLO_DEVICE,
    YOLO_IMAGE_SIZE,
    YOLO_IOU,
    YOLO_MODEL_PATH,
    CAMERA_RECONNECT_SECONDS,
    CAMERA_TARGET_FPS,
)

_MODEL_LOCK = threading.RLock()
_yolo_model = None
_yolo_error: Optional[str] = None


def get_yolo_model():
    """Lazily loads the YOLO model once, shared by every camera worker."""
    global _yolo_model, _yolo_error
    if YOLO is None:
        return None
    with _MODEL_LOCK:
        if _yolo_model is None and _yolo_error is None:
            try:
                _yolo_model = YOLO(YOLO_MODEL_PATH)
            except Exception as exc:
                _yolo_error = str(exc)
                print(f"[Component 2 / Camera] YOLO failed to load: {exc}")
        return _yolo_model


def yolo_status() -> Dict[str, Any]:
    return {
        "available": YOLO is not None and cv2 is not None,
        "model_path": YOLO_MODEL_PATH,
        "loaded": _yolo_model is not None,
        "error": _yolo_error,
    }


class CameraWorker:
    """One worker per discovered ESP32-CAM: MJPEG stream -> YOLO -> JPEG."""

    def __init__(self, device_id: str, stream_url: str):
        self.device_id = device_id
        self.stream_url = stream_url

        self.stop_event = threading.Event()
        self.thread: Optional[threading.Thread] = None
        self.lock = threading.RLock()

        self.latest_jpeg: Optional[bytes] = None
        self.latest_frame_time: Optional[datetime] = None
        self.latest_fps = 0.0
        self.latest_detection_count = 0
        self.last_error: Optional[str] = None

        self._frames_seen = 0
        self._last_fps_time = time.monotonic()

    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.stop_event.clear()
        self.thread = threading.Thread(target=self._run, name=f"camera-{self.device_id}", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()

    def update_stream_url(self, stream_url: str) -> None:
        if stream_url and stream_url != self.stream_url:
            self.stream_url = stream_url
            self.stop_event.set()  

    def get_snapshot(self) -> Dict[str, Any]:
        with self.lock:
            return {
                "jpeg": self.latest_jpeg,
                "frame_time": self.latest_frame_time.isoformat() if self.latest_frame_time else None,
                "fps": round(self.latest_fps, 1),
                "detections": self.latest_detection_count,
                "error": self.last_error,
            }

    def _annotate(self, frame):
        model = get_yolo_model()
        if model is None:
            return frame, 0
        try:
            kwargs = {
                "source": frame,
                "conf": YOLO_CONFIDENCE,
                "iou": YOLO_IOU,
                "imgsz": YOLO_IMAGE_SIZE,
                "verbose": False,
            }
            if YOLO_DEVICE:
                kwargs["device"] = YOLO_DEVICE
            results = model.predict(**kwargs)
            if not results:
                return frame, 0
            result = results[0]
            annotated = result.plot(conf=True, labels=True, boxes=True)
            count = len(result.boxes) if result.boxes is not None else 0
            return annotated, count
        except Exception as exc:
            with self.lock:
                self.last_error = f"YOLO inference failed: {exc}"
            return frame, 0

    def _run(self) -> None:
        if cv2 is None:
            with self.lock:
                self.last_error = "opencv-python is not installed."
            return

        frame_delay = 1.0 / CAMERA_TARGET_FPS if CAMERA_TARGET_FPS > 0 else 0

        while not self.stop_event.is_set():
            self.stop_event.clear()

            cap = cv2.VideoCapture(self.stream_url)
            try:
                cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            except Exception:
                pass

            if not cap.isOpened():
                with self.lock:
                    self.last_error = f"Unable to open stream: {self.stream_url}"
                cap.release()
                time.sleep(CAMERA_RECONNECT_SECONDS)
                continue

            with self.lock:
                self.last_error = None

            while not self.stop_event.is_set():
                loop_started = time.monotonic()
                ok, frame = cap.read()
                if not ok or frame is None:
                    with self.lock:
                        self.last_error = "Camera stream read failed."
                    break

                annotated, detection_count = self._annotate(frame)
                ok_jpeg, jpeg = cv2.imencode(".jpg", annotated, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
                if ok_jpeg:
                    with self.lock:
                        self.latest_jpeg = jpeg.tobytes()
                        self.latest_frame_time = datetime.now()
                        self.latest_detection_count = detection_count
                        self.last_error = None

                self._frames_seen += 1
                elapsed = time.monotonic() - self._last_fps_time
                if elapsed >= 1.0:
                    with self.lock:
                        self.latest_fps = self._frames_seen / elapsed
                    self._frames_seen = 0
                    self._last_fps_time = time.monotonic()

                processing_time = time.monotonic() - loop_started
                if frame_delay > processing_time:
                    time.sleep(frame_delay - processing_time)

            cap.release()


class CameraManager:
    """Keeps one CameraWorker per discovered camera device, in sync with
    whatever component2_mqtt_service currently knows about."""

    def __init__(self) -> None:
        self._workers: Dict[str, CameraWorker] = {}
        self._lock = threading.RLock()
        self._sync_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

    def sync(self) -> None:
        from app.component2.mqtt_service import get_devices_snapshot  

        devices = get_devices_snapshot()
        cameras = {d["device_id"]: d for d in devices.values() if d.get("device_type") == "camera" and d.get("stream_url")}

        with self._lock:
           
            for device_id, device in cameras.items():
                worker = self._workers.get(device_id)
                if worker is None:
                    worker = CameraWorker(device_id, device["stream_url"])
                    self._workers[device_id] = worker
                    worker.start()
                else:
                    worker.update_stream_url(device["stream_url"])

            
            for device_id in list(self._workers.keys()):
                if device_id not in cameras:
                    self._workers[device_id].stop()
                    del self._workers[device_id]

    def get_snapshot(self, device_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            worker = self._workers.get(device_id)
        return worker.get_snapshot() if worker else None

    def _sync_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.sync()
            except Exception as exc:
                print(f"[Component 2 / Camera] sync failed: {exc}")
            time.sleep(3)

    def start(self) -> None:
        if self._sync_thread and self._sync_thread.is_alive():
            return
        self._stop_event.clear()
        self._sync_thread = threading.Thread(target=self._sync_loop, name="camera-manager-sync", daemon=True)
        self._sync_thread.start()
        print("[Component 2 / Camera] Camera manager started.")

    def stop(self) -> None:
        self._stop_event.set()
        with self._lock:
            for worker in self._workers.values():
                worker.stop()
            self._workers.clear()
        print("[Component 2 / Camera] Camera manager stopped.")


camera_manager = CameraManager()
