from fastapi import APIRouter, Depends

from app.users.dependencies import (
    get_access_token,
)

from app.users.schemas import (
    RegisterRequest,
    LoginRequest,
    UpdateUserRequest,
)

from app.users.service import (
    UserService,
)


router = APIRouter(
    prefix="/users",
    tags=["Users"],
)


# =========================================================
# REGISTER
# =========================================================

@router.post(
    "/register",
    status_code=201,
)
def register_user(
    request: RegisterRequest,
):

    return UserService.register(
        request
    )


# =========================================================
# LOGIN
# =========================================================

@router.post("/login")
def login_user(
    request: LoginRequest,
):

    return UserService.login(
        request
    )


# =========================================================
# CURRENT USER
# =========================================================

@router.get("/me")
def get_my_profile(
    access_token: str = Depends(
        get_access_token
    ),
):

    return UserService.get_current_user(
        access_token
    )


# =========================================================
# UPDATE PROFILE
# =========================================================

@router.put("/me")
def update_my_profile(
    request: UpdateUserRequest,
    access_token: str = Depends(
        get_access_token
    ),
):

    return UserService.update_user(
        access_token,
        request,
    )