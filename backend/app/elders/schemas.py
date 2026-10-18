"""
app/elders/schemas.py

THE FIX for a gap confirmed during review: Component4Request.user
requires age, previous_falls, and assistive_device, but nothing in
the original project stored these anywhere — the `users` table only
had name/email/phone/role/address/relationship/priority.

This module gives those three fields a real home: an "elders" table,
linked to the caregiver who registered them. Run the SQL in
README.md to create the table before using this module.
"""

from pydantic import BaseModel, EmailStr, Field


class CreateElderRequest(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    age: int = Field(ge=0, le=130)
    previous_falls: int = Field(default=0, ge=0)
    assistive_device: str = Field(default="none", max_length=50)
    address: str | None = Field(default=None, max_length=255)
    phone: str | None = Field(default=None, max_length=20)
    gender: str | None = Field(default=None, max_length=20)

    # Lets a caregiver optionally provision real app-login access for
    # this elder in the SAME request that creates their profile — no
    # separate self-registration step for the elder. Both optional/
    # default-off so every existing caller (and the Flutter form
    # before this change) keeps working with zero behavior change
    # when omitted.
    grant_login: bool = Field(default=False)
    login_email: EmailStr | None = Field(default=None)

    # ADDED (avatar picker feature): the id of a preset avatar chosen
    # in the Flutter app (e.g. "elder_1") — see
    # lib/constants/avatar_presets.dart for the fixed set of valid ids.
    avatar_id: str | None = Field(default=None, max_length=50)


class UpdateElderRequest(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=100)
    age: int | None = Field(default=None, ge=0, le=130)
    previous_falls: int | None = Field(default=None, ge=0)
    assistive_device: str | None = Field(default=None, max_length=50)
    address: str | None = Field(default=None, max_length=255)
    phone: str | None = Field(default=None, max_length=20)
    gender: str | None = Field(default=None, max_length=20)

    # Same optional login-provisioning fields as CreateElderRequest, so
    # a caregiver can grant app access to an EXISTING elder profile
    # later (one that was created before this feature existed, or
    # whose caregiver skipped it originally).
    grant_login: bool = Field(default=False)
    login_email: EmailStr | None = Field(default=None)

    # ADDED (avatar picker feature): see CreateElderRequest.avatar_id.
    # Nullable/optional so every existing caller (and every elder who
    # hasn't picked one yet) is completely unaffected.
    avatar_id: str | None = Field(default=None, max_length=50)
