"""
app/core/config.py — Central application configuration.

Every setting used anywhere in the backend is loaded from environment
variables (via a local .env file). Nothing is hardcoded here.

This is the ONLY place that reads os.getenv() for these values —
every other module imports the constants from here instead of calling
os.getenv() itself. That keeps configuration in one place and makes it
obvious what env vars the project needs (see .env.example).
"""

import os
from dotenv import load_dotenv

load_dotenv()


def _require(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(
            f"{name} is missing from your .env file. "
            f"Copy .env.example to .env and fill it in."
        )
    return value


def _optional(name: str, default: str = "") -> str:
    return os.getenv(name, default)


# ============================================================
# SUPABASE
# ============================================================

SUPABASE_URL = _require("SUPABASE_URL")
SUPABASE_PUBLISHABLE_KEY = _require("SUPABASE_PUBLISHABLE_KEY")
SUPABASE_SECRET_KEY = _require("SUPABASE_SECRET_KEY")


# ============================================================
# HIVEMQ / MQTT — ONE broker shared by every component
# ============================================================
#
# Components 1, 2 and 3 previously used separate/inconsistent
# broker credentials and topics. There is now exactly one set
# of broker credentials, and each component gets its own topic
# under the same broker so they can all coexist.

# ============================================================
# HIVEMQ / MQTT — Component 2 keeps the original shared broker;
# Components 1 and 3 each get their OWN HiveMQ Cloud cluster.
# ============================================================
#
# Component 2 (unchanged — still HIVEMQ_BROKER/PORT/USERNAME/PASSWORD)
HIVEMQ_BROKER = _require("HIVEMQ_BROKER")
HIVEMQ_PORT = int(_optional("HIVEMQ_PORT", "8883"))
HIVEMQ_USERNAME = _require("HIVEMQ_USERNAME")
HIVEMQ_PASSWORD = _require("HIVEMQ_PASSWORD")

# Component 1 — its own HiveMQ Cloud cluster
COMPONENT1_HIVEMQ_BROKER = _require("COMPONENT1_HIVEMQ_BROKER")
COMPONENT1_HIVEMQ_PORT = int(_optional("COMPONENT1_HIVEMQ_PORT", "8883"))
COMPONENT1_HIVEMQ_USERNAME = _require("COMPONENT1_HIVEMQ_USERNAME")
COMPONENT1_HIVEMQ_PASSWORD = _require("COMPONENT1_HIVEMQ_PASSWORD")

# Component 3 — its own HiveMQ Cloud cluster
COMPONENT3_HIVEMQ_BROKER = _require("COMPONENT3_HIVEMQ_BROKER")
COMPONENT3_HIVEMQ_PORT = int(_optional("COMPONENT3_HIVEMQ_PORT", "8883"))
COMPONENT3_HIVEMQ_USERNAME = _require("COMPONENT3_HIVEMQ_USERNAME")
COMPONENT3_HIVEMQ_PASSWORD = _require("COMPONENT3_HIVEMQ_PASSWORD")

MQTT_KEEPALIVE = int(_optional("MQTT_KEEPALIVE", "60"))
MQTT_QOS = int(_optional("MQTT_QOS", "0"))

# Per-component topics (all under the same broker).
COMPONENT1_TOPIC = _optional("COMPONENT1_TOPIC", "eldercare/component1/imu")
COMPONENT2_TOPIC = _optional("COMPONENT2_TOPIC", "eldercare/component2/#")
COMPONENT3_TOPIC = _optional("COMPONENT3_TOPIC", "eldercare/component3/vitals")

# Device considered OFFLINE if nothing heard for this many seconds.
DEVICE_OFFLINE_TIMEOUT = float(_optional("DEVICE_OFFLINE_TIMEOUT", "15"))

# ============================================================
# KNOWN LIMITATION: single elder per deployment (MVP)
# ============================================================
# The MQTT sensor payloads (ESP32 -> HiveMQ) don't currently carry an
# elder_id — there's one physical sensor rig per deployment, so the
# automatic Component 1 -> Component 4 flow (message_router.py) needs
# to know WHICH elder's alert_history row to write to. Set this to a
# real elder's id (from `select id from elders`) once one exists, so
# real sensor events actually show up in that elder's History screen.
# Multi-elder deployments need elder_id added to the MQTT topic/payload
# itself — a bigger change, tracked as a future enhancement, not done
# here.
DEFAULT_ELDER_ID = _optional("DEFAULT_ELDER_ID", "")

# ============================================================
# FIX (see conversation notes): "unknown" location gap
# ============================================================
# When no Component 2 device has published telemetry yet,
# component2_context.get_context() returns location=None, and
# pipeline.py previously fell back to the literal string "unknown" —
# a value never seen in Component 4's training data, risking a
# silent misclassification. This gives a real, in-distribution
# fallback location instead. Set this to wherever the elder spends
# most of their time, or the room your test sensor rig is closest to.
DEFAULT_LOCATION = _optional("DEFAULT_LOCATION", "Bedroom")


# ============================================================
# YOLO (Component 2 camera hazard detection)
# ============================================================

YOLO_MODEL_PATH = _optional("YOLO_MODEL", "yolov8n.pt")
YOLO_CONFIDENCE = float(_optional("YOLO_CONFIDENCE", "0.35"))
YOLO_IOU = float(_optional("YOLO_IOU", "0.45"))
YOLO_IMAGE_SIZE = int(_optional("YOLO_IMAGE_SIZE", "640"))
YOLO_DEVICE = _optional("YOLO_DEVICE", "").strip() or None

# Set to "false" in .env to disable camera/YOLO entirely (e.g. for a
# demo machine with no GPU and no cameras wired up yet).
CAMERA_ENABLED = _optional("CAMERA_ENABLED", "true").lower() == "true"
CAMERA_RECONNECT_SECONDS = float(_optional("CAMERA_RECONNECT_SECONDS", "3"))
CAMERA_TARGET_FPS = float(_optional("CAMERA_TARGET_FPS", "10"))


# ============================================================
# APPLICATION
# ============================================================

APP_ENV = _optional("APP_ENV", "development")
CORS_ALLOW_ORIGINS = _optional("CORS_ALLOW_ORIGINS", "*").split(",")
