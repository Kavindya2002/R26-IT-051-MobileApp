from pydantic import BaseModel, EmailStr


class InviteEmergencyContactRequest(BaseModel):
    email: EmailStr
