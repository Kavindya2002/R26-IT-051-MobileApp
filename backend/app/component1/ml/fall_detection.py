"""
app/component1/ml/fall_detection.py — Component 1 core ML pipeline.

Responsibilities:
    - Synthetic dataset generation (for bootstrapping training)
    - Model training (activity / fall-type / risk classifiers)
    - Real-time inference on a single IMU reading
    - Sequence-based rule risk analysis
    - Explainable output

NOTE ON HONESTY FOR YOUR REPORT:
    generate_dataset() below produces SYNTHETIC data from
    hand-picked distributions. If your final dataset is still
    synthetic, say so explicitly in your report rather than
    presenting it as measured sensor data.
"""

from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score
from sklearn.model_selection import train_test_split
from sklearn.neighbors import KNeighborsClassifier
from sklearn.preprocessing import LabelEncoder, StandardScaler
from sklearn.tree import DecisionTreeClassifier

# ============================================================
# FEATURE COLUMNS
# ============================================================

FEATURE_COLS = [
    "accel_x", "accel_y", "accel_z",
    "gyro_x", "gyro_y", "gyro_z",
    "acc_magnitude", "gyro_magnitude",
    "mean_acceleration", "std_acceleration",
    "variance_acceleration", "signal_magnitude_area",
    "tilt_angle_x", "tilt_angle_y",
]

ACTIVITIES = ["Sitting", "Standing", "Walking"]
FALL_TYPES = ["Forward Fall", "Backward Fall", "Side Fall Right", "Side Fall Left"]


# ============================================================
# DERIVED FEATURES (shared by dataset generation AND inference,
# so the two paths can never silently drift apart)
# ============================================================

def _derive_features(ax: float, ay: float, az: float,
                      gx: float, gy: float, gz: float) -> Dict[str, float]:
    acc_mag = float(np.sqrt(ax ** 2 + ay ** 2 + az ** 2))
    gyro_mag = float(np.sqrt(gx ** 2 + gy ** 2 + gz ** 2))
    sma = float((abs(ax) + abs(ay) + abs(az)) / 3)
    variance = float(np.var([ax, ay, az]))
    std_acc = float(np.std([ax, ay, az]))
    mean_acc = float(np.mean([ax, ay, az]))
    tilt_x = float(np.degrees(np.arctan2(ax, np.sqrt(ay ** 2 + az ** 2))))
    tilt_y = float(np.degrees(np.arctan2(ay, np.sqrt(ax ** 2 + az ** 2))))

    return {
        "accel_x": ax, "accel_y": ay, "accel_z": az,
        "gyro_x": gx, "gyro_y": gy, "gyro_z": gz,
        "acc_magnitude": acc_mag, "gyro_magnitude": gyro_mag,
        "mean_acceleration": mean_acc, "std_acceleration": std_acc,
        "variance_acceleration": variance, "signal_magnitude_area": sma,
        "tilt_angle_x": tilt_x, "tilt_angle_y": tilt_y,
    }


# ============================================================
# SYNTHETIC DATASET GENERATION
# ============================================================

def generate_dataset(n: int = 10000, seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    rows: List[Dict[str, Any]] = []

    for _ in range(n):
        activity = rng.choice(ACTIVITIES, p=[0.30, 0.35, 0.35])

        if activity == "Sitting":
            ax, ay, az = rng.normal(0.0, 0.05), rng.normal(0.0, 0.05), rng.normal(9.80, 0.08)
            gx, gy, gz = rng.normal(0, 0.2), rng.normal(0, 0.2), rng.normal(0, 0.2)
            stability, risk, fall_type, fall_detected = "Stable", "LOW", "No Fall", 0

        elif activity == "Standing":
            state = rng.choice(["stable", "unstable", "fall"], p=[0.80, 0.15, 0.05])
            if state == "stable":
                ax, ay, az = rng.normal(0.0, 0.10), rng.normal(0.0, 0.10), rng.normal(9.80, 0.12)
                gx, gy, gz = rng.normal(0, 0.6), rng.normal(0, 0.6), rng.normal(0, 0.3)
                stability, risk, fall_type, fall_detected = "Stable", "LOW", "No Fall", 0
            elif state == "unstable":
                ax, ay, az = rng.normal(0.0, 1.5), rng.normal(0.0, 1.5), rng.normal(9.3, 0.4)
                gx, gy, gz = rng.normal(0, 5), rng.normal(0, 5), rng.normal(0, 2.5)
                stability, risk, fall_type, fall_detected = "Unstable", "HIGH", "No Fall", 0
            else:
                fall_type = rng.choice(FALL_TYPES)
                ax = rng.normal(5.5 if fall_type == "Forward Fall" else -5.5 if fall_type == "Backward Fall" else 0.2, 0.5)
                ay = rng.normal(5.5 if fall_type == "Side Fall Right" else -5.5 if fall_type == "Side Fall Left" else 0.2, 0.5)
                az = rng.normal(2.5, 0.8)
                gx, gy, gz = rng.normal(0, 10), rng.normal(0, 10), rng.normal(0, 7)
                stability, risk, fall_detected = "Unstable", "CRITICAL", 1

        else:  # Walking
            state = rng.choice(["stable", "irregular", "fall"], p=[0.82, 0.13, 0.05])
            if state == "stable":
                ax, ay, az = rng.normal(0.5, 0.35), rng.normal(0.1, 0.25), rng.normal(9.5, 0.35)
                gx, gy, gz = rng.normal(0, 3.5), rng.normal(0, 3.5), rng.normal(0, 2.0)
                stability, risk, fall_type, fall_detected = "Stable", "LOW", "No Fall", 0
            elif state == "irregular":
                ax, ay, az = rng.normal(0.5, 2.0), rng.normal(0.1, 2.0), rng.normal(9.0, 0.7)
                gx, gy, gz = rng.normal(0, 6), rng.normal(0, 6), rng.normal(0, 4)
                stability, risk, fall_type, fall_detected = "Unstable", "MEDIUM", "No Fall", 0
            else:
                fall_type = rng.choice(FALL_TYPES)
                ax = rng.normal(6.0 if fall_type == "Forward Fall" else -6.0 if fall_type == "Backward Fall" else 0.2, 0.5)
                ay = rng.normal(6.0 if fall_type == "Side Fall Right" else -6.0 if fall_type == "Side Fall Left" else 0.2, 0.5)
                az = rng.normal(2.0, 1.0)
                gx, gy, gz = rng.normal(0, 11), rng.normal(0, 11), rng.normal(0, 8)
                stability, risk, fall_detected = "Unstable", "CRITICAL", 1

        features = _derive_features(ax, ay, az, gx, gy, gz)
        features.update({
            "activity": activity,
            "stability": stability,
            "risk_level": risk,
            "fall_detected": fall_detected,
            "fall_type": fall_type,
        })
        rows.append({k: round(v, 4) if isinstance(v, float) else v for k, v in features.items()})

    return pd.DataFrame(rows)


# ============================================================
# TRAINING
# ============================================================

def train_models(df: pd.DataFrame) -> Dict[str, Any]:
    df = df.dropna().copy()

    scaler = StandardScaler()
    df_scaled = df.copy()
    df_scaled[FEATURE_COLS] = scaler.fit_transform(df[FEATURE_COLS])
    X = df_scaled[FEATURE_COLS].copy()

    le_activity, le_fall, le_risk = LabelEncoder(), LabelEncoder(), LabelEncoder()
    y_activity = le_activity.fit_transform(df["activity"])
    y_fall = le_fall.fit_transform(df["fall_type"])
    y_risk = le_risk.fit_transform(df["risk_level"])

    X_train, X_test, y_act_train, y_act_test = train_test_split(
        X, y_activity, test_size=0.20, random_state=42, stratify=y_activity
    )
    _, _, y_fall_train, y_fall_test = train_test_split(
        X, y_fall, test_size=0.20, random_state=42, stratify=y_activity
    )
    _, _, y_risk_train, y_risk_test = train_test_split(
        X, y_risk, test_size=0.20, random_state=42, stratify=y_activity
    )

    ml_models = {
        "Decision Tree": DecisionTreeClassifier(max_depth=15, min_samples_split=5, random_state=42),
        "Random Forest": RandomForestClassifier(n_estimators=200, max_depth=20, random_state=42, n_jobs=-1),
        "KNN": KNeighborsClassifier(n_neighbors=3, metric="euclidean"),
    }

    results, trained_models = {}, {}
    for name, model in ml_models.items():
        model.fit(X_train, y_act_train)
        y_pred = model.predict(X_test)
        results[name] = {
            "Accuracy": accuracy_score(y_act_test, y_pred),
            "Precision": precision_score(y_act_test, y_pred, average="weighted", zero_division=0),
            "Recall": recall_score(y_act_test, y_pred, average="weighted", zero_division=0),
            "F1-Score": f1_score(y_act_test, y_pred, average="weighted", zero_division=0),
        }
        trained_models[name] = model

    best_model_name = max(results, key=lambda n: results[n]["Accuracy"])

    fall_model = RandomForestClassifier(n_estimators=100, max_depth=15, min_samples_leaf=3, random_state=42, n_jobs=-1)
    fall_model.fit(X_train, y_fall_train)

    risk_model = RandomForestClassifier(n_estimators=100, max_depth=15, min_samples_leaf=3, random_state=42, n_jobs=-1)
    risk_model.fit(X_train, y_risk_train)

    return {
        "scaler": scaler,
        "le_activity": le_activity,
        "le_fall": le_fall,
        "le_risk": le_risk,
        "best_model": trained_models[best_model_name],
        "best_model_name": best_model_name,
        "fall_model": fall_model,
        "risk_model": risk_model,
        "results": results,
    }


# ============================================================
# STABILITY (rule-based, gravity-aware)
# ============================================================

def get_stability(ax: float, ay: float, az: float) -> str:
    horizontal_magnitude = np.sqrt(ax ** 2 + ay ** 2)
    gravity_deviation = abs(abs(az) - 9.81)
    if horizontal_magnitude > 2.0 or gravity_deviation > 1.5:
        return "Unstable"
    return "Stable"


# ============================================================
# SEQUENCE-BASED RISK (rule layer, on top of the ML fall_type)
# ============================================================
#
# REDESIGNED (see conversation notes — "Two-Branch System"):
#
#   fall_detected = False  ->  PRE-FALL WARNING branch.
#       risk_level (LOW/MEDIUM/HIGH) describes an instability PATTERN
#       that hasn't produced an actual impact yet (e.g. wobbling when
#       standing up). Caregiver gets a status update; no alert routing.
#
#   fall_detected = True   ->  A REAL IMPACT crossed the base
#       threshold (FALL_MAGNITUDE_THRESHOLD). risk_level here is no
#       longer a pattern label — it's a SEVERITY GRADE of the fall
#       itself, banded by impact magnitude (FALL_SEVERITY_BANDS).
#       Component 4 always runs for these, and its OWN model output
#       (alert_type: Voice/Caregiver/Emergency Alert) decides who
#       gets notified — this rule layer does not hardcode that part.
#
# This replaces the old design where fall_detected could ONLY ever be
# True when risk_level == "CRITICAL" — a combination that made
# LOW-risk fall guidance (fall_detected=True, risk_level=LOW)
# mathematically impossible from real sensor data. Severity bands
# below are defaults, not measured from a specific dataset — revisit
# them if your project's requirements specify different thresholds.

FALL_MAGNITUDE_THRESHOLD = 3.0  # m/s^2 — the base "this is a fall, not just wobbling" gate

FALL_SEVERITY_BANDS = [
    (4.5, "LOW"),       # magnitude < 4.5  -> LOW    (mild stumble, self-recoverable)
    (6.0, "MEDIUM"),    # magnitude < 6.0  -> MEDIUM (moderate fall)
    (8.0, "HIGH"),      # magnitude < 8.0  -> HIGH   (serious fall)
    # magnitude >= 8.0 -> CRITICAL (severe fall)
]


def _classify_fall_severity(magnitude: float) -> str:
    for upper_bound, label in FALL_SEVERITY_BANDS:
        if magnitude < upper_bound:
            return label
    return "CRITICAL"


def _fall_direction_label(ax_raw: float, ay_raw: float) -> str:
    """Purely descriptive (used in the explanation text) — fall_type
    for guidance-content selection still comes from the independent
    ML classifier (`fall_model`) in run_system(), not from here."""
    if abs(ax_raw) >= abs(ay_raw):
        return "Forward fall" if ax_raw > 0 else "Backward fall"
    return "Side fall (right)" if ay_raw > 0 else "Side fall (left)"


def _fall_direction_to_type(ax_raw: float, ay_raw: float) -> str:
    """Same rule-based direction logic as _fall_direction_label(), but
    returned in the EXACT label spelling used by FALL_TYPES / le_fall
    ("Forward Fall", "Backward Fall", "Side Fall Right", "Side Fall
    Left") instead of the free-text explanation phrasing. Used ONLY as
    a fallback for fall_type — see run_system()'s consistency check
    below — never as a replacement for the ML classifier itself."""
    if abs(ax_raw) >= abs(ay_raw):
        return "Forward Fall" if ax_raw > 0 else "Backward Fall"
    return "Side Fall Right" if ay_raw > 0 else "Side Fall Left"


# ============================================================
# FIX (stationary-device / "device left on a table" false positive)
# ------------------------------------------------------------
# Root cause: get_stability() above flips to "Unstable" from a SINGLE
# noisy reading whenever horizontal_magnitude or gravity_deviation
# cross a fixed threshold. A device resting on a hard, flat surface
# can pick up small vibration/knock noise bursts that cross those
# thresholds for one sample even though the device never actually
# moved or changed orientation — and the old analyze_sequence() only
# needed that ONE sample (stability=="Unstable" + activity in
# [Standing, Walking] + impact_magnitude > FALL_MAGNITUDE_THRESHOLD)
# to report fall_detected=True.
#
# A REAL fall is physically different from surface noise in three
# ways that a flat, motionless device cannot fake at the same time:
#   1. The device's actual ORIENTATION changes (a real fall tips the
#      device over; sitting flat on a table does not).
#   2. A real fall involves genuine ROTATIONAL motion (gyroscope),
#      not just an accelerometer spike — vibration/knock noise on a
#      hard surface is mostly accelerometer-only.
#   3. The unstable pattern PERSISTS across more than one consecutive
#      reading — a single noisy sample should not be enough.
#
# These three checks are computed entirely from data already produced
# by _derive_features() (tilt_angle_x/y, gyro_magnitude) and from the
# existing `history` list — no change to FEATURE_COLS, the trained
# models, or any .pkl file is required.
# ============================================================

TILT_ONSET_DEG = 20.0               # overall tilt-from-vertical a real fall actually reaches
GYRO_CORROBORATION_THRESHOLD = 8.0  # gyro_magnitude floor a genuine fall/impact should show
# NOTE: both are a reasonable starting point (chosen from an offline
# simulation — see test_table_false_positive.py — not from your own
# device's real fall/table recordings). Tune them once you have a raw
# sensor log captured from an actual false trigger and from a real
# recorded fall, the same way the thresholds elsewhere in this file
# are flagged as defaults to revisit.


def analyze_sequence(history: List[Dict[str, Any]]) -> Tuple[str, Optional[str], bool]:
    """Returns (risk_level, description, fall_detected)."""
    if len(history) < 2:
        return "LOW", None, False

    last, previous = history[-1], history[-2]
    ax_raw = last.get("ax_raw", 0.0)
    ay_raw = last.get("ay_raw", 0.0)
    impact_magnitude = float(np.sqrt(ax_raw ** 2 + ay_raw ** 2))

    base_fall_pattern = (
        last["stability"] == "Unstable"
        and last["activity"] in ["Standing", "Walking"]
        and impact_magnitude > FALL_MAGNITUDE_THRESHOLD
    )

    if base_fall_pattern:
        # --- FIX: three extra physically-grounded gates before we
        # actually confirm this as a fall (see block comment above).
        # NOTE: this uses the ABSOLUTE tilt the device has reached (not
        # a frame-to-frame delta) — a real fall stays tilted once it
        # happens, it doesn't keep changing tilt every single sample,
        # so gating on "did tilt change since last sample" would miss
        # the second and later samples of a real fall. ---
        tilt_now = float(np.hypot(last.get("tilt_x", 0.0), last.get("tilt_y", 0.0)))
        reoriented = tilt_now >= TILT_ONSET_DEG
        rotation_corroborated = last.get("gyro_mag", 0.0) > GYRO_CORROBORATION_THRESHOLD
        persisted = previous.get("stability") == "Unstable"

        if reoriented and rotation_corroborated and persisted:
            severity = _classify_fall_severity(impact_magnitude)
            direction = _fall_direction_label(ax_raw, ay_raw)
            return severity, direction, True

        # The accelerometer spike LOOKS like a fall, but the device's
        # orientation barely changed and/or there was no matching
        # rotational motion and/or it was a single one-off sample —
        # most consistent with surface vibration/noise (e.g. the
        # device resting on a table), not a real fall. Report it as a
        # status update instead of raising a false alert.
        return (
            "HIGH",
            "Unstable reading did not match a real fall pattern (possible sensor noise, e.g. device resting on a surface)",
            False,
        )

    # --- PRE-FALL WARNING: unstable transition, no impact yet ---
    if previous["activity"] == "Walking" and last["activity"] == "Standing" and last["stability"] == "Unstable":
        return "HIGH", "Instability after stopping from walk", False
    if previous["activity"] == "Sitting" and last["activity"] == "Standing" and last["stability"] == "Unstable":
        return "MEDIUM", "Instability when rising from seated position", False
    if previous["activity"] == "Standing" and last["activity"] == "Walking" and last["stability"] == "Unstable":
        return "MEDIUM", "Irregular walking pattern detected", False

    return "LOW", None, False


def generate_explanation(history: List[Dict[str, Any]], risk: str,
                          prediction: Optional[str], fall_detected: bool) -> str:
    if fall_detected:
        prev_act = history[-2]["activity"] if len(history) >= 2 else "previous activity"
        direction = prediction or "A fall"
        return (
            f"{direction} detected during {history[-1]['stability'].lower()} "
            f"{history[-1]['activity'].lower()} after {prev_act.lower()}. Severity: {risk}."
        )
    if risk == "HIGH":
        return "High risk: sudden stop from walking caused instability."
    if risk == "MEDIUM":
        return "Moderate risk: abnormal activity transition detected."
    return "Normal activity — no immediate risk detected."


# ============================================================
# MAIN INFERENCE ENTRY POINT
# ============================================================

def run_system(raw_sample: Dict[str, float], history: List[Dict[str, Any]],
                trained: Dict[str, Any]) -> Dict[str, Any]:
    ax, ay, az = raw_sample["accel_x"], raw_sample["accel_y"], raw_sample["accel_z"]
    gx, gy, gz = raw_sample["gyro_x"], raw_sample["gyro_y"], raw_sample["gyro_z"]

    features = _derive_features(ax, ay, az, gx, gy, gz)
    raw_features = np.array([[features[c] for c in FEATURE_COLS]])
    scaled = trained["scaler"].transform(raw_features)

    activity = trained["le_activity"].inverse_transform(trained["best_model"].predict(scaled))[0]
    stability = get_stability(ax, ay, az)

    fall_pred = trained["fall_model"].predict(scaled)
    fall_type = trained["le_fall"].inverse_transform(fall_pred)[0]

    try:
        proba = trained["fall_model"].predict_proba(scaled)[0]
        confidence = round(float(np.max(proba)) * 100, 1)
    except Exception:
        confidence = 0.0

    history.append({
        "activity": activity, "stability": stability,
        "ax_raw": ax, "ay_raw": ay, "az_raw": az,
        "gx_raw": gx, "gy_raw": gy, "gz_raw": gz,
        # FIX (table false-positive): carry the already-computed
        # orientation (tilt_x/tilt_y) and rotational-motion
        # (gyro_mag) signals forward into history so analyze_sequence()
        # can tell a real reorientation+rotation apart from a
        # motionless device just picking up surface noise.
        "tilt_x": features["tilt_angle_x"], "tilt_y": features["tilt_angle_y"],
        "gyro_mag": features["gyro_magnitude"],
    })
    if len(history) > 5:
        history.pop(0)

    risk_level, prediction, fall_detected = analyze_sequence(history)

    # FIX (fall_detected=True / fall_type="No Fall" contradiction):
    # `fall_detected` (rule layer, above) and `fall_type` (independent
    # ML classifier, a few lines up) are computed by two separate
    # mechanisms from the same raw sample, so they CAN disagree — the
    # rule layer confirms a real impact crossed FALL_MAGNITUDE_THRESHOLD
    # while the classifier's top probability still lands on "No Fall"
    # (e.g. a borderline/low-confidence reading). Reported as-is, that
    # reads as a contradiction: "a fall happened" + "fall type: no
    # fall". The classifier is NOT touched or retrained here — this
    # only decides what to report. When the two layers disagree, fall
    # back to the direction already derivable from the same raw impact
    # data the rule layer used to confirm the fall in the first place
    # (_fall_direction_to_type, mirroring _fall_direction_label just
    # above but in le_fall's exact label spelling), and record which
    # source actually produced the reported fall_type so this is
    # auditable rather than silently overwritten.
    fall_type_source = "ml_model"
    if fall_detected and fall_type == "No Fall":
        last_sample = history[-1]
        fall_type = _fall_direction_to_type(last_sample["ax_raw"], last_sample["ay_raw"])
        fall_type_source = "rule_fallback"

    explanation = generate_explanation(history, risk_level, prediction, fall_detected)
    sequence = " → ".join(
        f"{h['activity']}({'U' if h['stability'] == 'Unstable' else 'S'})" for h in history
    )

    return {
        "activity": activity,
        "stability": stability,
        "sequence": sequence,
        "risk_level": risk_level,
        "prediction": prediction,
        "confidence": confidence,
        "fall_type": fall_type,
        "fall_type_source": fall_type_source,
        "fall_detected": fall_detected,
        "explanation": explanation,
        "alert": fall_detected,
    }
