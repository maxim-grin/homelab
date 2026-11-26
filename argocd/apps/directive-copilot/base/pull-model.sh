#!/usr/bin/env bash
# Init container: put $MODEL on the volume before the server starts. Exits 0
# without touching the registry when the model is already there, so a restart
# with no internet still succeeds. Any failure exits non-zero.
set -euo pipefail

: "${MODEL:?MODEL must name the model to pull}"

# The server runs only for this pull. It is stopped on exit, so the server
# container starts on a clean pod with no second process from this one.
ollama serve &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT

# `ollama list` talks to the server, so success means it is answering.
up=0
for _ in $(seq 60); do
  if ollama list >/dev/null 2>&1; then
    up=1
    break
  fi
  # A server that died early is not worth waiting out.
  kill -0 "$server" 2>/dev/null || break
  sleep 1
done
[ "$up" -eq 1 ] || { echo "pull-model: ollama serve not answering within 60s" >&2; exit 1; }

# `ollama show` reads the local manifest only, so it works with no network.
if ollama show "$MODEL" >/dev/null 2>&1; then
  echo "pull-model: $MODEL already present"
  exit 0
fi
ollama pull "$MODEL"
echo "pull-model: pulled $MODEL"
