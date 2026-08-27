#!/usr/bin/env bash
# Run the local DeepSeek-V4-Flash OptiQ-2bit model and launch Codex against it.
#
#   ./ollama-local-ds4flash.sh [--server-only] [port]
#
# Default: starts the server (background) on :11888, then opens Codex pointed at
# it. --server-only starts just the server (for curl / OpenAI SDK use).
# Ctrl-C in Codex exits Codex; the server keeps running in the background.
set -euo pipefail

DS4MLX="${DS4MLX:-$HOME/Documents/ds4_mlx}"
PORT="${1:-11888}"
HOST="${HOST:-127.0.0.1}"
SERVER_ONLY=0
[ "${1:-}" = "--server-only" ] && { SERVER_ONLY=1; PORT="${2:-11888}"; }

MODEL_REPO="mlx-community/DeepSeek-V4-Flash-0731-OptiQ-2bit"
CACHE="$HOME/.cache/huggingface/hub"
LOG="${DS4MLX}/serve.log"

# Resolve the cached snapshot so nothing touches the network at startup.
MODEL="$MODEL_REPO"
snap=$(ls -d "$CACHE"/models--mlx-community--DeepSeek-V4-Flash-0731-OptiQ-2bit/snapshots/*/ 2>/dev/null | head -1 || true)
[ -n "$snap" ] && MODEL="${snap%/}"

echo "[ds4flash] model: $MODEL"
echo "[ds4flash] OpenAI/Codex endpoint: http://${HOST}:${PORT}/v1"

# --- ensure the server is up ---
pids=$(lsof -ti tcp:"${PORT}" 2>/dev/null || true)
if [ -n "$pids" ]; then
  if curl -s -m 2 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "[ds4flash] server already running on :${PORT} (PID $pids)"
  else
    echo "[ds4flash] port :${PORT} is in use by PID(s): $pids (not our server)"
    read -r -p "[ds4flash] kill and restart? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) kill $pids 2>/dev/null; sleep 2 ;;
      *) echo "[ds4flash] leaving it — nothing to do."; exit 0 ;;
    esac
  fi
fi

if ! curl -s -m 2 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
  echo "[ds4flash] starting server on :${PORT} ..."
  cd "$DS4MLX"
  nohup .venv/bin/python serve_optiq.py serve \
    --model "$MODEL" \
    --stream-experts \
    --stream-experts-cache 8 \
    --host "$HOST" --port "$PORT" \
    --max-concurrent 2 > "$LOG" 2>&1 &
  # wait for readiness (up to ~90s; first load is slow)
  for _ in $(seq 1 90); do
    curl -s -m 2 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -s -m 2 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1 \
    && echo "[ds4flash] server up (log: $LOG)" \
    || { echo "[ds4flash] server failed to start — see $LOG"; exit 1; }
fi

[ "$SERVER_ONLY" = 1 ] && { echo "[ds4flash] server-only mode. Ctrl-C to stop."; wait; exit 0; }

# --- launch Codex against the local model ---
echo "[ds4flash] launching Codex (provider=ds4flash, model=ds4flash) ..."
export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-optiq-local}"
exec codex -c 'model_provider="ds4flash"' -c 'model="ds4flash"'
