#!/usr/bin/env bash
set -euo pipefail
# Source me:  source ollama-env.sh
# Points OpenAI + Anthropic SDKs/CLIs at ollama.com using your OLLAMA_API_KEY.

if [ -z "$OLLAMA_API_KEY" ]; then
  echo "ollama-env: OLLAMA_API_KEY is not set" >&2
  return 1 2>/dev/null || exit 1
fi

# OpenAI SDK / CLI  (posts to $OPENAI_BASE_URL/chat/completions)
export OPENAI_BASE_URL="https://ollama.com/v1"
export OPENAI_API_KEY="$OLLAMA_API_KEY"

# Anthropic SDK / CLI  (posts to $ANTHROPIC_BASE_URL/v1/messages)
# ollama.com accepts only "Authorization: Bearer", NOT the SDK's default
# x-api-key header. ANTHROPIC_AUTH_TOKEN makes clients send Bearer.
export ANTHROPIC_BASE_URL="https://ollama.com"
export ANTHROPIC_AUTH_TOKEN="$OLLAMA_API_KEY"
unset ANTHROPIC_API_KEY

echo "ollama-env: OpenAI -> $OPENAI_BASE_URL, Anthropic -> $ANTHROPIC_BASE_URL/v1/messages"
