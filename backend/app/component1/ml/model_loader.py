"""
app/component1/ml/model_loader.py

Loads pre-trained Component 1 artifacts if they exist under
app/component1/models/. If they don't exist, trains fresh from
a dataset (generating a synthetic one if needed) and saves the
result — so the project runs out of the box on a clean machine,
but prefers your already-trained models when present.

This replaces the old train.py / main.py / predict.py split that
had mismatched function signatures. There is exactly ONE training
code path now.
"""

import os
import pickle
from pathlib import Path
from typing import Any, Dict, Optional

import pandas as pd

from app.component1.ml.fall_detection import generate_dataset, train_models

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"
DATA_PATH = MODELS_DIR / "fall_detection_dataset.csv"

ARTIFACT_NAMES = [
    "scaler.pkl", "le_activity.pkl", "le_fall.pkl", "le_risk.pkl",
    "best_model.pkl", "fall_model.pkl", "risk_model.pkl",
]


class Component1ModelLoader:
    def __init__(self) -> None:
        self.trained: Optional[Dict[str, Any]] = None

    def _load_pickles(self) -> Optional[Dict[str, Any]]:
        paths = {name: MODELS_DIR / name for name in ARTIFACT_NAMES}
        if not all(p.exists() for p in paths.values()):
            return None

        loaded: Dict[str, Any] = {}
        for name, path in paths.items():
            with open(path, "rb") as f:
                loaded[name.replace(".pkl", "")] = pickle.load(f)

        best_name_file = MODELS_DIR / "best_model_name.txt"
        loaded["best_model_name"] = (
            best_name_file.read_text().strip() if best_name_file.exists() else "Random Forest"
        )
        return loaded

    def _save_pickles(self, trained: Dict[str, Any]) -> None:
        MODELS_DIR.mkdir(parents=True, exist_ok=True)
        for name in ARTIFACT_NAMES:
            key = name.replace(".pkl", "")
            with open(MODELS_DIR / name, "wb") as f:
                pickle.dump(trained[key], f)
        (MODELS_DIR / "best_model_name.txt").write_text(trained["best_model_name"])

    def load(self) -> Dict[str, Any]:
        if self.trained is not None:
            return self.trained

        print("=" * 70)
        print("COMPONENT 1 MODEL LOADER")
        print("=" * 70)

        pretrained = self._load_pickles()
        if pretrained is not None:
            print(f"Loaded pre-trained Component 1 models from {MODELS_DIR}")
            print(f"Best model: {pretrained['best_model_name']}")
            self.trained = pretrained
            return self.trained

        print("No pre-trained models found — training a fresh set.")
        print("(Put your own trained .pkl files in app/component1/models/")
        print(" to skip this step next time.)")

        if DATA_PATH.exists():
            df = pd.read_csv(DATA_PATH)
            print(f"Loaded dataset: {DATA_PATH} shape={df.shape}")
        else:
            print("No dataset found — generating a SYNTHETIC dataset (10,000 rows).")
            print("NOTE: this is simulated data, not measured sensor data.")
            df = generate_dataset(10000)
            MODELS_DIR.mkdir(parents=True, exist_ok=True)
            df.to_csv(DATA_PATH, index=False)

        trained = train_models(df)
        self._save_pickles(trained)
        self.trained = trained

        print(f"Best model: {trained['best_model_name']}")
        for name, scores in trained["results"].items():
            print(f"   {name}: Accuracy={scores['Accuracy']*100:.1f}%  F1={scores['F1-Score']*100:.1f}%")
        print("=" * 70)

        return self.trained


component1_loader = Component1ModelLoader()
