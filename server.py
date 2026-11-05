"""Stateless SLM inference gateway. The restricted sandbox lives in the iPhone IPA.

Host behind HTTPS. This server has no agent state and cannot run AI tool calls.
Hosted mode: set GROQ_API_KEY (and optionally GROQ_MODEL, default openai/gpt-oss-20b).
Also supported: OPENROUTER_API_KEY, or a local Ollama on loopback for self-hosting.
"""
import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from app import STRING, tool

TOOLS = [
    tool("calculate", "Evaluate basic arithmetic in the on-device sandbox.",
         {"expression": STRING}, ["expression"]),
    tool("notes", "Manage notes on this iPhone: list, read, write.",
         {"action": {"type": "string", "enum": ["list", "read", "write"]},
          "name": STRING, "text": STRING}, ["action"]),
    tool("tasks", "Manage a local task list: list, add, done, delete.",
         {"action": {"type": "string", "enum": ["list", "add", "done", "delete"]},
          "title": STRING, "id": {"type": "integer"}}, ["action"]),
    tool("workspace", "Read, write, list or delete VIRTUAL text files on this iPhone.",
         {"action": {"type": "string", "enum": ["list", "read", "write", "delete"]},
          "name": STRING, "text": STRING}, ["action"]),
    tool("read_web", "Read a permitted HTTPS text page via the iPhone's restricted web reader.",
         {"url": STRING}, ["url"]),
    tool("clone_agent", "Create an independent agent inside the iPhone IPA.",
         {"name": STRING}, ["name"]),
    tool("app_action", "Use an installed and enabled declarative sandbox app on the iPhone. Consult the system-provided app catalogue and action IDs. The app will enforce permissions locally.",
         {"app_id": STRING, "action": STRING, "key": STRING, "text": STRING},
         ["app_id", "action"])
]
ALLOWED_HOSTS = ["docs.python.org", "en.wikipedia.org"]


class ServerError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_messages(messages):
    if not isinstance(messages, list) or not 1 <= len(messages) <= 40:
        raise ServerError(400, "Expected 1-40 conversation messages.")
    total = 0
    for message in messages:
        if not isinstance(message, dict):
            raise ServerError(400, "Invalid message object.")
        role = message.get("role")
        if role not in ("system", "user", "assistant", "tool"):
            raise ServerError(400, "Invalid message role.")
        content = message.get("content")
        if content is not None and not isinstance(content, str):
            raise ServerError(400, "Invalid message content.")
        total += len(content or "")
        if role == "tool":
            if not isinstance(message.get("tool_call_id"), str):
                raise ServerError(400, "Missing tool-call id.")
        if message.get("tool_calls") is not None:
            calls = message["tool_calls"]
            if role != "assistant" or not isinstance(calls, list) or len(calls) > 8:
                raise ServerError(400, "Invalid tool calls.")
            for call in calls:
                if not isinstance(call, dict) or not isinstance(call.get("id"), str):
                    raise ServerError(400, "Invalid tool-call identifier.")
                function = call.get("function")
                if not isinstance(function, dict):
                    raise ServerError(400, "Invalid tool-call function.")
                if not isinstance(function.get("name"), str) or not isinstance(function.get("arguments"), str):
                    raise ServerError(400, "Invalid function arguments.")
                total += len(function["arguments"])
    if total > 35000:
        raise ServerError(413, "Conversation is too long. Reset this agent's chat.")
    return messages


class InferenceEngine:
    """Provider priority: Groq, then OpenRouter, then local Ollama (never on Render)."""

    @property
    def provider(self):
        if os.getenv("GROQ_API_KEY"):
            return "groq"
        if os.getenv("OPENROUTER_API_KEY"):
            return "openrouter"
        return "ollama"

    @property
    def model(self):
        provider = self.provider
        if provider == "groq":
            return os.getenv("GROQ_MODEL") or "openai/gpt-oss-20b"
        if provider == "openrouter":
            return os.getenv("OPENROUTER_MODEL", "qwen/qwen3-1.7b:free")
        return os.getenv("OLLAMA_MODEL", "qwen3:1.7b")

    def complete(self, messages):
        provider = self.provider
        if provider == "groq":
            endpoint = "https://api.groq.com/openai/v1/chat/completions"
            headers = {
                "Authorization": "Bearer " + os.environ["GROQ_API_KEY"],
                "Content-Type": "application/json",
                # Groq sits behind Cloudflare, which can block urllib's default agent.
                "User-Agent": "AIControllerGateway/2",
            }
        elif provider == "openrouter":
            endpoint = "https://openrouter.ai/api/v1/chat/completions"
            headers = {
                "Authorization": "Bearer " + os.environ["OPENROUTER_API_KEY"],
                "Content-Type": "application/json",
                "X-Title": "AI Controller Thing",
            }
        else:
            if os.getenv("RENDER"):
                raise ValueError("Configure GROQ_API_KEY on the hosted inference gateway.")
            endpoint = "http://127.0.0.1:11434/v1/chat/completions"
            headers = {"Content-Type": "application/json"}
        body = json.dumps({"model": self.model, "messages": messages,
                           "tools": TOOLS, "max_tokens": 800,
                           "stream": False}).encode("utf-8")
        request = Request(endpoint, data=body, headers=headers, method="POST")
        try:
            opener = build_opener(ProxyHandler({}), NoRedirect())
            with opener.open(request, timeout=90) as response:
                output = json.load(response)
            result = output.get("choices", [{}])[0].get("message", {})
            if not isinstance(result, dict) or result.get("role") != "assistant":
                raise ValueError("Invalid model response.")
            # Drops provider extras such as gpt-oss "reasoning"; keeps tool_calls.
            return {key: value for key, value in result.items()
                    if key in ("role", "content", "tool_calls")}
        except HTTPError as error:
            if error.code == 429:
                raise ValueError("Hosted model rate limit reached.") from None
            if error.code in (401, 403):
                raise ValueError("SLM provider rejected the API key or request.") from None
            if error.code == 404:
                raise ValueError("Selected model is unavailable: " + self.model) from None
            if error.code == 400:
                raise ValueError("Model rejected the request (possibly a malformed tool call).") from None
            raise ValueError("Model provider returned HTTP " + str(error.code)) from None
        except (URLError, TimeoutError):
            raise ValueError("SLM host is offline or did not respond.") from None
        except json.JSONDecodeError:
            raise ValueError("Model provider returned invalid JSON.") from None


class InferenceHandler(BaseHTTPRequestHandler):
    server_version = "AIControllerInference/2"

    def log_message(self, format, *args):
        # Never print chat bodies, model keys or bearer tokens.
        print("%s %s" % (self.address_string(), format % args), flush=True)

    def answer(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def authenticate(self):
        token = self.headers.get("Authorization", "")
        expected = "Bearer " + self.server.secret
        if not hmac.compare_digest(token.encode("utf-8")[:1024], expected.encode("utf-8")):
            raise ServerError(401, "Incorrect access token.")
        now = time.monotonic()
        with self.server.limit_lock:
            recent = [t for t in self.server.recent if now - t < 60]
            if len(recent) >= 30:
                raise ServerError(429, "Too many requests; please retry later.")
            recent.append(now)
            self.server.recent = recent

    def parse_body(self):
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            raise ServerError(415, "Expected JSON.")
        try:
            size = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise ServerError(400, "Invalid content length.") from None
        if size < 0 or size > 45000:
            raise ServerError(413, "Request body is too large.")
        try:
            data = json.loads(self.rfile.read(size))
        except (ValueError, UnicodeDecodeError):
            raise ServerError(400, "Malformed JSON.") from None
        if not isinstance(data, dict):
            raise ServerError(400, "Expected JSON object.")
        return data

    def handle_request(self, method):
        if method == "GET" and self.path == "/health":
            return {"status": "ok"}
        self.authenticate()
        if method == "GET" and self.path == "/api/state":
            return {
                "model": self.server.engine.model,
                "allowed_hosts": ALLOWED_HOSTS,
                "tools": [t["function"]["name"] for t in TOOLS],
                "sandbox_location": "iPhone IPA"
            }
        if method == "POST" and self.path == "/api/complete":
            body = self.parse_body()
            messages = validate_messages(body.get("messages"))
            # The server only returns model output. It NEVER executes function calls.
            with self.server.inference_lock:
                try:
                    message = self.server.engine.complete(messages)
                except ValueError as exc:
                    raise ServerError(502, str(exc)[:200]) from None
            return {"message": message}
        raise ServerError(404, "Unknown endpoint.")

    def dispatch(self, method):
        try:
            self.answer(200, self.handle_request(method))
        except ServerError as exc:
            self.answer(exc.code, {"error": str(exc)})
        except Exception as exc:
            print("Inference gateway error:", type(exc).__name__, flush=True)
            self.answer(500, {"error": "Internal inference gateway error."})

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")


class InferenceServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, token, engine=None):
        self.secret = token
        self.engine = engine or InferenceEngine()
        self.inference_lock = threading.Lock()
        self.limit_lock = threading.Lock()
        self.recent = []
        super().__init__(address, InferenceHandler)


def main():
    token = os.getenv("AI_CONTROLLER_TOKEN", "")
    if not 24 <= len(token) <= 256:
        raise SystemExit("Set AI_CONTROLLER_TOKEN to a secret of 24-256 characters.")
    hosted = bool(os.getenv("RENDER"))
    host = os.getenv("AI_CONTROLLER_HOST", "0.0.0.0" if hosted else "127.0.0.1")
    if host not in ("127.0.0.1", "::1") and not (hosted and host == "0.0.0.0"):
        raise SystemExit("Only bind to loopback or Render's managed ingress.")
    port = int(os.getenv("PORT", "8787"))
    server = InferenceServer((host, port), token)
    print("SLM inference gateway ready (no sandbox here).", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
