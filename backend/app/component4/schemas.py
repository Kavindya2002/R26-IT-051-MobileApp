from pydantic import BaseModel, Field


class Component1Output(BaseModel):
    fall_detected: bool
    fall_type: str
    risk_level: str
    movement: str
    confidence: float = Field(default=0.0, ge=0, le=100)


class Component2Output(BaseModel):
    location: str
    time: str


class UserRiskProfile(BaseModel):
    age: int
    previous_falls: int
    assistive_device: str


class Component4Request(BaseModel):
    component1: Component1Output
    component2: Component2Output
    user: UserRiskProfile
