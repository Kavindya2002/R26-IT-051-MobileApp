from fastapi import APIRouter, Depends

from app.elders.schemas import CreateElderRequest, UpdateElderRequest
from app.elders.service import ElderService
from app.users.dependencies import get_access_token
from app.users.service import UserService

router = APIRouter(prefix="/elders", tags=["Elders"])


@router.post("", status_code=201)
def create_elder(request: CreateElderRequest, access_token: str = Depends(get_access_token)):
    caregiver = UserService.get_current_user(access_token)["user"]
    return ElderService.create(caregiver["id"], request)


@router.get("")
def list_elders(access_token: str = Depends(get_access_token)):
    caregiver = UserService.get_current_user(access_token)["user"]
    return ElderService.list_for_caregiver(caregiver["id"])


# ADDED (ELDER role integration, prompt section 9): must be declared
# BEFORE "/{elder_id}" below — otherwise FastAPI would match a request
# for "/elders/me" against the "/{elder_id}" path parameter route
# instead (with elder_id literally equal to the string "me"), since
# routes are matched in declaration order.
#
# Deliberately takes NO elder_id from the client at all: the Elder's
# own profile is resolved purely from their authenticated user id, so
# an Elder can never view another elder's profile by guessing an id
# (prompt section 10).
@router.get("/me")
def get_my_elder_profile(access_token: str = Depends(get_access_token)):
    current_user = UserService.get_current_user(access_token)["user"]
    return ElderService.get_my_profile(current_user["id"])


@router.put("/{elder_id}")
def update_elder(elder_id: str, request: UpdateElderRequest, access_token: str = Depends(get_access_token)):
    caregiver = UserService.get_current_user(access_token)["user"]
    return ElderService.update(elder_id, caregiver["id"], request)


@router.get("/{elder_id}")
def get_elder(elder_id: str, access_token: str = Depends(get_access_token)):
    caregiver = UserService.get_current_user(access_token)["user"]
    return ElderService.get_by_id(elder_id, caregiver["id"])


@router.get("/{elder_id}/public")
def get_elder_public(elder_id: str):
    """No auth dependency — see ElderService.get_public()'s doc
    comment. Used by the standalone Elder App, which has no login."""
    return ElderService.get_public(elder_id)


@router.delete("/{elder_id}")
def delete_elder(elder_id: str, access_token: str = Depends(get_access_token)):
    caregiver = UserService.get_current_user(access_token)["user"]
    return ElderService.delete(elder_id, caregiver["id"])
