"""
app/events/schemas.py

THE FIX for a confirmed gap: the `alerts` table only ever receives
Component 4's fall-triggered decisions, so Analytics and Alerts in
the Flutter app have never been able to show anything from Component
2 (environment) or Component 3 (vitals) — not because those
components don't detect anything noteworthy, but because neither one
had anywhere to persist a "this zone/vital just became risky" moment.

Deliberately a SEPARATE table from `alerts` rather than overloading
it: alerts has fall-specific required fields (fall_type) that don't
map cleanly onto "moisture sensor crossed into HIGH in the bathroom"
or "resting heart rate entered Critical range". A generic `events`
table avoids forcing non-fall data into a fall-shaped schema.

This does NOT change Component 1/4's fall-alert pipeline at all —
it only gives Components 2 and 3 a place to write to, which they
previously lacked entirely.
"""

from pydantic import BaseModel


class EventRecord(BaseModel):
    """Shape of one row written to the `events` table."""

    elder_id: str
    source: str  # "component2" | "component3"
    event_type: str  # e.g. "environment_risk", "vitals_risk"
    severity: str  # the component's own real severity string, e.g. "HIGH", "Critical"
    location: str | None = None  # Component 2 only
    details: str | None = None  # short, human-readable, built from real values only
