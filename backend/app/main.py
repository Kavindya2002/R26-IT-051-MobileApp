"""
app/main.py — Elder Care Backend entrypoint.

Run with:
    uvicorn app.main:app --reload

THE CENTRAL FIX FROM THE ORIGINAL PROJECT:
The old combined main.py only started Component 4's model loader
and Component 2's lightweight context bridge in its lifespan hook.
Component 1's MQTT subscriber and Component 3's MQTT service were
fully built and worked correctly in isolation, but were never
started here — grep for "subscriber" or "component3_mqtt" in the
original file returned zero matches. That meant no real sensor
data ever reached this backend for two of your four components.

All THREE MQTT-based components now start here, every time.
"""

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from app.alerts.router import router as alerts_router
from app.events.router import router as events_router
from app.component1.api.router import router as component1_router
from app.component1.ml.model_loader import component1_loader
from app.component2.api.router import router as component2_router
from app.component2.camera_service import camera_manager, yolo_status
from app.component2.mqtt_service import component2_mqtt_service, is_mqtt_connected as component2_mqtt_connected
from app.component3.api.router import router as component3_router
from app.component3.mqtt_service import component3_mqtt_service, is_mqtt_connected as component3_mqtt_connected
from app.component4.api.router import router as component4_router
from app.component4.model_loader import component4_loader
from app.core.config import CAMERA_ENABLED, CORS_ALLOW_ORIGINS
from app.elders.router import router as elders_router
from app.emergency_contacts.router import router as emergency_contacts_router
from app.integration.mqtt.subscriber import component1_subscriber
from app.integration.router import router as integration_router
from app.realtime.websocket_manager import connection_manager
from app.users.router import router as users_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    print("")
    print("=" * 70)
    print("ELDER CARE BACKEND — STARTING")
    print("=" * 70)

    # WebSocket broadcasts (app/alerts/service.py) can be triggered
    # from non-async code (e.g. paho-mqtt's callback thread), so the
    # manager needs a handle on the actual running event loop.
    connection_manager.set_loop(asyncio.get_running_loop())

    # --------------------------------------------------------
    # Component 1 — loads/trains models, then starts its MQTT
    # subscriber so real IMU data actually reaches run_system().
    # --------------------------------------------------------
    print("\n[1/4] Component 1: loading model + starting MQTT subscriber...")
    try:
        component1_loader.load()
        component1_subscriber.start()
    except Exception as exc:
        print(f"Component 1 startup failed (continuing without it): {exc}")

    # --------------------------------------------------------
    # Component 2 — starts its own MQTT client in THIS process.
    # --------------------------------------------------------
    print("\n[2/4] Component 2: starting MQTT service...")
    try:
        component2_mqtt_service.start()
        if CAMERA_ENABLED:
            camera_manager.start()
        else:
            print("Component 2: camera/YOLO disabled via CAMERA_ENABLED=false.")
    except Exception as exc:
        print(f"Component 2 startup failed (continuing without it): {exc}")

    # --------------------------------------------------------
    # Component 3 — starts its own MQTT client in THIS process.
    # --------------------------------------------------------
    print("\n[3/4] Component 3: starting MQTT service...")
    try:
        component3_mqtt_service.start()
    except Exception as exc:
        print(f"Component 3 startup failed (continuing without it): {exc}")

    # --------------------------------------------------------
    # Component 4 — loads the XGBoost alert model.
    # --------------------------------------------------------
    print("\n[4/4] Component 4: loading model...")
    try:
        component4_loader.load()
    except Exception as exc:
        print(f"Component 4 model failed to load (continuing without it): {exc}")

    print("")
    print("=" * 70)
    print("ELDER CARE BACKEND READY")
    print("=" * 70)

    try:
        yield
    finally:
        print("\nShutting down MQTT services...")
        component1_subscriber.stop()
        component2_mqtt_service.stop()
        camera_manager.stop()
        component3_mqtt_service.stop()


app = FastAPI(
    title="Elder Care Backend",
    description="Integrated backend for Components 1-4: fall detection, "
                 "environmental monitoring, PPG/BP monitoring, and alerting.",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ALLOW_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(component1_router)
app.include_router(component2_router)
app.include_router(component3_router)
app.include_router(component4_router)
app.include_router(integration_router)
app.include_router(users_router)
app.include_router(elders_router)
app.include_router(alerts_router)
app.include_router(events_router)
app.include_router(emergency_contacts_router)


@app.websocket("/ws/elder/{elder_id}")
async def elder_alert_stream(websocket: WebSocket, elder_id: str):
    """Real-time alert push for one elder. The Flutter app connects
    here once per dashboard screen instead of polling for alerts.
    NOTE: this stream carries ALERT events only (see
    AlertService.create's broadcast_sync call) — Component 1/2/3
    /latest data is a separate concern, still polled for now."""
    await connection_manager.connect(elder_id, websocket)
    try:
        while True:
            # This endpoint is push-only; we still need to await
            # something so the connection stays open and disconnects
            # are detected promptly.
            await websocket.receive_text()
    except WebSocketDisconnect:
        connection_manager.disconnect(elder_id, websocket)


@app.get("/")
def root():
    return {
        "status": "success",
        "service": "Elder Care Backend",
        "version": "2.0.0",
        "components": {
            "component1": "available (MQTT-driven fall detection)",
            "component2": "available (MQTT-driven environmental monitoring)",
            "component3": "available (MQTT-driven PPG/BP monitoring)",
            "component4": "available (automatic alert on fall detection + manual /integration endpoint)",
        },
    }


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "component1": {
            "mqtt_connected": component1_subscriber.connected,
            "model_loaded": component1_loader.trained is not None,
        },
        "component2": {
            "mqtt_connected": component2_mqtt_connected(),
            "camera": yolo_status(),
        },
        "component3": {
            "mqtt_connected": component3_mqtt_connected(),
        },
        "component4": {
            "model_loaded": component4_loader.xgboost_model is not None,
            "label_encoder_loaded": component4_loader.label_encoder is not None,
            "training_columns_loaded": component4_loader.training_columns is not None,
        },
    }
