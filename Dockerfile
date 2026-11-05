# Server-only image; the iPhone's agents, tools and imported apps remain in the IPA.
FROM ollama/ollama:latest
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 ca-certificates bash \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /srv
COPY app.py server.py /srv/
COPY deploy/start-ollama.sh /srv/start-ollama.sh
RUN chmod +x /srv/start-ollama.sh
ENV OLLAMA_HOST=127.0.0.1:11434 \
    OLLAMA_MODEL=qwen3:1.7b \
    OLLAMA_NUM_PARALLEL=1 \
    OLLAMA_MAX_LOADED_MODELS=1 \
    OLLAMA_CONTEXT_LENGTH=2048
EXPOSE 10000
ENTRYPOINT ["/bin/bash", "/srv/start-ollama.sh"]
