#!/usr/bin/env bash
# Update every coding agent / tool in one go.
#   codex, claude, ollama, pi, hermes, opencode
set -euo pipefail

# --- helpers ----------------------------------------------------------------

_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
_skip() { printf '  \033[33m-\033[0m %s\n' "$*"; }
_fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# _update <name> <cmd...>  -> run a tool's own updater, report result.
_update() {
  local name="$1"; shift
  if ! command -v "$name" >/dev/null 2>&1; then
    _skip "$name not installed — skipping"
    return
  fi
  printf '\n\033[1m%s\033[0m\n' "$name"
  if "$@"; then _ok "$name updated"; else _fail "$name update failed"; fi
}

# --- updates ----------------------------------------------------------------

_update codex   codex update

_update claude  npm update -g @anthropic-ai/claude-code

_update pi      npm update -g @earendil-works/pi-coding-agent

_update opencode opencode upgrade

_update unsloth unsloth studio update

# hermes: self-updating install script (idempotent).
_update hermes  bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'

# ollama: installed via the Ollama.app, which auto-updates itself in the
# background — nothing to run here, just report the version.
if command -v ollama >/dev/null 2>&1; then
  printf '\n\033[1mollama\033[0m\n'
  _skip "managed by Ollama.app (auto-updates) — version: $(ollama --version 2>/dev/null | head -1)"
else
  _skip "ollama not installed — skipping"
fi

printf '\n\033[1mDone.\033[0m\n'
