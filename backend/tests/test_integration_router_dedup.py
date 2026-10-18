"""
Tests for the duplicate-alert guard added to
app/integration/router.py's /component1-to-component4 endpoint.
"""

from unittest.mock import patch

import pytest
from fastapi import HTTPException

from app.integration.router import component1_to_component4, Component1ToComponent4Request


def _make_request(elder_id="elder-123", fall_detected=True, fall_type="fall_forward"):
    return Component1ToComponent4Request(
        component1={
            "fall_detected": fall_detected,
            "fall_type": fall_type,
            "risk_level": "HIGH",
            "movement": "Unstable",
            "confidence": 90.0,
        },
        component2={"location": "Bedroom", "time": "unknown"},
        user={"age": 80, "previous_falls": 1, "assistive_device": "cane"},
        elder_id=elder_id,
    )


class TestDuplicateGuard:
    def test_no_recent_alert_calls_pipeline_normally(self):
        request = _make_request()
        with patch("app.integration.router.AlertService.find_recent_open_episode", return_value=None) as mock_find, \
             patch("app.integration.router.elder_care_pipeline.predict", return_value={
                 "status": "success",
                 "integration": "Component 1 -> Component 4",
                 "component1": request.component1.model_dump(),
                 "component4": {"alert": "Emergency Alert", "confidence": 90.0},
                 "alert_id": "new-alert-id",
             }) as mock_predict:
            result = component1_to_component4(request)

        mock_find.assert_called_once_with(elder_id="elder-123", fall_type="fall_forward")
        mock_predict.assert_called_once()
        assert result["alert_id"] == "new-alert-id"
        assert "duplicate_of_recent_alert" not in result

    def test_recent_alert_skips_pipeline_and_returns_existing(self):
        request = _make_request()
        existing_alert = {
            "id": "existing-alert-id",
            "alert_type": "Emergency Alert",
            "confidence": 93.0,
            "fall_type": "fall_forward",
        }
        with patch("app.integration.router.AlertService.find_recent_open_episode", return_value=existing_alert), \
             patch("app.integration.router.elder_care_pipeline.predict") as mock_predict:
            result = component1_to_component4(request)

        mock_predict.assert_not_called()
        assert result["alert_id"] == "existing-alert-id"
        assert result["duplicate_of_recent_alert"] is True
        assert result["component4"]["alert"] == "Emergency Alert"

    def test_fall_detected_false_never_checks_for_duplicates(self):
        request = _make_request(fall_detected=False, fall_type="No Fall")
        with patch("app.integration.router.AlertService.find_recent_open_episode") as mock_find, \
             patch("app.integration.router.elder_care_pipeline.predict", return_value={"status": "success"}) as mock_predict:
            component1_to_component4(request)

        mock_find.assert_not_called()
        mock_predict.assert_called_once()

    def test_no_elder_id_skips_duplicate_check(self):
        request = _make_request(elder_id=None)
        with patch("app.integration.router.AlertService.find_recent_open_episode") as mock_find, \
             patch("app.integration.router.elder_care_pipeline.predict", return_value={"status": "success"}) as mock_predict:
            component1_to_component4(request)

        mock_find.assert_not_called()
        mock_predict.assert_called_once()

    def test_pipeline_value_error_still_returns_400(self):
        request = _make_request()
        with patch("app.integration.router.AlertService.find_recent_open_episode", return_value=None), \
             patch("app.integration.router.elder_care_pipeline.predict", side_effect=ValueError("missing field")):
            with pytest.raises(HTTPException) as exc_info:
                component1_to_component4(request)

        assert exc_info.value.status_code == 400

    def test_pipeline_unexpected_error_still_returns_500(self):
        request = _make_request()
        with patch("app.integration.router.AlertService.find_recent_open_episode", return_value=None), \
             patch("app.integration.router.elder_care_pipeline.predict", side_effect=RuntimeError("boom")):
            with pytest.raises(HTTPException) as exc_info:
                component1_to_component4(request)

        assert exc_info.value.status_code == 500

    def test_duplicate_check_itself_raising_is_not_silently_swallowed(self):
        request = _make_request()
        with patch("app.integration.router.AlertService.find_recent_open_episode", side_effect=RuntimeError("db down")):
            with pytest.raises(HTTPException) as exc_info:
                component1_to_component4(request)

        assert exc_info.value.status_code == 500