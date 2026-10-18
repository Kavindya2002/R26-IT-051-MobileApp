"""
tests/test_message_router_dedup.py

Unit tests for the duplicate-alert fix in
app/integration/mqtt/message_router.py, including the restart/
concurrency-safe database backstop (AlertService.find_recent_open_episode).

ACTUALLY EXECUTED in the delivery environment against the real
message_router.py logic (every app.* import it makes is faked out —
see _install_fake_app_modules — but the module under test itself is
imported and run for real, not mocked). Run again in the real repo as
a sanity check: `pytest tests/test_message_router_dedup.py -v`.
"""

import sys
import types
import uuid
from unittest.mock import MagicMock

import pytest


def _install_fake_app_modules():
    fake_modules = {}

    alerts_service_mod = types.ModuleType("app.alerts.service")
    alerts_service_mod.AlertService = MagicMock()
    alerts_service_mod.AlertService.find_recent_open_episode.return_value = None
    fake_modules["app.alerts.service"] = alerts_service_mod

    router_mod = types.ModuleType("app.component1.api.router")
    router_mod.store_prediction = MagicMock()
    fake_modules["app.component1.api.router"] = router_mod

    feedback_mod = types.ModuleType("app.component4.guidance.feedback.feedback_controller")
    feedback_mod.guidance_feedback_controller = MagicMock()
    fake_modules["app.component4.guidance.feedback.feedback_controller"] = feedback_mod

    config_mod = types.ModuleType("app.core.config")
    config_mod.DEFAULT_ELDER_ID = "test-elder-id"
    fake_modules["app.core.config"] = config_mod

    adapter_mod = types.ModuleType("app.integration.component1_adapter")
    adapter_mod.component1_adapter = MagicMock()
    fake_modules["app.integration.component1_adapter"] = adapter_mod

    runtime_mod = types.ModuleType("app.integration.component1_runtime")
    runtime_mod.component1_runtime = MagicMock()
    fake_modules["app.integration.component1_runtime"] = runtime_mod

    pipeline_mod = types.ModuleType("app.integration.pipeline")
    pipeline_mod.elder_care_pipeline = MagicMock()
    fake_modules["app.integration.pipeline"] = pipeline_mod

    ws_mod = types.ModuleType("app.realtime.websocket_manager")
    ws_mod.connection_manager = MagicMock()
    fake_modules["app.realtime.websocket_manager"] = ws_mod

    for name, mod in fake_modules.items():
        sys.modules[name] = mod
    return fake_modules


@pytest.fixture
def router_module():
    fakes = _install_fake_app_modules()
    sys.modules.pop("app.integration.mqtt.message_router", None)
    import importlib
    mod = importlib.import_module("app.integration.mqtt.message_router")
    importlib.reload(mod)
    mod._fakes = fakes
    yield mod
    sys.modules.pop("app.integration.mqtt.message_router", None)


def _make_component1_result(fall_detected: bool, fall_type: str = "fall_forward", risk_level: str = "CRITICAL"):
    return {
        "fall_detected": fall_detected,
        "fall_type": fall_type,
        "risk_level": risk_level,
        "movement": "falling",
        "confidence": 91.31,
        "explanation": "test explanation",
    }


def _ok_pipeline_result(alert_id="alert-001"):
    """A SUCCESSFULLY PERSISTED alert — alert_id must be present, or
    the new persistence-failure-retry logic will (correctly) refuse to
    lock the episode open."""
    return {
        "component4": {"alert": "Emergency Alert", "confidence": 91.31, "guidance": {}},
        "alert_id": alert_id,
    }


class TestFallEpisodeDeduplication:
    def test_single_sustained_fall_creates_only_one_alert(self, router_module):
        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router_module.component1_runtime.load.return_value = {}
        router_module.elder_care_pipeline.predict.return_value = _ok_pipeline_result()
        router_module.guidance_feedback_controller.process_sensor.return_value = {"active": False}

        router = router_module.MQTTMessageRouter()

        for _ in range(20):
            router.process({"accel_x": 1, "accel_y": 1, "accel_z": 1, "gyro_x": 0, "gyro_y": 0, "gyro_z": 0})

        assert router_module.elder_care_pipeline.predict.call_count == 1

    def test_recovery_then_new_fall_creates_a_second_alert(self, router_module):
        router_module.component1_runtime.load.return_value = {}
        router_module.elder_care_pipeline.predict.return_value = _ok_pipeline_result()
        router_module.guidance_feedback_controller.process_sensor.return_value = {"active": False}

        router = router_module.MQTTMessageRouter()

        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router.process({"x": 1})
        router.process({"x": 1})

        router_module.component1_adapter.predict.return_value = _make_component1_result(False, risk_level="LOW")
        router.process({"x": 1})

        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router.process({"x": 1})
        router.process({"x": 1})

        assert router_module.elder_care_pipeline.predict.call_count == 2

    def test_each_episode_gets_its_own_stable_id(self, router_module):
        router_module.component1_runtime.load.return_value = {}
        router_module.elder_care_pipeline.predict.return_value = _ok_pipeline_result()
        router_module.guidance_feedback_controller.process_sensor.return_value = {"active": False}

        router = router_module.MQTTMessageRouter()

        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router.process({"x": 1})
        first_episode_id = router._fall_episode_id
        router.process({"x": 1})
        assert router._fall_episode_id == first_episode_id
        uuid.UUID(first_episode_id)  # does not raise -> a real uuid

        router_module.component1_adapter.predict.return_value = _make_component1_result(False, risk_level="LOW")
        router.process({"x": 1})
        assert router._fall_episode_id is None

        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router.process({"x": 1})
        second_episode_id = router._fall_episode_id
        assert second_episode_id != first_episode_id

    def test_pipeline_exception_does_not_permanently_lock_the_episode(self, router_module):
        router_module.component1_runtime.load.return_value = {}
        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router_module.guidance_feedback_controller.process_sensor.return_value = {"active": False}

        router = router_module.MQTTMessageRouter()

        router_module.elder_care_pipeline.predict.side_effect = RuntimeError("Component 4 is down")
        router.process({"x": 1})
        assert router._fall_episode_active is False

        router_module.elder_care_pipeline.predict.side_effect = None
        router_module.elder_care_pipeline.predict.return_value = _ok_pipeline_result()
        router.process({"x": 1})
        assert router_module.elder_care_pipeline.predict.call_count == 2

    def test_persistence_failure_does_not_lock_episode_and_retries_next_sample(self, router_module):
        """Section 3/4 requirement: 'A failed database write must not
        incorrectly mark an event as successfully persisted' / 'An
        alert persistence failure followed by a retry'. If
        AlertService.create() failed inside the pipeline (alert_id is
        None even though elder_id was provided), the episode must NOT
        be locked "active" with nothing recorded for it — the very
        next sample should get another real attempt."""
        router_module.component1_runtime.load.return_value = {}
        router_module.component1_adapter.predict.return_value = _make_component1_result(True)
        router_module.guidance_feedback_controller.process_sensor.return_value = {"active": False}

        router = router_module.MQTTMessageRouter()

        # First sample: pipeline "succeeds" (no exception) but the
        # write itself failed -> alert_id is None.
        router_module.elder_care_pipeline.predict.return_value = {
            "component4": {"alert": "Emergency Alert", "confidence": 91.31, "guidance": {}},
            "alert_id": None,
        }
        router.process({"x": 1})
        assert router._fall_episode_active is False

        # Second sample (still the same real fall): this time the
        # write succeeds -> must actually try again, not skip.
        router_module.elder_care_pipeline.predict.return_value = _ok_pipeline_result()
        router.process({"x": 1})
        assert router_module.elder_care_pipeline.predict.call_count == 2
        assert router._fall_episode_active is True


class TestRestartRecoveryBackstop:
    """Covers requirement: 'A backend restart must not automatically
    allow a previously processed event to be inserted again.' Since
    in-memory state is lost on restart, these simulate a FRESH router
    instance (as if just restarted) seeing a sample for a fall that
    was already alerted moments earlier, per
    AlertService.find_recent_open_episode()."""

    def test_restart_recovers_open_episode_without_creating_a_duplicate_alert(self, router_module):
        router_module.component1_runtime.load.return_value = {}
        router_module.component1_adapter.predict.return_value = _make_component1_result(
            True, fall_type="fall_forward"
        )

        router_module.AlertService.find_recent_open_episode.return_value = {
            "id": "alert-already-saved",
            "fall_type": "fall_forward",
            "alert_type": "Emergency Alert",
            "episode_id": "episode-abc",
        }

        # A fresh router instance, as if the process just restarted.
        router = router_module.MQTTMessageRouter()
        router.process({"x": 1})

        router_module.elder_care_pipeline.predict.assert_not_called()
        assert router._fall_episode_active is True
        assert router._fall_episode_id == "episode-abc"

    def test_distinct_fall_type_is_not_treated_as_a_recovered_episode(self, router_module):
        """The backstop only matches on fall_type — a genuinely
        different fall_type must still create its own new alert even
        if some other alert was created moments ago."""
        router_module.component1_runtime.load.return_value = {}
        router_module.component1_adapter.predict.return_value = _make_component1_result(
            True, fall_type="fall_backward"
        )
        router_module.elder_care_pipeline.predict.return_value = _ok_pipeline_result()

        router_module.AlertService.find_recent_open_episode.return_value = None

        router = router_module.MQTTMessageRouter()
        router.process({"x": 1})

        router_module.elder_care_pipeline.predict.assert_called_once()
        router_module.AlertService.find_recent_open_episode.assert_called_once_with(
            "test-elder-id", fall_type="fall_backward"
        )
