"""
app/component4/api/router.py

"""

from fastapi import APIRouter, HTTPException

from app.component4.model_loader import component4_loader
from app.component4.prediction_service import PredictionService
from app.component4.schemas import Component4Request

router = APIRouter(prefix="/component4", tags=["Component 4"])

prediction_service = PredictionService(component4_loader)


@router.post("/predict")
def predict_component4(request: Component4Request):
    try:
        return prediction_service.predict(request)
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail={"status": "error", "message": "Component 4 prediction failed.", "error": str(exc)},
        )


@router.get("/model-info")
def component4_model_info():
    try:
        return prediction_service.model_info()
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail={"status": "error", "message": "Unable to retrieve model information.", "error": str(exc)},
        )


@router.get("/health")
def component4_health():
    return {
        "status": "healthy",
        "component": "Component 4",
        "model_loaded": component4_loader.xgboost_model is not None,
        "label_encoder_loaded": component4_loader.label_encoder is not None,
        "training_columns_loaded": component4_loader.training_columns is not None,
    }
