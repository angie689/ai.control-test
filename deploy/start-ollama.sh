#!/usr/bin/env bash
set -euo pipefail
: "${AI_CONTROLLER_TOKEN:?Set a random AI_CONTROLLER_TOKEN of 24-256 characters}"
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3:1.7b}"
ollama serve &
OLLAMA_PID=$!
trap 'kill "${OLLAMA_PID}" 2>/dev/null || true' EXIT
for attempt in $(seq 1 90); do
    if ollama list >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${OLLAMA_PID}" 2>/dev/null; then
        echo "Ollama exited unexpectedly" >&2
        exit 1
    fi
    sleep 1
done
ollama list >/dev/null 2>&1 || { echo "Ollama failed to start" >&2; exit 1; }
ollama pull "${OLLAMA_MODEL}"
python3 -u /srv/server.py
