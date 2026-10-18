from fastapi import APIRouter, Depends

from app.emergency_contacts.schemas import InviteEmergencyContactRequest
from app.emergency_contacts.service import EmergencyContactService
from app.users.dependencies import get_access_token
from app.users.service import UserService

router = APIRouter(tags=["Emergency Contacts"])


@router.post("/elders/{elder_id}/emergency-contacts")
def invite_emergency_contact(
    elder_id: str,
    request: InviteEmergencyContactRequest,
    access_token: str = Depends(get_access_token),
):
    caregiver = UserService.get_current_user(access_token)["user"]
    return EmergencyContactService.invite(elder_id, caregiver["id"], request.email)


@router.delete("/elders/{elder_id}/emergency-contacts/{emergency_person_id}")
def remove_emergency_contact(
    elder_id: str,
    emergency_person_id: str,
    access_token: str = Depends(get_access_token),
):
    caregiver = UserService.get_current_user(access_token)["user"]
    return EmergencyContactService.remove(elder_id, caregiver["id"], emergency_person_id)


@router.get("/elders/{elder_id}/emergency-contacts")
def list_emergency_contacts(elder_id: str, access_token: str = Depends(get_access_token)):
    caregiver = UserService.get_current_user(access_token)["user"]
    return EmergencyContactService.list_for_elder(elder_id, caregiver["id"])


@router.get("/emergency-contacts/my-elders")
def my_elders(access_token: str = Depends(get_access_token)):
    """Called by an EMERGENCY_PERSON — returns the elders they've been
    linked to by a caregiver, so the Flutter app knows which elder(s)
    to show on the Emergency Alerts Feed screen."""
    current_user = UserService.get_current_user(access_token)["user"]
    return EmergencyContactService.list_my_elders(current_user["id"])
