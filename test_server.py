import http.client
import json
import threading
import unittest

from server import InferenceServer, ServerError, validate_messages


class FakeSLM:
    model = "tiny-test-model"
    def complete(self, messages):
        return {"role": "assistant", "content": "Hello from the model"}


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.secret = "test-token-with-at-least-24-characters"
        cls.server = InferenceServer(("127.0.0.1", 0), cls.secret, FakeSLM())
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=3)

    def send(self, method, path, payload=None, token=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=4)
        headers = {"Authorization": "Bearer " + (self.secret if token is None else token)}
        body = None
        if payload is not None:
            body = json.dumps(payload)
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_auth_and_state(self):
        status, body = self.send("GET", "/api/state", token="invalid")
        self.assertEqual(status, 401)
        status, body = self.send("GET", "/api/state")
        self.assertEqual(status, 200)
        self.assertEqual(body["model"], "tiny-test-model")
        self.assertEqual(body["sandbox_location"], "iPhone IPA")
        self.assertIn("app_action", body["tools"])
        self.assertNotIn("agents", body)
        self.assertNotIn("api_key", str(body))

    def test_chat_is_inference_only(self):
        messages = [{"role": "user", "content": "hello"}]
        status, result = self.send("POST", "/api/complete", {"messages": messages})
        self.assertEqual(status, 200)
        self.assertEqual(result["message"]["content"], "Hello from the model")
        status, body = self.send("POST", "/api/chat", {"message": "hello"})
        self.assertEqual(status, 404)
        status, body = self.send("POST", "/api/agents", {"name": "worker"})
        self.assertEqual(status, 404)

    def test_validations(self):
        for messages in ([], [12], [{"role": "bad", "content": "hello"}],
                         [{"role": "user", "content": "x" * 35001}]):
            with self.assertRaises(ServerError):
                validate_messages(messages)
        status, body = self.send("POST", "/api/complete", {"messages": []})
        self.assertEqual(status, 400)
        status, body = self.send("POST", "/api/complete", {"messages": "hello"})
        self.assertEqual(status, 400)
        status, body = self.send("GET", "/nonexistent")
        self.assertEqual(status, 404)

    def test_model_can_suggest_but_cannot_execute_tools(self):
        class Suggestor:
            model = "tool-test"
            def complete(self, messages):
                return {"role": "assistant", "content": None, "tool_calls": [
                    {"id": "1", "type": "function", "function": {
                        "name": "app_action",
                        "arguments": '{"app_id":"flashcards","action":"save","key":"one","text":"hi"}'
                    }}
                ]}
        initial = self.server.engine
        self.server.engine = Suggestor()
        try:
            status, data = self.send("POST", "/api/complete",
                                      {"messages": [{"role": "user", "content": "save card"}]})
            self.assertEqual(status, 200)
            self.assertEqual(data["message"]["tool_calls"][0]["function"]["name"], "app_action")
            # The gateway has no installed apps, task files, or shell executor.
            self.assertFalse(hasattr(self.server, "sandbox"))
        finally:
            self.server.engine = initial


if __name__ == "__main__":
    unittest.main()
