import base64
import importlib.util
import sys
import unittest
import unittest.mock
from pathlib import Path
from urllib.parse import quote


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = (
    REPO_ROOT
    / "native/macos/Fae/Sources/Fae/Resources/Skills/collaborate/scripts"
)
NO_BODY = object()


def load_script(module_name, filename):
    spec = importlib.util.spec_from_file_location(module_name, SCRIPT_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


forwards = load_script("collaborate_forwards_contract", "forwards.py")
stores = load_script("collaborate_stores_contract", "stores.py")
kanban = load_script("collaborate_kanban_contract", "kanban.py")
swarm = load_script("collaborate_swarm_contract", "swarm.py")


class RecordingClient:
    def __init__(self, response=None, error=None):
        self.response = {} if response is None else response
        self.error = error
        self.calls = []

    def _call(self, method, path, body=NO_BODY):
        self.calls.append((method, path, body))
        if self.error is not None:
            raise self.error
        return self.response

    def get(self, path):
        return self._call("GET", path)

    def post(self, path, body=NO_BODY):
        return self._call("POST", path, body)

    def put(self, path, body=NO_BODY):
        return self._call("PUT", path, body)

    def delete(self, path):
        return self._call("DELETE", path)


class CollaborateSkillScriptContractTests(unittest.TestCase):
    PEER_AGENT = "a" * 64
    STORE_ID = "team/store?rev=1#west coast"
    KEY = "profile/name?lang=en#preferred value"
    ENCODED_STORE_ID = quote(STORE_ID, safe="")
    ENCODED_KEY = quote(KEY, safe="")

    def test_forwards_add_posts_exact_contract(self):
        client = RecordingClient(response={"local_addr": "127.0.0.1:15432"})

        forwards.do_add(
            client,
            {
                "local_addr": "127.0.0.1:15432",
                "peer_agent": self.PEER_AGENT.upper(),
                "target_host": "127.0.0.2",
                "target_port": "443",
                "ignored": "must not reach the daemon",
            },
        )

        self.assertEqual(
            client.calls,
            [
                (
                    "POST",
                    "/forwards",
                    {
                        "local_addr": "127.0.0.1:15432",
                        "peer_agent": self.PEER_AGENT,
                        "target_host": "127.0.0.2",
                        "target_port": 443,
                    },
                )
            ],
        )

    def test_forwards_list_gets_exact_contract(self):
        client = RecordingClient(response={"forwards": []})

        forwards.do_list(client)

        self.assertEqual(client.calls, [("GET", "/forwards", NO_BODY)])

    def test_forwards_rm_deletes_percent_encoded_local_address(self):
        client = RecordingClient(response={"removed": True})

        forwards.do_rm(client, {"local_addr": "127.0.0.1:15432"})

        self.assertEqual(
            client.calls,
            [("DELETE", "/forwards/127.0.0.1%3A15432", NO_BODY)],
        )

    def test_stores_list_gets_exact_contract(self):
        client = RecordingClient(response={"stores": []})

        stores.do_list(client)

        self.assertEqual(client.calls, [("GET", "/stores", NO_BODY)])

    def test_stores_create_posts_exact_contract(self):
        client = RecordingClient(response={"id": "created-store"})

        stores.do_create(
            client,
            {
                "name": " Shared plans ",
                "topic": " fae/project ",
                "ignored": "must not reach the daemon",
            },
        )

        self.assertEqual(
            client.calls,
            [
                (
                    "POST",
                    "/stores",
                    {"name": "Shared plans", "topic": "fae/project"},
                )
            ],
        )

    def test_stores_join_posts_bodyless_encoded_store_id(self):
        client = RecordingClient(response={"id": self.STORE_ID})

        stores.do_join(client, {"store_id": self.STORE_ID})

        self.assertEqual(
            client.calls,
            [("POST", f"/stores/{self.ENCODED_STORE_ID}/join", NO_BODY)],
        )

    def test_stores_keys_gets_encoded_store_id(self):
        client = RecordingClient(response={"keys": []})

        stores.do_keys(client, {"store_id": self.STORE_ID})

        self.assertEqual(
            client.calls,
            [("GET", f"/stores/{self.ENCODED_STORE_ID}/keys", NO_BODY)],
        )

    def test_stores_get_gets_each_encoded_path_segment(self):
        client = RecordingClient(response={"key": self.KEY, "value": "aGVsbG8="})

        stores.do_get(client, {"store_id": self.STORE_ID, "key": self.KEY})

        self.assertEqual(
            client.calls,
            [
                (
                    "GET",
                    f"/stores/{self.ENCODED_STORE_ID}/{self.ENCODED_KEY}",
                    NO_BODY,
                )
            ],
        )

    def test_stores_set_puts_encoded_segments_and_base64_body(self):
        client = RecordingClient()
        value = "hello / 日本語"
        encoded_value = base64.b64encode(value.encode("utf-8")).decode("ascii")
        path = f"/stores/{self.ENCODED_STORE_ID}/{self.ENCODED_KEY}"

        stores.do_set(
            client,
            {
                "store_id": self.STORE_ID,
                "key": self.KEY,
                "value": value,
                "content_type": "text/plain; charset=utf-8",
            },
        )
        stores.do_set(
            client,
            {"store_id": self.STORE_ID, "key": self.KEY, "value": ""},
        )

        self.assertEqual(
            client.calls,
            [
                (
                    "PUT",
                    path,
                    {
                        "value": encoded_value,
                        "content_type": "text/plain; charset=utf-8",
                    },
                ),
                ("PUT", path, {"value": ""}),
            ],
        )

    def test_stores_rm_deletes_bodyless_encoded_segments(self):
        client = RecordingClient()

        stores.do_rm(client, {"store_id": self.STORE_ID, "key": self.KEY})

        self.assertEqual(
            client.calls,
            [
                (
                    "DELETE",
                    f"/stores/{self.ENCODED_STORE_ID}/{self.ENCODED_KEY}",
                    NO_BODY,
                )
            ],
        )

    def test_invalid_forward_inputs_fail_before_client_call(self):
        cases = [
            {
                "local_addr": "not-an-address",
                "peer_agent": self.PEER_AGENT,
                "target_host": "127.0.0.1",
                "target_port": 443,
            },
            {
                "local_addr": "127.0.0.1:15432",
                "peer_agent": "not-an-agent-id",
                "target_host": "127.0.0.1",
                "target_port": 443,
            },
            {
                "local_addr": "127.0.0.1:15432",
                "peer_agent": self.PEER_AGENT,
                "target_host": "127.0.0.1",
                "target_port": 0,
            },
            {
                "local_addr": "127.0.0.1:15432",
                "peer_agent": self.PEER_AGENT,
                "target_host": "127.0.0.1",
                "target_port": 22.5,
            },
        ]
        for params in cases:
            with self.subTest(params=params):
                client = RecordingClient()
                with self.assertRaises(forwards.X0xError):
                    forwards.do_add(client, params)
                self.assertEqual(client.calls, [])

    def test_non_loopback_forward_inputs_fail_before_client_call(self):
        cases = [
            {
                "local_addr": "192.0.2.10:15432",
                "peer_agent": self.PEER_AGENT,
                "target_host": "127.0.0.1",
                "target_port": 443,
            },
            {
                "local_addr": "127.0.0.1:15432",
                "peer_agent": self.PEER_AGENT,
                "target_host": "192.0.2.20",
                "target_port": 443,
            },
        ]
        for params in cases:
            with self.subTest(params=params):
                client = RecordingClient()
                with self.assertRaises(forwards.X0xError):
                    forwards.do_add(client, params)
                self.assertEqual(client.calls, [])

    def test_missing_store_inputs_fail_before_client_call(self):
        cases = [
            (stores.do_join, {}),
            (stores.do_keys, {}),
            (stores.do_get, {"key": self.KEY}),
            (stores.do_set, {"key": self.KEY, "value": "value"}),
            (stores.do_rm, {"key": self.KEY}),
            (stores.do_get, {"store_id": self.STORE_ID}),
            (stores.do_set, {"store_id": self.STORE_ID, "value": "value"}),
            (stores.do_rm, {"store_id": self.STORE_ID}),
            (stores.do_set, {"store_id": self.STORE_ID, "key": self.KEY}),
        ]
        for action, params in cases:
            with self.subTest(action=action.__name__, params=params):
                client = RecordingClient()
                with self.assertRaises(stores.X0xError):
                    action(client, params)
                self.assertEqual(client.calls, [])

    def test_x0x_errors_are_voice_safe_bounded_and_redacted(self):
        marker = "MARKER_SECRET_DO_NOT_SPEAK"
        raw_detail = f"{marker}: bearer token and daemon traceback"
        cases = [
            (forwards.do_list, ()),
            (
                forwards.do_add,
                (
                    {
                        "local_addr": "127.0.0.1:15432",
                        "peer_agent": self.PEER_AGENT,
                        "target_host": "127.0.0.1",
                        "target_port": 443,
                    },
                ),
            ),
            (forwards.do_rm, ({"local_addr": "127.0.0.1:15432"},)),
            (stores.do_list, ()),
            (stores.do_create, ({"name": "plans", "topic": "fae/plans"},)),
            (stores.do_join, ({"store_id": self.STORE_ID},)),
            (stores.do_keys, ({"store_id": self.STORE_ID},)),
            (stores.do_get, ({"store_id": self.STORE_ID, "key": self.KEY},)),
            (
                stores.do_set,
                ({"store_id": self.STORE_ID, "key": self.KEY, "value": "value"},),
            ),
            (stores.do_rm, ({"store_id": self.STORE_ID, "key": self.KEY},)),
        ]
        for action, args in cases:
            with self.subTest(action=action.__name__):
                client = RecordingClient(error=stores.X0xError(raw_detail))
                with self.assertRaises(stores.X0xError) as raised:
                    action(client, *args)
                message = str(raised.exception)
                self.assertNotIn(marker, message)
                self.assertNotIn(raw_detail, message)
                self.assertLessEqual(len(message), 200)
                self.assertEqual(len(client.calls), 1)


class Retry404Client:
    """Stub that raises X0xError('...HTTP 404...') for the first N GET calls, then succeeds.

    Mirrors RecordingClient's call-log format so assertions can inspect the sequence.
    """

    def __init__(self, fail_count: int, success_response: dict | None = None):
        self.fail_count = fail_count
        self._get_count = 0
        self.calls: list = []
        self.success_response = {} if success_response is None else success_response

    def get(self, path):
        self._get_count += 1
        self.calls.append(("GET", path, NO_BODY))
        if self._get_count <= self.fail_count:
            raise kanban.X0xError(
                f"x0x request failed (GET {path}): HTTP 404 — state not recovered yet"
            )
        return self.success_response

    def post(self, path, body=NO_BODY):
        self.calls.append(("POST", path, body))
        return self.success_response

    def put(self, path, body=NO_BODY):
        self.calls.append(("PUT", path, body))
        return self.success_response

    def delete(self, path):
        self.calls.append(("DELETE", path, NO_BODY))
        return self.success_response


class SubscribeFailClient:
    """Stub where POST /subscribe raises X0xError but every other call succeeds."""

    def __init__(self, success_response: dict | None = None):
        self.calls: list = []
        self.success_response = {} if success_response is None else success_response

    def post(self, path, body=NO_BODY):
        self.calls.append(("POST", path, body))
        if "/subscribe" in path:
            raise swarm.X0xError("subscription refused — daemon internal error")
        return self.success_response

    def get(self, path):
        self.calls.append(("GET", path, NO_BODY))
        return self.success_response


class CollaborateSkillGotchasTests(unittest.TestCase):
    """Tests for live-proven x0x operational gotchas encoded in kanban, stores, swarm."""

    # ---- kanban retry on 404 ------------------------------------------------

    @unittest.mock.patch("time.sleep")
    def test_kanban_list_retries_on_404_and_recovers(self, mock_sleep):
        client = Retry404Client(fail_count=2, success_response={"lists": []})
        result = kanban.do_list(client)
        self.assertTrue(result["ok"])
        self.assertEqual(result["count"], 0)
        # 2 failures + 1 success = 3 total GET calls
        self.assertEqual(len(client.calls), 3)
        self.assertTrue(all(m == "GET" for m, _, _ in client.calls))
        # 2 sleeps between the 3 attempts
        self.assertEqual(mock_sleep.call_count, 2)
        # Each sleep must be the configured delay (4.0 s)
        for call_args in mock_sleep.call_args_list:
            self.assertEqual(call_args.args[0], 4.0)

    @unittest.mock.patch("time.sleep")
    def test_kanban_list_raises_restart_hint_after_retries_exhaust(self, mock_sleep):
        # 4 failures exhaust all 4 attempts (initial + 3 retries)
        client = Retry404Client(fail_count=4, success_response={"lists": []})
        with self.assertRaises(kanban.X0xError) as raised:
            kanban.do_list(client)
        msg = str(raised.exception)
        self.assertIn("daemon", msg.lower())
        self.assertIn("recovering", msg.lower())
        self.assertLessEqual(len(msg), 200)
        # All 4 attempts were made
        self.assertEqual(len(client.calls), 4)
        # 3 sleeps (not 4 — first attempt has no preceding sleep)
        self.assertEqual(mock_sleep.call_count, 3)

    @unittest.mock.patch("time.sleep")
    def test_kanban_list_does_not_retry_non_404_errors(self, mock_sleep):
        err = kanban.X0xError("connection refused — daemon not running")
        client = RecordingClient(error=err)
        with self.assertRaises(kanban.X0xError) as raised:
            kanban.do_list(client)
        # Original error propagates (not the restart hint)
        self.assertIn("connection refused", str(raised.exception))
        # Exactly 1 attempt — no retry
        self.assertEqual(len(client.calls), 1)
        mock_sleep.assert_not_called()

    @unittest.mock.patch("time.sleep")
    def test_kanban_tasks_retries_on_404_and_recovers(self, mock_sleep):
        client = Retry404Client(
            fail_count=1,
            success_response={"tasks": [{"id": "t1", "state": "open", "title": "work"}]},
        )
        result = kanban.do_tasks(client, {"list_id": "board-1"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["count"], 1)
        # 1 failure + 1 success = 2 GET calls
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(mock_sleep.call_count, 1)

    # ---- stores retry on 404 ------------------------------------------------

    @unittest.mock.patch("time.sleep")
    def test_stores_list_retries_on_404_and_recovers(self, mock_sleep):
        # Reuse Retry404Client but driven via stores module; X0xError is compatible
        # because both kanban and stores import from the same _x0x module.
        client = Retry404Client(fail_count=1, success_response={"stores": []})
        result = stores.do_list(client)
        self.assertTrue(result["ok"])
        self.assertEqual(result["count"], 0)
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(mock_sleep.call_count, 1)

    @unittest.mock.patch("time.sleep")
    def test_stores_list_raises_restart_hint_after_retries_exhaust(self, mock_sleep):
        client = Retry404Client(fail_count=4, success_response={"stores": []})
        with self.assertRaises(stores.X0xError) as raised:
            stores.do_list(client)
        msg = str(raised.exception)
        self.assertIn("daemon", msg.lower())
        self.assertIn("recovering", msg.lower())
        self.assertLessEqual(len(msg), 200)
        self.assertEqual(len(client.calls), 4)
        self.assertEqual(mock_sleep.call_count, 3)

    @unittest.mock.patch("time.sleep")
    def test_stores_non_404_error_is_sanitized_and_not_retried(self, mock_sleep):
        marker = "INTERNAL_TOKEN_DO_NOT_SPEAK"
        err = stores.X0xError(f"{marker}: daemon traceback")
        client = RecordingClient(error=err)
        with self.assertRaises(stores.X0xError) as raised:
            stores.do_list(client)
        msg = str(raised.exception)
        self.assertNotIn(marker, msg)
        self.assertLessEqual(len(msg), 200)
        self.assertEqual(len(client.calls), 1)
        mock_sleep.assert_not_called()

    # ---- swarm subscribe-before-publish ------------------------------------

    def test_swarm_publish_subscribes_to_topic_before_publishing(self):
        client = RecordingClient(response={"message_id": "msg-42", "ok": True})
        result = swarm.do_publish(client, {"payload": "run tests", "topic": "x0x-swarm/tasks"})
        self.assertTrue(result["ok"])
        self.assertTrue(result.get("subscribed_before_publish"))
        # First call must be subscribe, second must be publish
        self.assertEqual(len(client.calls), 2)
        sub_method, sub_path, sub_body = client.calls[0]
        pub_method, pub_path, pub_body = client.calls[1]
        self.assertEqual(sub_method, "POST")
        self.assertIn("/subscribe", sub_path)
        self.assertEqual(sub_body.get("topic"), "x0x-swarm/tasks")
        self.assertEqual(pub_method, "POST")
        self.assertIn("/publish", pub_path)
        # No warning in summary when subscription succeeded
        self.assertNotIn("could not confirm", result["summary"])

    def test_swarm_publish_warns_when_subscription_fails(self):
        client = SubscribeFailClient(success_response={"message_id": "msg-99"})
        result = swarm.do_publish(client, {"payload": "run tests", "topic": "x0x-swarm/tasks"})
        self.assertTrue(result["ok"])
        self.assertFalse(result.get("subscribed_before_publish"))
        # Publish still attempted despite subscribe failure
        pub_calls = [c for c in client.calls if "/publish" in c[1]]
        self.assertEqual(len(pub_calls), 1)
        # Warning present in summary
        self.assertIn("could not confirm", result["summary"])

    def test_swarm_publish_uses_default_topic_for_subscription(self):
        """When no topic param is given, subscription must target the default task topic."""
        client = RecordingClient(response={"message_id": "m1"})
        swarm.do_publish(client, {"payload": "hello"})
        sub_call = client.calls[0]
        self.assertEqual(sub_call[2].get("topic"), swarm.DEFAULT_TASK_TOPIC)


if __name__ == "__main__":
    unittest.main()
