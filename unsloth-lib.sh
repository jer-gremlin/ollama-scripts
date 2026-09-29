#!/usr/bin/env bash
set -euo pipefail
# Shared helpers for the unsloth-* launchers (Unsloth Studio servers).
# Not executable; sourced AFTER lib.sh (reuses STATE_DIR, _resolve_model).
#
# Server discovery: $UNSLOTH_BASE_URL wins outright, else probe
# ${UNSLOTH_HOST:-127.0.0.1} on :18888 (remote ssh tunnel) and :8888 (local).
# Every server that answers is offered in an fzf-style chooser (prefilled with
# the last pick); with a single server up you're not bothered.
#
# Auth is detected per server, keys tried in order:
#   $UNSLOTH_API_KEY, $UNSLOTH_BIG_GPU, then any other $UNSLOTH_*KEY* env.
#   bearer -> a key authenticates; clients send "Bearer <$US_KEY_VAR>"
#   open   -> no key needed; clients send no Authorization header at all
#   broken -> up but nothing works (key mismatch); listed with a warning
# _us_base_url sets US_URL, US_KEY (value; "" when open) and US_KEY_VAR
# (env var name; "" when open) for the launchers.

# Redefine the die prefix for unsloth launchers.
_die() { echo "unsloth: $*" >&2; exit 1; }

# _us_probe <url> <key|->  -> echoes HTTP status of GET /v1/models (000 = dead).
# "-" sends no Authorization header.
_us_probe() {
  local hdr=() code
  [ "$2" != "-" ] && hdr=(-H "Authorization: Bearer $2")
  code=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
           "$1/v1/models" "${hdr[@]+"${hdr[@]}"}" 2>/dev/null) || true
  echo "${code:-000}"
}

# _us_mode <url>  -> echoes "mode<TAB>key<TAB>varname" (key/var empty unless
# bearer): open|bearer|broken:<code>|down.
_us_mode() {
  local url="$1" k v
  for k in UNSLOTH_API_KEY UNSLOTH_BIG_GPU; do
    v=$(printenv "$k" 2>/dev/null || true)
    [ -n "$v" ] || continue
    if [ "$(_us_probe "$url" "$v")" = 200 ]; then
      printf 'bearer\t%s\t%s\n' "$v" "$k"; return
    fi
  done
  # Any other UNSLOTH_*KEY* env vars, sorted for determinism.
  while IFS='=' read -r k v; do
    case "$k" in
      UNSLOTH_API_KEY|UNSLOTH_BIG_GPU|UNSLOTH_*MODEL*|UNSLOTH_BASE_URL|UNSLOTH_HOST) continue ;;
      UNSLOTH_*KEY*)
        [ -n "$v" ] || continue
        if [ "$(_us_probe "$url" "$v")" = 200 ]; then
          printf 'bearer\t%s\t%s\n' "$v" "$k"; return
        fi ;;
    esac
  done < <(env | sort)
  local c
  c=$(_us_probe "$url" -)
  case "$c" in
    200) printf 'open\t\t\n'; return ;;
    000) printf 'down\t\t\n'; return ;;
    *)   printf 'broken:%s\t\t\n' "$c" ;;
  esac
}

# _us_count_models <url> <key|->  -> model count or "?".
_us_count_models() {
  local hdr=() out
  [ "$2" != "-" ] && hdr=(-H "Authorization: Bearer $2")
  out=$(curl -fsS --max-time 5 "$1/v1/models" "${hdr[@]+"${hdr[@]}"}" 2>/dev/null) || { echo "?"; return; }
  printf '%s' "$out" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null || echo "?"
}

# _us_base_url  -> sets $US_URL, $US_KEY ("" when open) and $US_KEY_VAR.
# shellcheck disable=SC2034  # US_KEY/US_KEY_VAR are consumed by the launchers
_us_base_url() {
  local host="${UNSLOTH_HOST:-127.0.0.1}" p url m n
  local lines="" last_file="$STATE_DIR/unsloth-server" last=""
  if [ -n "${UNSLOTH_BASE_URL:-}" ]; then
    US_URL="${UNSLOTH_BASE_URL%/}"
    IFS=$'\t' read -r m US_KEY US_KEY_VAR <<<"$(_us_mode "$US_URL")"
    case "$m" in
      open)     US_KEY=""; US_KEY_VAR="" ;;
      bearer)   : ;;
      broken:*) _die "$US_URL answers HTTP ${m#broken:} — no UNSLOTH_*KEY* env matches this server" ;;
      *)        _die "$US_URL unreachable" ;;
    esac
    echo "unsloth: using $US_URL (UNSLOTH_BASE_URL, ${m%%:*})" >&2
    return
  fi
  mkdir -p "$STATE_DIR"
  [ -f "$last_file" ] && last=$(cat "$last_file")
  for p in 18888 8888; do
    url="http://$host:$p"
    IFS=$'\t' read -r m mkey mvar <<<"$(_us_mode "$url")"
    case "$m" in
      down)     continue ;;
      bearer)   n=$(_us_count_models "$url" "$mkey")
                lines+="$url"$'\t'"key $mvar · $n models"$'\n' ;;
      open)     n=$(_us_count_models "$url" "-")
                lines+="$url"$'\t'"open · $n models"$'\n' ;;
      broken:*) lines+="$url"$'\t'"HTTP ${m#broken:} — no key matches"$'\n' ;;
    esac
  done
  [ -n "$lines" ] || _die "no unsloth server on :18888 or :8888 (set UNSLOTH_BASE_URL or UNSLOTH_HOST)"
  local chosen=""
  if [ "$(printf '%s' "$lines" | grep -c .)" -gt 1 ]; then
    local header="unsloth server  (last: ${last##*/})"
    if command -v fzf >/dev/null 2>&1; then
      chosen=$(printf '%s' "$lines" | fzf --height=10 --reverse --border \
        --prompt="$header > " --query="$last") || exit 130
    elif command -v gum >/dev/null 2>&1; then
      chosen=$(printf '%s' "$lines" | gum filter --height=10 --value="$last" \
        --placeholder="type to filter…" --header="$header") || exit 130
    else
      local urls; urls=$(printf '%s' "$lines" | cut -f1)
      PS3="unsloth server> "
      select chosen in $urls; do [ -n "$chosen" ] && break; done
    fi
    chosen=${chosen%%$'\t'*}
  else
    chosen=${lines%%$'\t'*}
  fi
  [ -n "$chosen" ] || _die "no server selected"
  IFS=$'\t' read -r m mkey mvar <<<"$(_us_mode "$chosen")"
  case "$m" in
    bearer) US_KEY="$mkey"; US_KEY_VAR="$mvar" ;;
    *)      US_KEY=""; US_KEY_VAR="" ;;   # broken pick: let the model fetch explain
  esac
  US_URL="$chosen"
  printf '%s\n' "$US_URL" > "$last_file"
  echo "unsloth: using $US_URL" >&2
}

# _us_models_raw  -> echoes raw /v1/models JSON (live, cache fallback).
_us_models_raw() {
  local cache="$STATE_DIR/unsloth-models.cache" out
  local hdr=()
  [ -n "${US_KEY:-}" ] && hdr=(-H "Authorization: Bearer $US_KEY")
  out=$(curl -fsS --max-time 10 "$US_URL/v1/models" "${hdr[@]+"${hdr[@]}"}" 2>/dev/null) || true
  if [ -n "$out" ]; then
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$out" > "$cache"
    printf '%s\n' "$out"
    return
  fi
  [ -s "$cache" ] || _die "could not list models from $US_URL and no cache present"
  echo "unsloth: $US_URL unreachable — using cached model list" >&2
  cat "$cache"
}

# Override lib.sh's cloud list: unsloth server model ids, one per line.
_models() {
  _us_models_raw | python3 -c 'import sys,json;print("\n".join(sorted(m["id"] for m in json.load(sys.stdin).get("data",[]))))'
}

# Annotated picker lines: "id<TAB>quant · ctx · loaded", loaded first.
_models_annotated() {
  MODELS_JSON=$(_us_models_raw) python3 - <<'PY'
import json, os

d = json.loads(os.environ["MODELS_JSON"]).get("data", [])
d.sort(key=lambda m: (not m.get("loaded"), m["id"]))
for m in d:
    bits = []
    if m.get("quant"):
        bits.append(m["quant"])
    if m.get("context_length"):
        bits.append(f"{m['context_length'] // 1024}k ctx")
    bits.append("loaded" if m.get("loaded") else "unloaded")
    print(m["id"] + "\t" + " · ".join(bits))
PY
}

# Override lib.sh's gum-only chooser: fzf first (fzf-style search), then gum,
# then a plain select. Remembers the last pick per harness. $UNSLOTH_MODEL skips.
_pick_model() {
  local harness="$1" last_file="$STATE_DIR/last-$1" last="" chosen=""
  mkdir -p "$STATE_DIR"
  if [ -n "${UNSLOTH_MODEL:-}" ]; then echo "$UNSLOTH_MODEL"; return; fi
  [ -f "$last_file" ] && last=$(cat "$last_file")
  local header="unsloth-$harness model  (last: ${last:-none})"
  if command -v fzf >/dev/null 2>&1; then
    chosen=$(_models_annotated | fzf --height=25 --reverse --border \
      --prompt="$header > " --query="$last") || exit 130
  elif command -v gum >/dev/null 2>&1; then
    chosen=$(_models_annotated | gum filter --height=20 --value="$last" \
      --placeholder="type to filter…" --header="$header") || exit 130
  else
    local models; models=$(_models)
    PS3="unsloth-$harness model> "
    select chosen in $models; do [ -n "$chosen" ] && break; done
  fi
  chosen=${chosen%%$'\t'*}
  [ -n "$chosen" ] || _die "no model selected"
  echo "$chosen" > "$last_file"
  echo "$chosen"
}

# Override lib.sh's /api/show metadata: /v1/models already carries
# context_length, quant and loaded state. Emits:
#   {"context_window": N, "capabilities": [...], "details": {...}}
_model_metadata() {
  local model="$1"
  MODELS_JSON=$(_us_models_raw) UNSLOTH_ID="$model" python3 - <<'PY'
import json, os, re

want = os.environ["UNSLOTH_ID"]
caps, details, ctx = [], {}, 131072
for m in json.loads(os.environ["MODELS_JSON"]).get("data", []):
    if m.get("id") == want:
        ctx = m.get("context_length") or m.get("native_context_length") or ctx
        details = {"quant": m.get("quant"), "loaded": m.get("loaded"),
                   "owned_by": m.get("owned_by")}
        break
# Light heuristic for reasoning models until the server advertises it.
if re.search(r"thinking|qwq|deepseek-r\d|magistral|qwen3(?!.?(instruct|guard))",
             want.lower()):
    caps.append("thinking")
print(json.dumps({"context_window": ctx, "capabilities": caps, "details": details}))
PY
}

# Override lib.sh's catalogue builder: one /v1/models fetch instead of one
# /api/show call per model against ollama.com. Echoes the catalogue path.
_codex_catalogue_all() {
  local out="$1"
  mkdir -p "$STATE_DIR"
  CATALOGUE_JSON=$(_us_models_raw) CATALOGUE_OUT="$out" python3 - <<'PY'
import json, os, re

entries = []
for m in json.loads(os.environ["CATALOGUE_JSON"]).get("data", []):
    mid = m["id"].lower()
    thinks = bool(re.search(
        r"thinking|qwq|deepseek-r\d|magistral|qwen3(?!.?(instruct|guard))", mid))
    ctx = m.get("context_length") or m.get("native_context_length") or 131072
    levels = ["low", "medium", "high"] if thinks else []
    entries.append({
        "slug": m["id"], "display_name": m["id"],
        "context_window": ctx, "input_modalities": ["text"],
        "supported_reasoning_levels": [{"effort": l, "description": l.title()} for l in levels],
        "default_reasoning_level": "low" if thinks else None,
        "supports_parallel_tool_calls": True,
        "supported_in_api": True, "visibility": "list",
        "shell_type": "default", "priority": 0, "base_instructions": "",
        "supports_reasoning_summaries": thinks, "default_reasoning_summary": "auto",
        "support_verbosity": False,
        "truncation_policy": {"mode": "tokens", "limit": ctx},
        "experimental_supported_tools": [],
    })
with open(os.environ["CATALOGUE_OUT"], "w") as f:
    json.dump({"models": entries}, f, indent=2)
PY
  echo "$out"
}