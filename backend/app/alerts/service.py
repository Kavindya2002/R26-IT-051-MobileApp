"""
app/alerts/service.py

"""

from typing import Any, Dict, Optional

from fastapi import HTTPException

from app.alerts.schemas import AlertRecord
from app.core.supabase import supabase_admin

# FIX (restart/concurrency-safe duplicate prevention — see
# message_router.py's docstring and migrations/0001_alert_episode_
# idempotency.sql): how long after the LAST alert for an elder a new
# fall_detected=True sample is still considered the "same" ongoing
# episode, for the purposes of the backstop check below ONLY. This is
# NOT the primary dedup mechanism (in-memory episode tracking in
# message_router.py is, and it reacts to the real
# fall_detected True/False transition, not a clock). This window only
# exists to catch the narrow case the in-memory state cannot: a
# backend restart (or a second worker process) losing track of an
# episode that is still physically ongoing.
#
# 10 seconds is chosen because real samples for one ongoing fall
# arrive roughly every 0.6-0.8s (confirmed from alerts_rows.csv) — 10s
# comfortably covers a restart/redeploy blip without being anywhere
# close to a realistic gap between two separate real-world falls.
# KNOWN LIMITATION (disclosed, not hidden): if an elder experiences
# two GENUINELY DISTINCT falls of the identical type within 10 seconds
# of each other, AND that window happens to straddle a backend
# restart, the second one could be incorrectly treated as a
# continuation rather than alerted separately. There is no stable
# per-event sensor identifier to disambiguate this with full
# confidence (see sensor_parser.py — the ESP32 payload carries no
# event id). This is the safest feasible backstop given what the
# system can actually observe, not a claim of perfect episode
# detection.
EPISODE_RECOVERY_WINDOW_SECONDS = 10


class AlertService:
    @staticmethod
    def create(record: AlertRecord, guidance: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
        try:
            response = supabase_admin.table("alerts").insert(record.model_dump()).execute()
            if not response.data:
                print("[Alerts] Insert returned no data (write may have failed silently).")
                return None
            saved = response.data[0]

            try:
                from app.realtime.websocket_manager import connection_manager
                connection_manager.broadcast_sync(record.elder_id, {
                    "type": "alert",
                    "alert": saved,
                    "guidance": guidance,
                })
            except Exception as exc:
                print(f"[Alerts] WebSocket broadcast failed (non-fatal): {exc}")

            return saved
        except Exception as exc:
            print(f"[Alerts] Failed to persist alert (continuing without it): {exc}")
            return None

    # FIX (restart/concurrency-safe duplicate prevention): called by
    # message_router.py right before it would otherwise treat a sample
    # as opening a BRAND NEW fall episode. Looks at the single most
    # recent alert row for this elder; if it matches the incoming
    # fall's type/alert_type and is recent enough (see
    # EPISODE_RECOVERY_WINDOW_SECONDS above), the caller should treat
    # this as a CONTINUATION of that already-alerted episode rather
    # than create a second alert row for it.
    #
    # Fails SAFE in the "open" direction: if this check itself cannot
    # reach Supabase (the same transient-disconnect scenario already
    # confirmed in list_for_elder()), it logs and returns None rather
    # than raising — a missed duplicate-prevention check is far less
    # harmful than silently dropping a real, new alert because a
    # safety check happened to fail.
    @staticmethod
    def find_recent_open_episode(
        elder_id: str,
        fall_type: str,
        alert_type: Optional[str] = None,
        within_seconds: int = EPISODE_RECOVERY_WINDOW_SECONDS,
    ) -> Optional[Dict[str, Any]]:
        try:
            response = (
                supabase_admin.table("alerts")
                .select("*")
                .eq("elder_id", elder_id)
                .order("created_at", desc=True)
                .limit(1)
                .execute()
            )
        except Exception as exc:
            print(f"[Alerts] Episode-recovery lookup failed (continuing without it): {exc}")
            return None

        rows = response.data or []
        if not rows:
            return None

        latest = rows[0]
        # fall_type is known to the caller BEFORE Component 4 runs
        # (it's Component 1's own output), so this check can run
        # ahead of the pipeline call and skip it entirely for a
        # recognized continuation. alert_type is Component 4's
        # decision — the caller here doesn't have it yet, so it's an
        # optional extra filter for callers that DO already know it
        # (e.g. a future check made after the pipeline already ran).
        if latest.get("fall_type") != fall_type:
            return None
        if alert_type is not None and latest.get("alert_type") != alert_type:
            return None

        created_at_raw = latest.get("created_at")
        if not created_at_raw:
            return None

        try:
            from datetime import datetime, timezone
            created_at = datetime.fromisoformat(str(created_at_raw).replace("Z", "+00:00"))
            if created_at.tzinfo is None:
                created_at = created_at.replace(tzinfo=timezone.utc)
            age_seconds = (datetime.now(timezone.utc) - created_at).total_seconds()
        except Exception as exc:
            print(f"[Alerts] Could not parse created_at for episode-recovery check: {exc}")
            return None

        if 0 <= age_seconds <= within_seconds:
            return latest
        return None

    @staticmethod
    def list_for_elder(
        elder_id: str,
        limit: int = 20,
        offset: int = 0,
        alert_type: Optional[str] = None,
    ) -> Dict[str, Any]:
        query = (
            supabase_admin.table("alerts")
            .select("*")
            .eq("elder_id", elder_id)
            .order("created_at", desc=True)
            .range(offset, offset + limit - 1)
        )
        if alert_type:
            query = query.eq("alert_type", alert_type)

        # FIX (confirmed real bug — matches a real backend log showing
        # "500 Internal Server Error" / httpx.RemoteProtocolError:
        # Server disconnected on this exact endpoint): query.execute()
        # previously had no error handling at all, so any transient
        # Supabase hiccup (a dropped connection, a timeout) propagated
        # as an unhandled 500 with an internal stack trace, instead of
        # a clean, expected error the Flutter app's
        # ErrorStateView/retry flow already knows how to show. create()
        # above already follows this same try/except pattern — this
        # brings list_for_elder() in line with it. A genuine empty
        # history (no exception, just zero rows) still returns the
        # normal {"success": True, "count": 0, "results": []} shape,
        # not an error.
        try:
            response = query.execute()
        except Exception as exc:
            print(f"[Alerts] Failed to fetch alert history for elder_id={elder_id}: {exc}")
            raise HTTPException(
                status_code=503,
                detail="Alert history is temporarily unavailable. Please try again.",
            )

        return {"success": True, "count": len(response.data or []), "results": response.data or []}

    @staticmethod
    def mark_guidance_completed(alert_id: str) -> Dict[str, Any]:
        response = (
            supabase_admin.table("alerts")
            .update({"guidance_completed": True})
            .eq("id", alert_id)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="Alert not found.")
        return {"success": True, "alert": response.data[0]}
