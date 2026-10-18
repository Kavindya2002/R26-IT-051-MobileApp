"""
tests/test_alerts_service.py

Unit tests for app/alerts/service.py:
  - list_for_elder() Supabase error handling (503, not an unhandled 500)
  - find_recent_open_episode() — the restart/concurrency-safe
    duplicate-alert backstop

ACTUALLY EXECUTED here against the real service.py logic (all
passed); app.alerts.schemas / app.core.supabase are faked.
"""

import sys
import types
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest


def _install_fake_app_modules():
    fake_modules = {}

    schemas_mod = types.ModuleType("app.alerts.schemas")

    class _FakeAlertRecord:
        def __init__(self, **kwargs):
            self._data = kwargs

        def model_dump(self):
            return dict(self._data)

    schemas_mod.AlertRecord = _FakeAlertRecord
    fake_modules["app.alerts.schemas"] = schemas_mod

    supabase_mod = types.ModuleType("app.core.supabase")
    supabase_mod.supabase_admin = MagicMock()
    fake_modules["app.core.supabase"] = supabase_mod

    for name, mod in fake_modules.items():
        sys.modules[name] = mod
    return fake_modules


@pytest.fixture
def service_module():
    fakes = _install_fake_app_modules()
    sys.modules.pop("app.alerts.service", None)
    import importlib
    mod = importlib.import_module("app.alerts.service")
    importlib.reload(mod)
    mod._fakes = fakes
    yield mod
    sys.modules.pop("app.alerts.service", None)


def _mock_list_response(rows, service_module):
    mock_query = MagicMock()
    mock_query.execute.return_value = MagicMock(data=rows)
    chain = service_module.supabase_admin.table.return_value
    chain.select.return_value.eq.return_value.order.return_value.limit.return_value = mock_query
    return mock_query


class TestListForElderErrorHandling:
    def test_transient_supabase_failure_returns_503_not_an_unhandled_500(self, service_module):
        from fastapi import HTTPException

        mock_query = MagicMock()
        mock_query.execute.side_effect = Exception("Server disconnected")
        chain = service_module.supabase_admin.table.return_value
        chain.select.return_value.eq.return_value.order.return_value.range.return_value = mock_query

        with pytest.raises(HTTPException) as exc_info:
            service_module.AlertService.list_for_elder("elder-123", limit=100, offset=400)

        assert exc_info.value.status_code == 503

    def test_successful_fetch_still_returns_normal_shape(self, service_module):
        mock_query = MagicMock()
        mock_query.execute.return_value = MagicMock(data=[{"id": "a1"}, {"id": "a2"}])
        chain = service_module.supabase_admin.table.return_value
        chain.select.return_value.eq.return_value.order.return_value.range.return_value = mock_query

        result = service_module.AlertService.list_for_elder("elder-123", limit=20, offset=0)

        assert result == {"success": True, "count": 2, "results": [{"id": "a1"}, {"id": "a2"}]}

    def test_genuine_empty_history_is_not_an_error(self, service_module):
        """Section 5 requirement: 'Genuine empty history returns a
        valid empty response rather than an error.'"""
        mock_query = MagicMock()
        mock_query.execute.return_value = MagicMock(data=[])
        chain = service_module.supabase_admin.table.return_value
        chain.select.return_value.eq.return_value.order.return_value.range.return_value = mock_query

        result = service_module.AlertService.list_for_elder("elder-with-no-history")

        assert result == {"success": True, "count": 0, "results": []}


class TestFindRecentOpenEpisode:
    def test_matching_recent_alert_is_recognized_as_open_episode(self, service_module):
        now = datetime.now(timezone.utc)
        recent_row = {
            "id": "alert-1",
            "fall_type": "fall_forward",
            "alert_type": "Emergency Alert",
            "created_at": (now - timedelta(seconds=3)).isoformat(),
            "episode_id": "episode-xyz",
        }
        _mock_list_response([recent_row], service_module)

        result = service_module.AlertService.find_recent_open_episode("elder-1", fall_type="fall_forward")

        assert result == recent_row

    def test_old_alert_outside_window_is_not_recognized(self, service_module):
        """The backstop must only cover a short recovery window, not
        merge distinct falls separated by a real gap."""
        now = datetime.now(timezone.utc)
        old_row = {
            "id": "alert-1",
            "fall_type": "fall_forward",
            "alert_type": "Emergency Alert",
            "created_at": (now - timedelta(minutes=5)).isoformat(),
            "episode_id": "episode-xyz",
        }
        _mock_list_response([old_row], service_module)

        result = service_module.AlertService.find_recent_open_episode("elder-1", fall_type="fall_forward")

        assert result is None

    def test_different_fall_type_is_not_recognized_as_the_same_episode(self, service_module):
        now = datetime.now(timezone.utc)
        recent_row = {
            "id": "alert-1",
            "fall_type": "fall_backward",
            "alert_type": "Emergency Alert",
            "created_at": (now - timedelta(seconds=2)).isoformat(),
        }
        _mock_list_response([recent_row], service_module)

        result = service_module.AlertService.find_recent_open_episode("elder-1", fall_type="fall_forward")

        assert result is None

    def test_no_history_at_all_returns_none(self, service_module):
        _mock_list_response([], service_module)

        result = service_module.AlertService.find_recent_open_episode("elder-1", fall_type="fall_forward")

        assert result is None

    def test_lookup_failure_fails_safe_returns_none_not_raises(self, service_module):
        """If the backstop CHECK itself can't reach Supabase, it must
        not block a real alert from being created — fail open, log,
        and return None rather than raising."""
        chain = service_module.supabase_admin.table.return_value
        chain.select.return_value.eq.return_value.order.return_value.limit.return_value.execute.side_effect = (
            Exception("Server disconnected")
        )

        result = service_module.AlertService.find_recent_open_episode("elder-1", fall_type="fall_forward")

        assert result is None
