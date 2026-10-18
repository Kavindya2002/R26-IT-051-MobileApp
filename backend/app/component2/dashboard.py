"""
app/component2/dashboard.py — OPTIONAL visualization dashboard.

Run separately with:  streamlit run app/component2/dashboard.py

IMPORTANT DESIGN NOTE:
This dashboard does NOT connect to MQTT itself and does NOT hold
its own device state. It only calls the FastAPI backend's HTTP
endpoints (/component2/devices, /component2/latest). This is the
fix for the original project's cross-process bug: there is now
exactly ONE process (the FastAPI backend) that owns MQTT and
device state. Every other view — this dashboard, Flutter, curl —
reads the same live data through the same API.

Set BACKEND_URL below (or via the BACKEND_URL env var) to point
at wherever you're running `uvicorn app.main:app`.
"""

import os
import time

import requests
import streamlit as st

BACKEND_URL = os.getenv("BACKEND_URL", "http://localhost:8000")

st.set_page_config(page_title="ElderCare — Component 2", page_icon="🏠", layout="wide")
st.title("🏠 Component 2 — Environmental Monitoring")
st.caption(f"Reading live data from {BACKEND_URL} (FastAPI backend owns MQTT)")


def fetch(path: str):
    try:
        response = requests.get(f"{BACKEND_URL}{path}", timeout=5)
        response.raise_for_status()
        return response.json()
    except Exception as exc:
        st.error(f"Could not reach backend at {BACKEND_URL}{path}: {exc}")
        return None


health = fetch("/component2/health")
if health:
    if health.get("mqtt_connected"):
        st.success("🟢 Backend connected to HiveMQ")
    else:
        st.error("🔴 Backend MQTT connection unavailable")

devices_response = fetch("/component2/devices")

if devices_response and devices_response.get("results"):
    for device in devices_response["results"]:
        with st.container(border=True):
            cols = st.columns(6)
            cols[0].metric("Zone", device.get("zone") or "-")
            cols[1].metric("Status", device.get("device_status") or "-")
            temp = device.get("temperature")
            cols[2].metric("Temperature", f"{temp:.1f} °C" if isinstance(temp, (int, float)) else "-")
            cols[3].metric("Motion", "YES" if device.get("motion") else "NO")
            cols[4].metric("Risk Score", device.get("risk_score", "-"))
            level = device.get("risk_level", "-")
            color = {"LOW": "🟢", "MEDIUM": "🟡", "HIGH": "🔴"}.get(level, "")
            cols[5].metric("Risk Level", f"{color} {level}")
else:
    st.info("No devices discovered yet. Waiting for MQTT telemetry...")

time.sleep(2)
st.rerun()
