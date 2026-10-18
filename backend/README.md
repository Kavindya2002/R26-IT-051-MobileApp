# Elder Care Backend — Clean Rebuild

This is a restructured version of the AegisCare / Elder Care project,
fixing the architectural problems found during code review:

| Problem in the original project | Fix in this version |
|---|---|
| Component 1 & 3 MQTT pipelines were never started by the combined backend | `app/main.py`'s `lifespan()` starts **all three** MQTT services on boot |
| Component 2's Streamlit dashboard and FastAPI backend ran as separate processes and couldn't share state | Component 2's MQTT client now runs **inside** the FastAPI process; the dashboard (optional) reads via HTTP |
| Component 1's real MQTT prediction was never saved for `/component1/latest` | `message_router.py` now calls `store_prediction()` |
| A detected fall never automatically triggered a Component 4 alert | `message_router.py` now calls the Component 1→4 pipeline automatically |
| `result.py` / `prediction.py` / `alert.py` duplicate routers per component | Exactly **one** router per component |
| Two different, inconsistent guidance text files | One `guidance_steps.py`, one `guidance_service.py` gating rule |
| `UserRiskProfile` (age/previous_falls/assistive_device) had no database table | New `app/elders` module + `elders` table (SQL below) |
| Hardcoded Supabase credentials/placeholder key | Everything loaded from `.env`, validated at startup |
| `risk_model.pkl` trained but never used; risk was rule-based only | Kept as-is, but now **documented explicitly** as a deliberate design choice in code comments — see `app/component1/ml/fall_detection.py` |

---

## Folder structure

```
app/
├── main.py                    # Single entrypoint — starts everything
├── core/
│   ├── config.py               # ALL environment variables, in one place
│   └── supabase.py
├── component1/                 # Fall Detection
│   ├── ml/
│   │   ├── fall_detection.py   # Dataset generation, training, inference
│   │   └── model_loader.py     # Loads pretrained .pkl or trains fresh
│   ├── models/                 # Your trained .pkl files go here
│   └── api/router.py           # /component1/latest, /health
├── component2/                 # Environmental Monitoring
│   ├── mqtt_service.py         # Owns the MQTT client (in-process)
│   ├── dashboard.py            # OPTIONAL Streamlit view, reads via HTTP
│   └── api/router.py           # /component2/latest, /devices, /cameras, /cameras/{id}/snapshot, /devices/{id}/buzzer, /health
│   └── camera_service.py       # ESP32-CAM + YOLO workers (ported from the original Streamlit main.py)
├── component3/                 # PPG / BP Monitoring
│   ├── ml/ppg_processor.py     # The ONE signal-processing implementation
│   ├── mqtt_service.py         # Owns the MQTT client (in-process)
│   ├── models/                 # bp_model.joblib goes here
│   └── api/router.py           # /component3/latest, /health
├── component4/                 # Alerts & Guidance
│   ├── model_loader.py
│   ├── prediction_service.py
│   ├── schemas.py
│   ├── models/                 # xgboost_model.pkl, label_encoder.pkl, training_columns.pkl
│   ├── guidance/
│   │   ├── guidance_steps.py       # Single source of truth for guidance text
│   │   ├── guidance_controller.py
│   │   ├── guidance_service.py     # The one gating rule (LOW + FallDetected)
│   │   └── feedback/                # Sensor-feedback validation (documented as WIP)
│   └── api/router.py           # /component4/predict, /model-info, /health
├── integration/
│   ├── component1_adapter.py
│   ├── component1_runtime.py
│   ├── component2_context.py
│   ├── pipeline.py              # Component1 -> Component4, called automatically
│   ├── router.py                # Manual trigger endpoint, for testing/demos
│   └── mqtt/
│       ├── sensor_parser.py     # ESP32 field names -> Component 1 field names
│       ├── message_router.py    # THE central wiring: predict, store, guide, alert
│       └── subscriber.py        # Component 1's MQTT client (in-process)
├── users/                       # Auth (unchanged — this code was already correct)
└── elders/                      # NEW — where age/previous_falls/assistive_device live
```

---

## Setup

```bash
python -m venv venv
source venv/bin/activate        # Windows: venv\Scripts\activate
pip install -r requirements.txt

cp .env.example .env
# now edit .env with your real Supabase + HiveMQ credentials
```

**IMPORTANT — regenerate your credentials.** If you pasted real
Supabase/HiveMQ keys into any chat or committed them to git at any
point, treat them as compromised: regenerate the Supabase secret key
and change the HiveMQ passwords before using them here.

### Run the backend

```bash
uvicorn app.main:app --reload
```

Open `http://localhost:8000/docs` for interactive API docs, and
`http://localhost:8000/health` to see which components' MQTT
connections are actually live.

### Run the optional Component 2 dashboard (separate terminal)

```bash
streamlit run app/component2/dashboard.py
```

This reads from the FastAPI backend over HTTP — it does not open
its own MQTT connection.

### Point your ESP32 devices at these MQTT topics (same broker)

```
Component 1 (IMU):        eldercare/component1/imu
Component 2 (env sensors): eldercare/component2/<device_id>/telemetry
                            eldercare/component2/<device_id>/discovery
                            eldercare/component2/<device_id>/status
Component 3 (PPG):        eldercare/component3/vitals
```

Change these in `.env` (`COMPONENT1_TOPIC`, etc.) if your firmware
already uses different topic names — just make sure firmware and
`.env` agree.

---

## New database table — `elders`

Component 4 requires `age`, `previous_falls`, and `assistive_device`
per elder, which had no table in the original project. Run this in
your Supabase SQL editor:

```sql
create table elders (
    id uuid primary key default gen_random_uuid(),
    caregiver_id uuid references users(id) not null,
    name text not null,
    age int not null,
    previous_falls int not null default 0,
    assistive_device text not null default 'none',
    address text,
    created_at timestamptz not null default now()
);

-- Optional: row-level security so caregivers only see their own elders
alter table elders enable row level security;

create policy "Caregivers manage their own elders"
    on elders
    for all
    using (caregiver_id = auth.uid());
```

Until you register real elder profiles, `app/integration/pipeline.py`
falls back to default values (age 75, 0 previous falls, no assistive
device) only when no `elder_id` is supplied. Pass a real `elder_id`
(from the manual `/integration/...` call, the `/elders/{id}/escalate`
endpoint, or `DEFAULT_ELDER_ID` in `.env` for the automatic MQTT flow)
and it looks up the real profile via `ElderService.get_risk_profile()`.

---

## New database table — `alerts`

Closes the "Component 4 is stateless" gap — every alert decision
(manual, automatic via MQTT, or escalated) is now written here so a
History screen has real data to read from `GET /elders/{id}/alerts`.

```sql
create table alerts (
    id uuid primary key default gen_random_uuid(),
    elder_id uuid references elders(id) not null,
    fall_type text,
    risk_level text,
    alert_type text,        -- Voice Alert / Caregiver Alert / Emergency Alert
    confidence float,
    location text,
    guidance_completed boolean not null default false,
    escalated boolean not null default false,
    created_at timestamptz not null default now()
);

alter table alerts enable row level security;

create policy "Caregivers see alerts for their own elders"
    on alerts
    for select
    using (
        elder_id in (select id from elders where caregiver_id = auth.uid())
    );
```

---

## New database table — `emergency_contacts`

Closes the "Emergency Person can't see any elder's data" architectural
gap. A caregiver invites an already-registered `EMERGENCY_PERSON`
account (by email) via `POST /elders/{id}/emergency-contacts`; that
person can then call `GET /emergency-contacts/my-elders` to see which
elder(s) they're linked to.

```sql
create table emergency_contacts (
    id uuid primary key default gen_random_uuid(),
    emergency_person_id uuid references users(id) not null,
    elder_id uuid references elders(id) not null,
    created_at timestamptz not null default now(),
    unique (emergency_person_id, elder_id)
);

alter table emergency_contacts enable row level security;

create policy "Caregivers manage contacts for their own elders"
    on emergency_contacts
    for all
    using (
        elder_id in (select id from elders where caregiver_id = auth.uid())
    );

create policy "Emergency contacts see their own links"
    on emergency_contacts
    for select
    using (emergency_person_id = auth.uid());
```

---

## What's still genuinely open (be honest about these in your report)

1. **`risk_model.pkl` is trained but not used for the live decision** —
   `risk_level` comes from interpretable rule-based thresholds on raw
   acceleration (see `analyze_sequence()` in `fall_detection.py`).
   This is now a documented design choice, not a silent bug — but you
   should still explain *why* you chose rules over the trained model
   in your report (interpretability/debuggability in a safety-critical
   system is a reasonable justification).
2. **Component 4's BP-style overfitting concern doesn't apply here**,
   but the earlier finding about `bp_model.joblib` (Component 3) being
   trained on data that looks synthetic (tight per-activity BP
   clustering) still applies — retrain on real measured data before
   claiming real-world accuracy.
3. **Sensor-feedback-confirms-guidance-step is still a stub** —
   `step_validator.py` intentionally does not mark steps "completed"
   yet, because real movement thresholds haven't been calibrated
   against actual hardware. This is disclosed in the file's own
   docstring; don't present it as a finished feature in your viva.
4. **Model version pinning** — `requirements.txt` pins scikit-learn
   1.6.1 to match what your `.pkl` files were trained with. If you
   retrain models with a different scikit-learn/xgboost version,
   update the pins to match, and re-test loading before your demo.
5. **Camera/YOLO hazard detection** is stubbed out (`CAMERA_ENABLED=false`
   by default) — the original dual-ESP32-CAM + YOLOv8 pipeline was
   real but entangled with the broken Streamlit architecture. Wire it
   back in as a background task inside `component2/mqtt_service.py`
   if you need it for your demo; keep it out of the request path.

---

## Testing without real ESP32 hardware

You can exercise the whole pipeline manually:

```bash
curl -X POST http://localhost:8000/integration/component1-to-component4 \
  -H "Content-Type: application/json" \
  -d '{
    "component1": {"fall_detected": true, "fall_type": "fall_forward", "risk_level": "LOW", "movement": "Standing", "confidence": 91.2},
    "component2": {"location": "Bedroom", "time": "14:32"},
    "user": {"age": 78, "previous_falls": 2, "assistive_device": "walker"}
  }'
```

This exercises the same `elder_care_pipeline` that the real MQTT
flow calls automatically — useful for a viva demo if hardware isn't
available in the room.
