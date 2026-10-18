"""
app/events/service.py

Same deliberate resilience pattern as AlertService.create(): a failed
event write is logged, never raised — Component 2/3's actual
real-time readings (returned to the Flutter app via their own
/latest endpoints) must never be blocked by a database hiccup on a
best-effort history write.

FIX (duplicate-event prevention — restart-safety backstop, same bug
class already fixed for alerts via AlertService.find_recent_open_episode()):
Component 2's in-memory risk-level state (which decides when to log a
NEW environment event, only on a transition into HIGH/CRITICAL) resets
to nothing on every backend restart. If the physical environment is
still genuinely HIGH right after a restart, the next telemetry sample
looks like a "new" transition to this process, even though the
real-world condition never actually changed — producing a duplicate
event row that isn't a real new occurrence.

find_recent_duplicate() lets the caller check the DATABASE itself
(not just this process's in-memory state) for a very recent event
matching the same elder/location/severity before inserting another
one.

KNOWN LIMITATION (same trade-off already documented for the alerts
backstop): this is a narrow, time-window heuristic, not a perfect
per-event identity. A genuinely new, distinct HIGH event at the same
location within the window (e.g. risk dropped to MEDIUM and spiked
back to HIGH minutes later) would also be treated as a duplicate and
suppressed. Given this is meant to absorb the restart case
specifically, this trade-off is considered acceptable.
"""

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

from app.core.supabase import supabase_admin
from app.events.schemas import EventRecord

# How recent a matching event must be to count as "the same
# occurrence" rather than a genuinely new one. Kept as its own
# constant here (not shared with alerts' EPISODE_RECOVERY_WINDOW_SECONDS)
# since events and alerts are independent tables with no shared
# config requirement.
EVENT_DEDUP_WINDOW_SECONDS = 1800  # 30 minutes


class EventService:
    @staticmethod
    def create(record: EventRecord) -> Optional[Dict[str, Any]]:
        try:
            response = supabase_admin.table("events").insert(record.model_dump()).execute()
            if not response.data:
                print("[Events] Insert returned no data (write may have failed silently).")
                return None
            return response.data[0]
        except Exception as exc:
            print(f"[Events] Failed to persist event (continuing without it): {exc}")
            return None

    @staticmethod
    def find_recent_duplicate(
        elder_id: str,
        source: str,
        location: Optional[str],
        severity: str,
        window_seconds: int = EVENT_DEDUP_WINDOW_SECONDS,
    ) -> Optional[Dict[str, Any]]:
        """Returns the most recent matching event row for this
        elder/source/location/severity within `window_seconds`, or
        None if none exists. Used as a restart-safety backstop before
        inserting a new event — see module docstring."""
        try:
            cutoff = (datetime.now(timezone.utc) - timedelta(seconds=window_seconds)).isoformat()
            query = (
                supabase_admin.table("events")
                .select("*")
                .eq("elder_id", elder_id)
                .eq("source", source)
                .eq("severity", severity)
                .gte("created_at", cutoff)
                .order("created_at", desc=True)
                .limit(1)
            )
            if location:
                query = query.eq("location", location)
            response = query.execute()
            return response.data[0] if response.data else None
        except Exception as exc:
            # Fail OPEN here — never block a real environment event
            # from being logged just because this safety check itself
            # had a hiccup (same reasoning as create()'s own try/except).
            print(f"[Events] Duplicate-check query failed (continuing to log normally): {exc}")
            return None

    @staticmethod
    def list_for_elder(elder_id: str, limit: int = 20, offset: int = 0) -> Dict[str, Any]:
        response = (
            supabase_admin.table("events")
            .select("*")
            .eq("elder_id", elder_id)
            .order("created_at", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )
        return {"success": True, "events": response.data or []}