from fastapi import APIRouter, Depends, Query

from app.alerts.schemas import EscalateRequest
from app.alerts.service import AlertService
from app.elders.service import ElderService
from app.emergency_contacts.service import EmergencyContactService
from app.integration.pipeline import elder_care_pipeline
from app.users.dependencies import get_access_token
from app.users.service import UserService

router = APIRouter(tags=["Alerts"])


@router.get("/elders/{elder_id}/alerts")
def list_elder_alerts(
    elder_id: str,
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    alert_type: str | None = Query(default=None, description="Voice Alert | Caregiver Alert | Emergency Alert"),
    access_token: str = Depends(get_access_token),
):
    user = UserService.get_current_user(access_token)["user"]


    if user["role"] == "EMERGENCY_PERSON":
        EmergencyContactService.verify_linked(elder_id, user["id"])
    else:

        ElderService.get_by_id(elder_id, user["id"])

    return AlertService.list_for_elder(elder_id, limit=limit, offset=offset, alert_type=alert_type)


@router.post("/elders/{elder_id}/escalate")
def escalate(elder_id: str, request: EscalateRequest, access_token: str = Depends(get_access_token)):
    """
    """
    UserService.get_current_user(access_token)  
    ElderService.get_risk_profile(elder_id) 

    result = elder_care_pipeline.predict(
        component1_result={
            "fall_detected": True,
            "fall_type": request.fall_type,
            "risk_level": "HIGH",
            "movement": "Unresponsive",
            "confidence": 100.0,
        },
        elder_id=elder_id,
        force_alert_type="Emergency Alert",
    )
    return {
        "success": True,
        "reason": request.reason,
        **result,
    }


@router.post("/alerts/{alert_id}/guidance-completed")
def mark_guidance_completed(alert_id: str, access_token: str = Depends(get_access_token)):
    UserService.get_current_user(access_token) 
    return AlertService.mark_guidance_completed(alert_id)
