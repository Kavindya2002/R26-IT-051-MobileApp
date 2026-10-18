"""
app/component4/model_loader.py


"""

from pathlib import Path

import joblib


class Component4ModelLoader:
    def __init__(self) -> None:
        self.model_dir = Path(__file__).resolve().parent / "models"
        self.xgboost_model = None
        self.label_encoder = None
        self.training_columns = None

    def load(self) -> None:
        print("=" * 70)
        print("COMPONENT 4 MODEL LOADER")
        print("=" * 70)

        model_path = self.model_dir / "xgboost_model.pkl"
        encoder_path = self.model_dir / "label_encoder.pkl"
        columns_path = self.model_dir / "training_columns.pkl"

        for path, label in [(model_path, "model"), (encoder_path, "label encoder"),
                             (columns_path, "training columns")]:
            if not path.exists():
                raise FileNotFoundError(
                    f"Missing Component 4 {label}: {path}\n"
                    f"Place your trained artifacts in {self.model_dir}"
                )

        self.xgboost_model = joblib.load(model_path)
        self.label_encoder = joblib.load(encoder_path)
        self.training_columns = joblib.load(columns_path)

        print("Model, label encoder, and training columns loaded.")
        print("Training columns:", list(self.training_columns))
        print("Alert classes:", list(self.label_encoder.classes_))
        print("=" * 70)


component4_loader = Component4ModelLoader()
