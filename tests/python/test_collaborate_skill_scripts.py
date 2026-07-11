import base64
import importlib.util
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
