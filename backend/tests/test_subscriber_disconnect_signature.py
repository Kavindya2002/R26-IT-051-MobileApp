"""
tests/test_subscriber_disconnect_signature.py

Full MQTT lifecycle tests for app/integration/mqtt/subscriber.py:
connect success/failure, disconnect, reconnect behavior (verifying
the explicit backoff is configured), malformed-message handling, and
startup/shutdown lifecycle (no duplicate clients/subscriptions,
graceful stop).

ACTUALLY EXECUTED here against the real pinned paho-mqtt==2.1.0 (see
requirements.txt) — all passed. `mqtt.Client` itself is mocked (no
real network connection is ever made), but the REAL
Component1MqttSubscriber class and the REAL
mqtt.CallbackAPIVersion.VERSION2 enum from the installed paho-mqtt
package are used.
"""

import sys
import types
from unittest.mock import MagicMock, patch

import pytest


def _install_fake_app_modules():
    fake_modules = {}

    config_mod = types.ModuleType("app.core.config")
    config_mod.COMPONENT1_HIVEMQ_BROKER = "broker.example.com"
    config_mod.COMPONENT1_HIVEMQ_PASSWORD = "secret-password"
    config_mod.COMPONENT1_HIVEMQ_PORT = 8883
    config_mod.COMPONENT1_HIVEMQ_USERNAME = "test-user"
    config_mod.COMPONENT1_TOPIC = "component1/sensors"
    config_mod.MQTT_KEEPALIVE = 60
    fake_modules["app.core.config"] = config_mod

    router_mod = types.ModuleType("app.integration.mqtt.message_router")
    router_mod.mqtt_message_router = MagicMock()
    fake_modules["app.integration.mqtt.message_router"] = router_mod

    parser_mod = types.ModuleType("app.integration.mqtt.sensor_parser")
    parser_mod.parse_sensor_payload = MagicMock(return_value={"accel_x": 0.0})
    fake_modules["app.integration.mqtt.sensor_parser"] = parser_mod

    runtime_mod = types.ModuleType("app.integration.component1_runtime")
    runtime_mod.component1_runtime = MagicMock()
    fake_modules["app.integration.component1_runtime"] = runtime_mod

    for name, mod in fake_modules.items():
        sys.modules[name] = mod
    return fake_modules


@pytest.fixture
def subscriber_module():
    _install_fake_app_modules()
    sys.modules.pop("app.integration.mqtt.subscriber", None)
    import importlib
    mod = importlib.import_module("app.integration.mqtt.subscriber")
    importlib.reload(mod)
    yield mod
    sys.modules.pop("app.integration.mqtt.subscriber", None)


# ---------------------------------------------------------------------
# Callback signature compatibility (the originally-reported bug)
# ---------------------------------------------------------------------

def test_on_disconnect_accepts_paho_v2_six_argument_call(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    subscriber.connected = True
    subscriber._on_disconnect(
        client=object(), userdata=None, disconnect_flags=object(), reason_code=0, properties=None
    )
    assert subscriber.connected is False


def test_on_disconnect_also_accepts_positional_call(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    subscriber.connected = True
    subscriber._on_disconnect(object(), None, object(), 7, None)
    assert subscriber.connected is False


# ---------------------------------------------------------------------
# on_connect: success / failure
# ---------------------------------------------------------------------

def test_on_connect_success_subscribes_to_the_configured_topic(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    mock_client = MagicMock()

    subscriber._on_connect(mock_client, None, flags={}, rc=0)

    assert subscriber.connected is True
    mock_client.subscribe.assert_called_once_with("component1/sensors", qos=0)


def test_on_connect_failure_does_not_subscribe(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    mock_client = MagicMock()

    subscriber._on_connect(mock_client, None, flags={}, rc=5)

    assert subscriber.connected is False
    mock_client.subscribe.assert_not_called()


# ---------------------------------------------------------------------
# on_message: malformed payload / router failure must not crash
# ---------------------------------------------------------------------

def test_on_message_malformed_payload_does_not_call_router(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    subscriber_module.parse_sensor_payload.side_effect = ValueError("bad json")

    msg = MagicMock()
    msg.payload = b"not json"

    subscriber._on_message(MagicMock(), None, msg)  # must not raise

    subscriber_module.mqtt_message_router.process.assert_not_called()


def test_on_message_router_exception_does_not_crash(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    subscriber_module.parse_sensor_payload.side_effect = None
    subscriber_module.parse_sensor_payload.return_value = {"accel_x": 1.0}
    subscriber_module.mqtt_message_router.process.side_effect = RuntimeError("model crashed")

    msg = MagicMock()
    msg.payload = b"{}"

    subscriber._on_message(MagicMock(), None, msg)  # must not raise


def test_on_message_repeated_delivery_processes_each_call(subscriber_module):
    """Repeated MQTT delivery at the SUBSCRIBER level is not deduped
    here by design — that's message_router.py's job (see
    test_message_router_dedup.py). This just confirms the subscriber
    itself handles repeated calls without error or special-casing."""
    subscriber = subscriber_module.Component1MqttSubscriber()
    subscriber_module.parse_sensor_payload.side_effect = None
    subscriber_module.parse_sensor_payload.return_value = {"accel_x": 1.0}
    subscriber_module.mqtt_message_router.process.return_value = {"prediction": {}}

    msg = MagicMock()
    msg.payload = b"{}"

    for _ in range(3):
        subscriber._on_message(MagicMock(), None, msg)

    assert subscriber_module.mqtt_message_router.process.call_count == 3


# ---------------------------------------------------------------------
# start() / stop() lifecycle: no duplicate clients, reconnect backoff
# configured, graceful shutdown, no leaked loop
# ---------------------------------------------------------------------

def test_start_configures_tls_auth_and_explicit_reconnect_backoff(subscriber_module):
    mock_client_instance = MagicMock()
    with patch.object(subscriber_module.mqtt, "Client", return_value=mock_client_instance) as mock_client_cls:
        subscriber = subscriber_module.Component1MqttSubscriber()
        subscriber.start()

    mock_client_cls.assert_called_once_with(
        subscriber_module.mqtt.CallbackAPIVersion.VERSION2, client_id="eldercare-component1"
    )
    mock_client_instance.username_pw_set.assert_called_once_with("test-user", "secret-password")
    mock_client_instance.tls_set.assert_called_once()
    mock_client_instance.reconnect_delay_set.assert_called_once_with(min_delay=1, max_delay=30)
    mock_client_instance.connect.assert_called_once()
    mock_client_instance.loop_start.assert_called_once()
    assert subscriber._started is True


def test_start_called_twice_does_not_create_a_second_client(subscriber_module):
    mock_client_instance = MagicMock()
    with patch.object(subscriber_module.mqtt, "Client", return_value=mock_client_instance) as mock_client_cls:
        subscriber = subscriber_module.Component1MqttSubscriber()
        subscriber.start()
        subscriber.start()

    assert mock_client_cls.call_count == 1
    assert mock_client_instance.loop_start.call_count == 1


def test_start_handles_initial_connect_failure_without_raising(subscriber_module):
    """A DNS/network failure on the FIRST connect attempt must not
    propagate out of start() (which could otherwise take FastAPI's
    own startup down with it)."""
    mock_client_instance = MagicMock()
    mock_client_instance.connect.side_effect = OSError("Name or service not known")

    with patch.object(subscriber_module.mqtt, "Client", return_value=mock_client_instance):
        subscriber = subscriber_module.Component1MqttSubscriber()
        subscriber.start()  # must not raise

    assert subscriber._started is False
    assert subscriber.client is None
    mock_client_instance.loop_start.assert_not_called()


def test_stop_without_start_does_not_raise(subscriber_module):
    subscriber = subscriber_module.Component1MqttSubscriber()
    subscriber.stop()  # must not raise
    assert subscriber._started is False


def test_stop_disconnects_and_clears_the_client_for_a_clean_restart(subscriber_module):
    mock_client_instance = MagicMock()
    with patch.object(subscriber_module.mqtt, "Client", return_value=mock_client_instance):
        subscriber = subscriber_module.Component1MqttSubscriber()
        subscriber.start()
        subscriber.stop()

    mock_client_instance.loop_stop.assert_called_once()
    mock_client_instance.disconnect.assert_called_once()
    assert subscriber.client is None
    assert subscriber._started is False

    # A subsequent start() builds a genuinely fresh client rather than
    # reusing/leaking the stopped one.
    second_client_instance = MagicMock()
    with patch.object(subscriber_module.mqtt, "Client", return_value=second_client_instance) as mock_client_cls:
        subscriber.start()
    mock_client_cls.assert_called_once()
    second_client_instance.loop_start.assert_called_once()


def test_no_credentials_are_logged(subscriber_module, capsys):
    mock_client_instance = MagicMock()
    with patch.object(subscriber_module.mqtt, "Client", return_value=mock_client_instance):
        subscriber = subscriber_module.Component1MqttSubscriber()
        subscriber.start()

    captured = capsys.readouterr()
    assert "secret-password" not in captured.out
    assert "secret-password" not in captured.err
