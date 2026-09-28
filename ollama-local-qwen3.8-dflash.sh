#!/usr/bin/env bash
# Run Qwen3.8-27B with DFlash 2 speculative decoding and launch a coding agent
# of your choice against it.
#
#   ./ollama-local-qwen3.8-dflash.sh [--server-only] [--tui codex|claude|pi|hermes|opencode] [port]
#
# DFlash 2 is a block-diffusion drafter: it predicts a whole block of tokens in
# one pass, then the target model verifies them — decoding is lossless (greedy
# output matches the target exactly). It is NOT a standalone model; it must run
# inside a speculative-decoding server.
#
# The GGUFs are pulled with the `hf` CLI (huggingface-cli) into a local storage
# dir, then served by llama-server. NOTE: your ollama model `qwen3.8:27b-mlx`
# is MLX format (nvfp4), not GGUF, so it cannot be reused here — the target
# GGUF is pulled from HF instead.
#
# Default: starts the server (background) on :11889, then prompts for which
# TUI to launch (or use --tui). --server-only starts just the server (for curl
# / OpenAI SDK use). Ctrl-C in the agent exits it; the server keeps running.
set -euo pipefail

# --- arg parsing ------------------------------------------------------------

TUI=""
SERVER_ONLY=0
PORT="11889"
HOST="${HOST:-127.0.0.1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --server-only) SERVER_ONLY=1; shift ;;
    --tui)         TUI="${2:-}"; shift 2 ;;
    --tui=*)       TUI="${1#*=}"; shift ;;
    *)             PORT="$1"; shift ;;
  esac
done

# --- config ----------------------------------------------------------------

STORAGE_DIR="${STORAGE_DIR:-$HOME/.cache/qwen3.8-dflash}"
TARGET_REPO="ggml-org/Qwen3.8-27B-GGUF"
TARGET_FILE="Qwen3.8-27B-Q4_K_M.gguf"
DRAFT_REPO="incoai/Qwen3.8-27B-DFlash2-GGUF"
DRAFT_FILE="Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
TARGET_GGUF="${TARGET_GGUF:-$STORAGE_DIR/$TARGET_FILE}"
DRAFT_GGUF="${DRAFT_GGUF:-$STORAGE_DIR/$DRAFT_FILE}"

ENDPOINT="http://${HOST}:${PORT}/v1"
MODEL="qwen3.8-dflash"
API_KEY="sk-qwen3.8-local"
LOG="${TMPDIR:-/tmp}/qwen3.8-dflash-serve.log"
TEMPLATE="$STORAGE_DIR/qwen3.8-lenient.jinja"
# 256K native context is wasteful for interactive use (huge KV cache, memory
# pressure). 64K is plenty for coding and much faster. Override with CTX_SIZE.
CTX_SIZE="${CTX_SIZE:-65536}"
PARALLEL="${PARALLEL:-1}"

# --- lenient chat template ---------------------------------------------------
# Qwen3.8's stock template raises 'System message must be at the beginning'
# when a system message isn't first (Codex/Claude send it that way). Extract
# the template from the GGUF and patch it to render non-first system messages
# inline instead of raising.
_make_lenient_template() {
  GGUF="$TARGET_GGUF" OUT="$TEMPLATE" python3 - <<'PY'
import os, struct
path = os.environ["GGUF"]
f = open(path, "rb")
assert f.read(4) == b"GGUF"
version, n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))

def read_str(f):
    n = struct.unpack("<Q", f.read(8))[0]
    return f.read(n).decode("utf-8", "replace")

def read_val(f, t):
    if t == 8: return read_str(f)
    if t == 9:
        at = struct.unpack("<I", f.read(4))[0]
        n = struct.unpack("<Q", f.read(8))[0]
        return [read_val(f, at) for _ in range(n)]
    if t == 0: return struct.unpack("<B", f.read(1))[0]
    if t == 1: return struct.unpack("<b", f.read(1))[0]
    if t == 2: return struct.unpack("<H", f.read(2))[0]
    if t == 3: return struct.unpack("<h", f.read(2))[0]
    if t == 4: return struct.unpack("<I", f.read(4))[0]
    if t == 5: return struct.unpack("<i", f.read(4))[0]
    if t == 6: return struct.unpack("<f", f.read(4))[0]
    if t == 7: return struct.unpack("<?", f.read(1))[0]
    if t == 10: return struct.unpack("<Q", f.read(8))[0]
    if t == 11: return struct.unpack("<q", f.read(8))[0]
    if t == 12: return struct.unpack("<d", f.read(8))[0]
    raise ValueError(f"type {t}")

tpl = None
for _ in range(n_kv):
    key = read_str(f)
    t = struct.unpack("<I", f.read(4))[0]
    val = read_val(f, t)
    if key == "tokenizer.chat_template":
        tpl = val
        break
if not tpl:
    raise SystemExit("chat template not found in GGUF")
old = '''    {%- if message.role == "system" %}\n        {%- if not loop.first %}\n            {{- raise_exception('System message must be at the beginning.') }}\n        {%- endif %}'''
new = '''    {%- if message.role == "system" %}\n        {%- if not loop.first %}\n            {{- '<|im_start|>system\\n' + content + '<|im_end|>' + '\\n' }}\n        {%- endif %}'''
assert old in tpl, "strict system check not found in template"
open(os.environ["OUT"], "w").write(tpl.replace(old, new))
PY
}

# --- preflight --------------------------------------------------------------

command -v llama-server >/dev/null 2>&1 \
  || { echo "[qwen3.8-dflash] llama-server not found on PATH (brew install llama.cpp)"; exit 1; }
command -v hf >/dev/null 2>&1 \
  || { echo "[qwen3.8-dflash] hf (huggingface-cli) not found on PATH (brew install huggingface-cli)"; exit 1; }

if ! llama-server --help 2>&1 | grep -q 'draft-dflash'; then
  echo "[qwen3.8-dflash] installed llama-server lacks DFlash 2 support (needs --spec-type draft-dflash)"
  echo "  update llama.cpp: brew upgrade llama.cpp"
  exit 1
fi

# --- pull the GGUFs (idempotent; hf skips already-downloaded files) ---------

mkdir -p "$STORAGE_DIR"
echo "[qwen3.8-dflash] pulling target GGUF ($TARGET_REPO/$TARGET_FILE) ..."
hf download "$TARGET_REPO" "$TARGET_FILE" --local-dir "$STORAGE_DIR" >/dev/null
echo "[qwen3.8-dflash] pulling draft GGUF ($DRAFT_REPO/$DRAFT_FILE) ..."
hf download "$DRAFT_REPO" "$DRAFT_FILE" --local-dir "$STORAGE_DIR" >/dev/null

[ -f "$TARGET_GGUF" ] || { echo "[qwen3.8-dflash] target GGUF missing: $TARGET_GGUF"; exit 1; }
[ -f "$DRAFT_GGUF" ]  || { echo "[qwen3.8-dflash] draft GGUF missing: $DRAFT_GGUF"; exit 1; }

echo "[qwen3.8-dflash] target: $TARGET_GGUF"
echo "[qwen3.8-dflash] draft:  $DRAFT_GGUF"
echo "[qwen3.8-dflash] OpenAI/Codex endpoint: $ENDPOINT"

# --- ensure the server is up ------------------------------------------------

pids=$(lsof -ti tcp:"${PORT}" 2>/dev/null || true)
if [ -n "$pids" ]; then
  if curl -s -m 2 "$ENDPOINT/models" >/dev/null 2>&1; then
    echo "[qwen3.8-dflash] server already running on :${PORT} (PID $pids)"
  else
    echo "[qwen3.8-dflash] port :${PORT} is in use by PID(s): $pids (not our server)"
    read -r -p "[qwen3.8-dflash] kill and restart? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES)
        kill $pids 2>/dev/null
        # wait for the port to actually free up before restarting
        for _ in $(seq 1 20); do
          lsof -ti tcp:"${PORT}" >/dev/null 2>&1 || break
          sleep 1
        done
        ;;
      *) echo "[qwen3.8-dflash] leaving it — nothing to do."; exit 0 ;;
    esac
  fi
fi

if ! curl -s -m 2 "$ENDPOINT/models" >/dev/null 2>&1; then
  echo "[qwen3.8-dflash] starting server on :${PORT} ..."
  _make_lenient_template
  nohup llama-server \
    --host "$HOST" --port "$PORT" \
    --model "$TARGET_GGUF" \
    --model-draft "$DRAFT_GGUF" \
    --spec-type draft-dflash \
    --spec-draft-n-max 7 \
    --ctx-size "$CTX_SIZE" \
    --parallel "$PARALLEL" \
    --chat-template-file "$TEMPLATE" \
    --alias "$MODEL" \
    > "$LOG" 2>&1 &
  # wait for readiness (up to ~180s; first load is slow)
  for _ in $(seq 1 180); do
    curl -s -m 2 "$ENDPOINT/models" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -s -m 2 "$ENDPOINT/models" >/dev/null 2>&1 \
    && echo "[qwen3.8-dflash] server up (log: $LOG)" \
    || { echo "[qwen3.8-dflash] server failed to start — see $LOG"; exit 1; }
fi

[ "$SERVER_ONLY" = 1 ] && { echo "[qwen3.8-dflash] server-only mode. Ctrl-C to stop."; wait; exit 0; }

# --- launch functions ---------------------------------------------------------

# codex: provider defined inline via -c flags (no persistent config).
# NB: provider name must not contain dots (Codex treats them as path separators).
_launch_codex() {
  echo "[qwen3.8-dflash] launching Codex (provider=qwen3_8_dflash) ..."
  # Provide model metadata (context window etc.) so Codex doesn't fall back.
  CATALOGUE="$STORAGE_DIR/codex-catalogue.json"
  cat > "$CATALOGUE" <<JSON
{
  "models": [
    {
      "slug": "$MODEL",
      "display_name": "Qwen3.8 DFlash",
      "context_window": $CTX_SIZE,
      "input_modalities": ["text"],
      "supported_reasoning_levels": [],
      "default_reasoning_level": null,
      "supports_parallel_tool_calls": true,
      "supported_in_api": true,
      "visibility": "list",
      "shell_type": "default",
      "priority": 0,
      "base_instructions": "",
      "supports_reasoning_summaries": false,
      "default_reasoning_summary": "auto",
      "support_verbosity": false,
      "truncation_policy": {"mode": "tokens", "limit": $CTX_SIZE},
      "experimental_supported_tools": []
    }
  ]
}
JSON
  export OPENAI_API_KEY="$API_KEY"
  exec codex \
    -c 'model_provider="qwen3_8_dflash"' \
    -c 'model="qwen3.8-dflash"' \
    -c 'model_providers.qwen3_8_dflash.name="Qwen3.8 DFlash"' \
    -c "model_providers.qwen3_8_dflash.base_url=\"$ENDPOINT\"" \
    -c 'model_providers.qwen3_8_dflash.env_key="OPENAI_API_KEY"' \
    -c 'model_providers.qwen3_8_dflash.wire_api="responses"' \
    -c "model_catalog_json=\"$CATALOGUE\""
}

# claude: env vars only (llama-server exposes an Anthropic-compatible /v1/messages).
_launch_claude() {
  echo "[qwen3.8-dflash] launching Claude Code ..."
  export ANTHROPIC_BASE_URL="http://${HOST}:${PORT}"
  export ANTHROPIC_AUTH_TOKEN="$API_KEY"
  export ANTHROPIC_MODEL="$MODEL"
  # Model is not in Claude's catalogue; tell it the real context window.
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="262144"
  export CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT="1"
  exec claude
}

# pi: upsert an OpenAI-compatible provider into pi's models.json.
_launch_pi() {
  echo "[qwen3.8-dflash] launching pi (provider=qwen3.8_dflash) ..."
  PI_MODELS="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" \
  ENDPOINT="$ENDPOINT" API_KEY="$API_KEY" MODEL="$MODEL" python3 - <<'PY'
import json, os
path = os.environ["PI_MODELS"]
endpoint = os.environ["ENDPOINT"]
api_key = os.environ["API_KEY"]
model = os.environ["MODEL"]
try:
    with open(path) as f:
        d = json.load(f)
except FileNotFoundError:
    d = {}
d.setdefault("providers", {})
d["providers"]["qwen3.8_dflash"] = {
    "baseUrl": endpoint,
    "api": "openai-completions",
    "apiKey": api_key,
    "compat": {"supportsDeveloperRole": False, "supportsReasoningEffort": False},
    "models": [{"id": model}],
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(d, f, indent=1)
PY
  exec pi --provider qwen3.8_dflash --api-key "$API_KEY" --model "$MODEL"
}

# hermes: surgically insert a provider into config.yaml (preserves comments).
_launch_hermes() {
  echo "[qwen3.8-dflash] launching Hermes (provider=custom:qwen3.8-dflash) ..."
  HERMES_CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}" \
  ENDPOINT="$ENDPOINT" API_KEY="$API_KEY" MODEL="$MODEL" python3 - <<'PY'
import os
path = os.environ["HERMES_CONFIG"]
endpoint = os.environ["ENDPOINT"]
api_key = os.environ["API_KEY"]
model = os.environ["MODEL"]
block = (
    f"  {model}:\n"
    f"    api: {endpoint}\n"
    f"    default_model: {model}\n"
    f"    models:\n"
    f"      - {model}\n"
    f"    name: Qwen3.8 DFlash\n"
    f"    api_key: {api_key}\n"
)
with open(path) as f:
    lines = f.readlines()
# Replace an existing entry, else insert before fallback_providers.
for i, ln in enumerate(lines):
    if ln.strip() == f"{model}:" and i > 0 and lines[i-1].strip() == "providers:":
        lines[i:i+1] = [block]
        break
else:
    for i, ln in enumerate(lines):
        if ln.startswith("fallback_providers:"):
            lines[i:i] = [block]
            break
with open(path, "w") as f:
    f.writelines(lines)
PY
  exec hermes --tui --provider "custom:qwen3.8-dflash" --model "$MODEL"
}

# opencode: add an OpenAI-compatible provider to opencode.jsonc.
_launch_opencode() {
  echo "[qwen3.8-dflash] launching OpenCode (provider=qwen3.8-dflash) ..."
  OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.jsonc}" \
  ENDPOINT="$ENDPOINT" API_KEY="$API_KEY" MODEL="$MODEL" python3 - <<'PY'
import json, os, re
path = os.environ["OPENCODE_CONFIG"]
endpoint = os.environ["ENDPOINT"]
api_key = os.environ["API_KEY"]
model = os.environ["MODEL"]
# Strip // and /* */ comments (string-aware, so URLs with // survive).
text = open(path).read()
out, i, n, in_str, esc = [], 0, len(text), False, False
while i < n:
    c = text[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            in_str = False
        i += 1
        continue
    if c == '"':
        in_str = True; out.append(c); i += 1; continue
    if c == '/' and i + 1 < n and text[i+1] == '/':
        while i < n and text[i] != '\n': i += 1
        continue
    if c == '/' and i + 1 < n and text[i+1] == '*':
        i += 2
        while i + 1 < n and not (text[i] == '*' and text[i+1] == '/'): i += 1
        i += 2
        continue
    out.append(c); i += 1
d = json.loads(''.join(out))
d.setdefault("provider", {})
d["provider"][model] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Qwen3.8 DFlash",
    "options": {"baseURL": endpoint, "apiKey": api_key},
    "models": {model: {"name": "Qwen3.8 DFlash"}},
}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY
  exec opencode --model "$MODEL/$MODEL"
}

# --- choose TUI --------------------------------------------------------------

if [ -z "$TUI" ]; then
  echo "[qwen3.8-dflash] choose a TUI:"
  PS3="TUI> "
  select tui in codex claude pi hermes opencode; do
    [ -n "$tui" ] && { TUI="$tui"; break; }
  done
fi

# --- launch the chosen agent ------------------------------------------------

case "$TUI" in
  codex)    _launch_codex ;;
  claude)   _launch_claude ;;
  pi)       _launch_pi ;;
  hermes)   _launch_hermes ;;
  opencode) _launch_opencode ;;
  *) echo "[qwen3.8-dflash] unknown TUI: $TUI (codex|claude|pi|hermes|opencode)"; exit 1 ;;
esac
