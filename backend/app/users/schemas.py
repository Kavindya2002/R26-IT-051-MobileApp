from enum import Enum

from pydantic import BaseModel, EmailStr, Field


class UserRole(str, Enum):
    CAREGIVER = "CAREGIVER"
    EMERGENCY_PERSON = "EMERGENCY_PERSON"
    # Elders never self-register through the public /users/register
    # endpoint with this role — only app/elders/service.py's
    # ElderService.create()/update() can ever create a user row with
    # role=ELDER, and only when an authenticated caregiver explicitly
    # grants login access for one of their own elder profiles. See
    # app/elders/service.py for the real creation path.
    ELDER = "ELDER"


class RegisterRequest(BaseModel):

    name: str = Field(
        min_length=2,
        max_length=100,
    )

    email: EmailStr

    password: str = Field(
        min_length=8,
        max_length=128,
    )

    phone: str = Field(
        min_length=9,
        max_length=20,
    )

    role: UserRole

    address: str | None = Field(
        default=None,
        max_length=255,
    )

    relationship: str | None = Field(
        default=None,
        max_length=100,
    )

    priority: int = Field(
        default=1,
        ge=1,
    )


class LoginRequest(BaseModel):

    email: EmailStr

    password: str = Field(
        min_length=1,
        max_length=128,
    )


class UpdateUserRequest(BaseModel):

    name: str | None = Field(
        default=None,
        min_length=2,
        max_length=100,
    )

    phone: str | None = Field(
        default=None,
        min_length=9,
        max_length=20,
    )

    address: str | None = Field(
        default=None,
        max_length=255,
    )

    relationship: str | None = Field(
        default=None,
        max_length=100,
    )

    priority: int | None = Field(
        default=None,
        ge=1,
    )

    # ADDED (avatar picker feature): the id of a preset avatar chosen
    # in the Flutter app (e.g. "caregiver_3") — see
    # lib/constants/avatar_presets.dart for the fixed set of valid ids.
    # Nullable/optional so every existing caller (and every profile
    # that hasn't picked one yet) is completely unaffected.
    avatar_id: str | None = Field(
        default=None,
        max_length=50,
    )
