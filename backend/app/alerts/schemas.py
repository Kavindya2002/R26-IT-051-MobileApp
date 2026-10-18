from pydantic import BaseModel, Field


class AlertRecord(BaseModel):
    """Shape of one row written to the `alerts` table. Not used as a
    request body anywhere — AlertService builds this internally after
    a Component 4 prediction, from data the caller already trusts
    (the pipeline's own output), so there's no user-supplied version
    of this schema to validate.

    UPDATE: added `explanation` — closes the gap where the Emergency
    Person's Alert Detail screen had a "Why this alert" section with
    nothing real to show (Component 1's plain-language explanation
    was never persisted, only structured fields were). Run this
    migration before deploying:

        alter table alerts add column if not exists explanation text;

    UPDATE 2: added `fall_detected` — Component 1 always computes this
    (it's a required field in component1_result, see
    app/integration/pipeline.py's own validation), but it was never
    persisted here, only `fall_type` was. That silently broke the
    Flutter Analytics screen's "actual fall vs. pre-fall warning"
    distinction: `fall_type` alone can't carry that information once
    Component 1 was fixed to always return a non-null fall_type
    ("No Fall" included). Run this migration before deploying:

        alter table alerts add column if not exists fall_detected boolean not null default false;

        -- Best-effort backfill for rows written before this column
        -- existed: fall_type is the only historical signal available
        -- for them, so treat anything other than "No Fall" as a real
        -- fall. This is a reasonable proxy, not a perfect
        -- reconstruction — new rows going forward get the real value
        -- directly from Component 1 via the pipeline.
        update alerts set fall_detected = true where fall_type != 'No Fall';

    UPDATE 3 (duplicate-alert prevention, restart/idempotency backstop
    — see migrations/0001_alert_episode_idempotency.sql): added
    `episode_id`, a NULLABLE, OPTIONAL field. It carries the stable
    in-memory uuid4() that message_router.py generates when it opens
    a new fall "episode" (see message_router.py's own docstring). It
    exists so AlertService.find_recent_open_episode() can recognize,
    after a backend restart or from a second worker process, that a
    just-arrived sample belongs to an episode that was ALREADY alerted
    — without it, a restart mid-episode would create a second alert
    for the same ongoing fall. It is None for every row created before
    this change, and None for rows NOT created through the automatic
    MQTT pipeline (e.g. the manual /escalate endpoint never sets it —
    escalation is always treated as its own distinct event, by
    design). Run the migration above before deploying this change;
    the column is additive and nullable, so existing rows and callers
    are unaffected either way.
    """

    elder_id: str
    fall_type: str
    fall_detected: bool
    risk_level: str
    alert_type: str
    confidence: float
    location: str | None = None
    explanation: str | None = None
    guidance_completed: bool = False
    escalated: bool = False
    episode_id: str | None = None


class EscalateRequest(BaseModel):
    reason: str = Field(description='"no_response_timeout" or "elder_requested_help"')
    fall_type: str = Field(default="fall")
