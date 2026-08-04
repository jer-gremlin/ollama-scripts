#!/usr/bin/env bash
set -euo pipefail
# Shared helpers for the ollama-* launchers.  Not executable; sourced.

OLLAMA_HOST_URL="https://ollama.com"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ollama-scripts"

_die() { echo "ollama: $*" >&2; exit 1; }

_require_key() {
  [ -n "${OLLAMA_API_KEY:-}" ] || _die "OLLAMA_API_KEY is not set"
}

# Print available cloud model names, one per line. Live fetch, cache fallback.
_models() {
  mkdir -p "$STATE_DIR"
  local cache="$STATE_DIR/models.cache" out
  # Use a fresh cache (<=1h old) instead of a slow live fetch on every launch.
  if [ -s "$cache" ] && [ $(( $(date +%s) - $(stat -f %m "$cache") )) -le 3600 ]; then
    cat "$cache"
    return
  fi
  out=$(curl -fsS --max-time 10 "$OLLAMA_HOST_URL/api/tags" \
          -H "Authorization: Bearer $OLLAMA_API_KEY" 2>/dev/null \
        | python3 -c 'import sys,json;print("\n".join(sorted(m["name"] for m in json.load(sys.stdin).get("models",[]))))' 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" > "$cache"
    printf '%s\n' "$out"
  elif [ -s "$cache" ]; then
    cat "$cache"
  else
    _die "could not fetch model list and no cache present"
  fi
}

# _model_raw <model>  -> echoes raw /api/show JSON for <model>, or empty on failure.
_model_raw() {
  local model="$1"
  curl -fsS --max-time 10 "$OLLAMA_HOST_URL/api/show" \
    -H "Authorization: Bearer $OLLAMA_API_KEY" \
    -d "{\"model\":\"$model\"}" 2>/dev/null || echo ""
}

# _model_metadata <model>  -> echoes parsed JSON with context_window, capabilities, details.
# Used by _codex_catalogue and _pi_model_dict. Format:
#   {"context_window": N, "capabilities": [...], "details": {...}}
_model_metadata() {
  local model="$1" raw
  raw=$(_model_raw "$model")
  MODEL_METADATA_RAW="$raw" python3 - <<'PY'
import json, os, sys
raw = os.environ.get("MODEL_METADATA_RAW") or ""
ctx, caps, details = 128000, [], {}
try:
    d = json.loads(raw)
    caps = d.get("capabilities") or []
    details = d.get("details") or {}
    mi = d.get("model_info") or {}
    arch = mi.get("general.architecture")
    key = f"{arch}.context_length" if arch else None
    if isinstance(mi.get(key), int):
        ctx = mi[key]
    else:
        ctx = next((v for k, v in mi.items()
                    if k.endswith(".context_length") and isinstance(v, int)), ctx)
except Exception:
    pass
print(json.dumps({"context_window": ctx, "capabilities": caps, "details": details}))
PY
}

# _pi_model_dict <model>  -> echoes JSON dict for pi models.json entry with metadata.
# Format: {"id": "model", "contextWindow": N, "reasoning": bool, "input": [...], ...}
_pi_model_dict() {
  local model="$1" meta
  meta=$(_model_metadata "$model")
  PI_META="$meta" PI_MODEL="$model" python3 - <<'PY'
import json, os
meta = json.loads(os.environ["PI_META"])
model = os.environ["PI_MODEL"]
caps = meta["capabilities"]
entry = {
    "id": model,
    "contextWindow": meta["context_window"],
    "reasoning": "thinking" in caps,
    "input": ["text", "image"] if "vision" in caps else ["text"],
    "maxTokens": 16384,
}
if "thinking" in caps:
    entry["compat"] = {"supportsReasoningEffort": True}
print(json.dumps(entry))
PY
}

# _codex_catalogue_all <out>  -> writes a Codex model catalogue listing every
# ollama cloud model so the /model picker shows them all (not just the one
# launched with). Echoes its path.
_codex_catalogue_all() {
  local out="$1"
  local models; models=$(_models)
  mkdir -p "$STATE_DIR"
  # Reuse the previous catalogue when the model list is unchanged, so the
  # launch isn't slowed by one /api/show call per model every time.
  if [ -f "$out" ]; then
    if CATALOGUE_MODELS="$models" OUT="$out" python3 -c 'import json,os,sys
d=json.load(open(os.environ["OUT"]))
cur=sorted(m["slug"] for m in d["models"])
want=sorted(x for x in os.environ["CATALOGUE_MODELS"].splitlines() if x.strip())
sys.exit(0 if cur==want else 1)'; then
      echo "$out"; return
    fi
  fi
  CATALOGUE_MODELS="$models" CATALOGUE_OUT="$out" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

def meta(model):
    req = urllib.request.Request(
        f"https://ollama.com/api/show",
        data=json.dumps({"model": model}).encode(),
        headers={"Authorization": f"Bearer {os.environ['OLLAMA_API_KEY']}"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            d = json.load(r)
    except urllib.error.URLError:
        return {}
    caps = d.get("capabilities") or []
    mi = d.get("model_info") or {}
    arch = mi.get("general.architecture")
    ctx = 128000
    key = f"{arch}.context_length" if arch else None
    if isinstance(mi.get(key), int):
        ctx = mi[key]
    else:
        ctx = next((v for k, v in mi.items()
                    if k.endswith(".context_length") and isinstance(v, int)), ctx)
    return {"ctx": ctx, "caps": caps}

entries = []
for model in os.environ["CATALOGUE_MODELS"].splitlines():
    m = model.strip()
    if not m:
        continue
    d = meta(m)
    caps = d.get("caps", [])
    thinks = "thinking" in caps
    levels = ["low", "medium", "high"] if thinks else []
    entries.append({
        "slug": m, "display_name": m,
        "context_window": d.get("ctx", 128000),
        "input_modalities": ["text", "image"] if "vision" in caps else ["text"],
        "supported_reasoning_levels": [{"effort": l, "description": l.title()} for l in levels],
        "default_reasoning_level": "low" if thinks else None,
        "supports_parallel_tool_calls": "tools" in caps,
        "supported_in_api": True, "visibility": "list",
        "shell_type": "default", "priority": 0, "base_instructions": "",
        "supports_reasoning_summaries": thinks, "default_reasoning_summary": "auto",
        "support_verbosity": False,
        "truncation_policy": {"mode": "tokens", "limit": d.get("ctx", 128000)},
        "experimental_supported_tools": [],
    })
with open(os.environ["CATALOGUE_OUT"], "w") as f:
    json.dump({"models": entries}, f, indent=2)
PY
  echo "$out"
}

# _resolve_model <harness> "$@"  -> sets $MODEL and $REST (remaining args).
# A "--model NAME" / "--model=NAME" flag skips the chooser (like `ollama launch`).
_resolve_model() {
  local harness="$1"; shift
  local m=""; REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)   m="${2:-}"; [ -n "$m" ] || _die "--model needs a value"; shift 2;;
      --model=*) m="${1#*=}"; shift;;
      *)         REST+=("$1"); shift;;
    esac
  done
  if [ -n "$m" ]; then
    mkdir -p "$STATE_DIR"; printf '%s\n' "$m" > "$STATE_DIR/last-$harness"; MODEL="$m"
  else
    # shellcheck disable=SC2034  # used by sourcing launchers
    MODEL=$(_pick_model "$harness")
  fi
}

# _pick_model <harness>  -> echoes chosen model, remembers it.
# Honours $OLLAMA_MODEL to skip the chooser entirely.
_pick_model() {
  local harness="$1" last_file="$STATE_DIR/last-$1" last="" chosen=""
  mkdir -p "$STATE_DIR"
  if [ -n "${OLLAMA_MODEL:-}" ]; then echo "$OLLAMA_MODEL"; return; fi
  [ -f "$last_file" ] && last=$(cat "$last_file")
  local models; models=$(_models)
  if command -v gum >/dev/null 2>&1; then
    chosen=$(printf '%s\n' "$models" | gum filter \
      --height=20 --value="$last" \
      --placeholder="type to filter…" \
      --header="ollama-$harness model  (last: ${last:-none})") || exit 130
  else
    PS3="ollama-$harness model> "
    select chosen in $models; do [ -n "$chosen" ] && break; done
  fi
  [ -n "$chosen" ] || _die "no model selected"
  echo "$chosen" > "$last_file"
  echo "$chosen"
}
