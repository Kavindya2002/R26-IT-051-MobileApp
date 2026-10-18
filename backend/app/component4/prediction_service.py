"""
app/component4/prediction_service.py

"""

import pandas as pd

from app.component4.guidance.guidance_service import guidance_service


class PredictionService:
    EXPECTED_COLUMNS = [
        "FallDetected", "FallType", "RiskLevel", "Age",
        "PreviousFalls", "Location", "Time", "Movement", "AssistiveDevice",
    ]

    def __init__(self, loader):
        self.loader = loader

    def validate_model(self) -> None:
        actual = list(self.loader.training_columns)
        if actual != self.EXPECTED_COLUMNS:
            raise ValueError(
                "Component 4 model columns do not match the required architecture.\n"
                f"Expected: {self.EXPECTED_COLUMNS}\nLoaded: {actual}"
            )

    def predict(self, request) -> dict:
        if self.loader.xgboost_model is None:
            raise RuntimeError("XGBoost model is not loaded.")
        if self.loader.label_encoder is None:
            raise RuntimeError("Label encoder is not loaded.")
        if self.loader.training_columns is None:
            raise RuntimeError("Training columns are not loaded.")

        self.validate_model()

        component1 = request.component1
        component2 = request.component2
        user = request.user

        data = {
            "FallDetected": 1 if component1.fall_detected else 0,
            "FallType": component1.fall_type,
            "RiskLevel": component1.risk_level,
            "Age": user.age,
            "PreviousFalls": user.previous_falls,
            "Location": component2.location,
            "Time": component2.time,
            "Movement": component1.movement,
            "AssistiveDevice": user.assistive_device,
        }

        df = pd.DataFrame([data])[self.loader.training_columns]

        prediction = self.loader.xgboost_model.predict(df)[0]
        probabilities = self.loader.xgboost_model.predict_proba(df)[0]

        alert = str(self.loader.label_encoder.inverse_transform([prediction])[0])
        confidence = float(max(probabilities))

        probability_result = {
            str(cls): round(float(probabilities[i]) * 100, 2)
            for i, cls in enumerate(self.loader.label_encoder.classes_)
        }

        guidance = guidance_service.create_guidance(
            alert=alert,
            risk_level=component1.risk_level,
            fall_detected=component1.fall_detected,
            fall_type=component1.fall_type,
        )

        return {
            "status": "success",
            "model": "Component 4 XGBoost",
            "input": data,
            "alert": alert,
            "confidence": round(confidence * 100, 2),
            "probabilities": probability_result,
            "guidance": guidance,
        }

    def model_info(self) -> dict:
        model_loaded = self.loader.xgboost_model is not None
        encoder_loaded = self.loader.label_encoder is not None
        columns_loaded = self.loader.training_columns is not None

        return {
            "model_loaded": model_loaded,
            "label_encoder_loaded": encoder_loaded,
            "training_columns": list(self.loader.training_columns) if columns_loaded else [],
            "input_count": len(self.loader.training_columns) if columns_loaded else 0,
            "alert_classes": list(self.loader.label_encoder.classes_) if encoder_loaded else [],
            "guidance": {
                "enabled_when": ["alert = 'Voice Alert'", "FallDetected = true"],
                "disabled_when": ["alert = 'Caregiver Alert'", "alert = 'Emergency Alert'", "FallDetected = false"],
            },
        }
