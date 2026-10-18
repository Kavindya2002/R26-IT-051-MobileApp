"""
test_table_false_positive.py

Offline simulation test for the Component 1 "device left stationary on a
table" false-positive fix, run WITHOUT the physical device.

What it does:
    1. Trains a throwaway model from fall_detection.py's own
       generate_dataset()/train_models() (same as model_loader.py does
       when no pretrained .pkl files exist), so this script needs no
       hardware and no pretrained models.
    2. Feeds ~30 samples of "device resting flat and still on a table"
       sensor readings (small random noise around gravity, no real
       motion) through run_system() and checks fall_detected is never
       True.
    3. Feeds a "device knocked / vibrated on a hard table" burst
       (bigger, sharper accelerometer noise but still basically no
       orientation change and no real gyro rotation) through
       run_system() and checks fall_detected is still never True --
       this is the specific pattern that used to cause the false
       positive.
    4. Feeds a simulated REAL forward fall (large tilt change + real
       gyro rotation, sustained across 2 samples) through run_system()
       and checks fall_detected DOES become True -- so the fix hasn't
       introduced a false negative.

Usage:
    python3 test_table_false_positive.py

Put this file next to your real app/component1/ml/fall_detection.py
(or edit the import path below) before running it.
"""

import sys
import numpy as np

# If fall_detection.py lives elsewhere, adjust this import.
from fall_detection import generate_dataset, train_models, run_system


def make_sample(ax, ay, az, gx, gy, gz):
    return {
        "accel_x": ax, "accel_y": ay, "accel_z": az,
        "gyro_x": gx, "gyro_y": gy, "gyro_z": gz,
    }


def run_scenario(name, samples, trained, expect_fall):
    history = []
    fall_triggered = False
    triggered_at = None
    for i, raw in enumerate(samples):
        result = run_system(raw, history, trained)
        if result["fall_detected"]:
            fall_triggered = True
            triggered_at = i
            break

    status = "PASS" if fall_triggered == expect_fall else "FAIL"
    print(f"[{status}] {name}: fall_detected ever True? {fall_triggered}"
          + (f" (at sample #{triggered_at})" if fall_triggered else "")
          + f"  | expected: {expect_fall}")
    return status == "PASS"


def main():
    print("Training a throwaway model from the synthetic dataset "
          "(same as model_loader.py's fallback path)...")
    rng = np.random.default_rng(123)
    df = generate_dataset(6000, seed=7)
    trained = train_models(df)
    print(f"Done. best_model={trained['best_model_name']}\n")

    all_passed = True

    # ------------------------------------------------------------
    # Scenario 1: device resting flat & perfectly still on a table.
    # az ~ +9.81 (gravity), ax/ay ~ 0, gyro ~ 0, only tiny sensor noise.
    # ------------------------------------------------------------
    still_samples = []
    for _ in range(30):
        ax = rng.normal(0.0, 0.05)
        ay = rng.normal(0.0, 0.05)
        az = rng.normal(9.81, 0.05)
        gx = rng.normal(0.0, 0.1)
        gy = rng.normal(0.0, 0.1)
        gz = rng.normal(0.0, 0.1)
        still_samples.append(make_sample(ax, ay, az, gx, gy, gz))
    all_passed &= run_scenario(
        "Table, perfectly still", still_samples, trained, expect_fall=False
    )

    # ------------------------------------------------------------
    # Scenario 2: device on a table getting knocked / vibrated --
    # THIS is the pattern that used to cause the false positive:
    # sharp accel spikes crossing get_stability()'s thresholds, but
    # orientation barely changes and there's no real gyro rotation.
    # ------------------------------------------------------------
    vibration_samples = []
    for i in range(30):
        if i in (10, 11, 20):  # a few sharp knock/vibration bursts
            ax = rng.normal(0.0, 2.2)
            ay = rng.normal(0.0, 2.2)
            az = rng.normal(9.0, 1.0)   # still roughly gravity-aligned
            gx = rng.normal(0.0, 1.0)   # vibration: not a real rotation
            gy = rng.normal(0.0, 1.0)
            gz = rng.normal(0.0, 1.0)
        else:
            ax = rng.normal(0.0, 0.05)
            ay = rng.normal(0.0, 0.05)
            az = rng.normal(9.81, 0.05)
            gx = rng.normal(0.0, 0.1)
            gy = rng.normal(0.0, 0.1)
            gz = rng.normal(0.0, 0.1)
        vibration_samples.append(make_sample(ax, ay, az, gx, gy, gz))
    all_passed &= run_scenario(
        "Table, knocked/vibrated (old false-positive case)",
        vibration_samples, trained, expect_fall=False,
    )

    # ------------------------------------------------------------
    # Scenario 3: a simulated REAL forward fall -- large orientation
    # change (device tips over) WITH real gyro rotation, sustained
    # across more than one sample. fall_detected should become True.
    # ------------------------------------------------------------
    fall_samples = []
    # walking normally for a bit first
    for _ in range(5):
        ax = rng.normal(0.5, 0.3)
        ay = rng.normal(0.1, 0.2)
        az = rng.normal(9.5, 0.3)
        gx = rng.normal(0.0, 3.0)
        gy = rng.normal(0.0, 3.0)
        gz = rng.normal(0.0, 2.0)
        fall_samples.append(make_sample(ax, ay, az, gx, gy, gz))
    # then a real fall: big accel spike, big gyro spike, orientation
    # actually changes -- for TWO consecutive samples (persistence)
    for _ in range(2):
        ax = rng.normal(6.0, 0.5)
        ay = rng.normal(0.2, 0.3)
        az = rng.normal(2.0, 0.8)   # az moves far away from +9.81 -> big tilt change
        gx = rng.normal(0.0, 12.0)
        gy = rng.normal(0.0, 10.0)
        gz = rng.normal(0.0, 8.0)
        fall_samples.append(make_sample(ax, ay, az, gx, gy, gz))
    all_passed &= run_scenario(
        "Simulated real forward fall", fall_samples, trained, expect_fall=True
    )

    print()
    if all_passed:
        print("ALL SCENARIOS PASSED - table/vibration no longer falsely "
              "triggers fall_detected, and a real fall still does.")
    else:
        print("SOME SCENARIOS FAILED - see [FAIL] lines above. Thresholds "
              "(TILT_CHANGE_THRESHOLD_DEG / GYRO_CORROBORATION_THRESHOLD in "
              "fall_detection.py) likely need tuning for your real device.")
        sys.exit(1)


if __name__ == "__main__":
    main()
