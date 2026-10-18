"""
app/realtime/websocket_manager.py

THE FIX for the "Flutter app polls every 5 seconds" gap. This adds a
plain FastAPI WebSocket channel — Option B from the priority list
(a Supabase Realtime subscription, Option A, is the other valid
choice and needs no backend code at all if you go that route
instead; this module is for teams that want to stay entirely within
the existing FastAPI/MQTT stack).

Design: one WebSocket connection per elder_id. When AlertService
creates a new alert row (see app/alerts/service.py), it broadcasts
that alert to every client currently connected for that elder. The
Flutter app connects once per elder dashboard screen and simply
listens — no polling needed for alerts specifically (Component
1/2/3 `/latest` polling is a separate, smaller concern not solved
by this).

Broadcasting from inside AlertService (which is NOT itself an async
function — it's called from both sync MQTT callback code and async
FastAPI routes) uses `broadcast_sync`, which schedules the actual
async send onto the running event loop instead of trying to await
directly from sync code.
"""

import asyncio
import json
import threading
from typing import Any, Dict, List, Optional

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: Dict[str, List[WebSocket]] = {}
        self._lock = threading.RLock()
        self._loop: Optional[asyncio.AbstractEventLoop] = None

    def set_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        """Called once from main.py's lifespan so broadcast_sync (which
        may be invoked from a non-async MQTT callback thread) knows
        which event loop actually owns the WebSocket connections."""
        self._loop = loop

    async def connect(self, elder_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        with self._lock:
            self._connections.setdefault(elder_id, []).append(websocket)

    def disconnect(self, elder_id: str, websocket: WebSocket) -> None:
        with self._lock:
            if elder_id in self._connections and websocket in self._connections[elder_id]:
                self._connections[elder_id].remove(websocket)
            if elder_id in self._connections and not self._connections[elder_id]:
                del self._connections[elder_id]

    async def broadcast(self, elder_id: str, message: Dict[str, Any]) -> None:
        with self._lock:
            sockets = list(self._connections.get(elder_id, []))
        payload = json.dumps(message, default=str)
        for ws in sockets:
            try:
                await ws.send_text(payload)
            except Exception:
                self.disconnect(elder_id, ws)

    def broadcast_sync(self, elder_id: str, message: Dict[str, Any]) -> None:
        """Safe to call from sync code (e.g. an MQTT on_message callback
        running on paho-mqtt's own thread) or from async code alike."""
        if self._loop is None:
            return  # no event loop registered yet (e.g. during tests) — drop silently
        asyncio.run_coroutine_threadsafe(self.broadcast(elder_id, message), self._loop)


connection_manager = ConnectionManager()
