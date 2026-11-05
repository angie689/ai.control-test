import json
import unittest
from urllib.error import HTTPError, URLError
from unittest.mock import patch
from app import Controller, calculate, read_web

class Tests(unittest.TestCase):
    def test_local_inference(self):
        with patch("app.build_opener") as factory, patch.dict("os.environ", {}, clear=True):
            response = factory.return_value.open.return_value.__enter__.return_value
            response.read.return_value = json.dumps({"choices": [{"message": {
                "role": "assistant", "content": "Hello"}}]})
            self.assertEqual(Controller().chat("main", "Hi"), "Hello")
            request = factory.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, "http://127.0.0.1:11434/v1/chat/completions")
            self.assertFalse(request.has_header("Authorization"))
            self.assertEqual(json.loads(request.data)["model"], "qwen3:1.7b")
            self.assertIn("tools", json.loads(request.data))

    def test_ollama_errors(self):
        for error, message in [
            (URLError("offline"), "ollama serve"),
            (HTTPError("local", 404, "missing", {}, None), "ollama pull"),
            (HTTPError("local", 400, "unsupported", {}, None), "supports tools")]:
            with patch("app.build_opener") as factory:
                factory.return_value.open.side_effect = error
                with self.assertRaisesRegex(ValueError, message):
                    Controller().chat("main", "Hi")

    def test_cloud_tag_rejected(self):
        with patch.dict("os.environ", {"OLLAMA_MODEL": "example:cloud"}):
            with self.assertRaisesRegex(ValueError, "local Ollama"):
                Controller().chat("main", "Hi")

    def test_calculator(self):
        self.assertEqual(calculate("(2 + 3) * 4"), 20)
        for expression in ["__import__('os')", "2**100", "True", "1e100"]:
            with self.assertRaises(ValueError):
                calculate(expression)

    def test_agents_and_notes(self):
        c = Controller()
        c.clone("worker")
        c.execute("main", "notes", {"action": "write", "name": "test", "text": "hello"})
        self.assertEqual(c.execute("worker", "notes", {"action": "list"}), [])
        with self.assertRaises(ValueError):
            c.execute("main", "shell", {})
        for i in range(6):
            c.clone(str(i))
        with self.assertRaises(ValueError):
            c.clone("overflow")

    def test_network_policy(self):
        for url in ["http://example.com", "https://other.com", "https://example.com:444",
                    "https://user@example.com"]:
            with self.assertRaises(ValueError):
                read_web(url, {"example.com"})
        with patch("app.socket.getaddrinfo", return_value=[(2, 1, 6, "", ("127.0.0.1", 443))]):
            with self.assertRaises(ValueError):
                read_web("https://example.com", {"example.com"})

    def test_tool_loop(self):
        replies = iter([
            {"role": "assistant", "content": None, "tool_calls": [
                {"id": "one", "type": "function", "function": {
                    "name": "calculate", "arguments": '{"expression":"2+2"}'}}]},
            {"role": "assistant", "content": "4"}])
        c = Controller(lambda messages: next(replies))
        self.assertEqual(c.chat("main", "calculate"), "4")
        self.assertEqual(c.agents["main"]["messages"][-2]["content"], "4")

if __name__ == "__main__":
    unittest.main()
