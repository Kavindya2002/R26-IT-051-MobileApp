from fastapi import APIRouter, Depends, Query

from app.elders.service import ElderService
from app.events.service import EventService
from app.users.dependencies import get_access_token
from app.users.service import UserService

router = APIRouter(tags=["Events"])


@router.get("/elders/{elder_id}/events")
def list_elder_events(
    elder_id: str,
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    access_token: str = Depends(get_access_token),
):
    """Environment/Health events (Component 2/3), separate from
    /elders/{elder_id}/alerts (Component 4's fall-triggered
    decisions). Same ownership check as the alerts endpoint — a
    caregiver can only read events for an elder they actually own.
    """
    caregiver = UserService.get_current_user(access_token)["user"]
    ElderService.get_by_id(elder_id, caregiver["id"])
    return EventService.list_for_elder(elder_id, limit=limit, offset=offset)
